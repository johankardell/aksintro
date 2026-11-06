#!/usr/bin/env python3
"""Check local Markdown links, Bash examples, and workshop cross-file invariants."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parents[2]
LINK_PATTERN = re.compile(r"(?<!!)\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))[^)]*\)")
FENCE_PATTERN = re.compile(r"^```([^\s`]*)\s*$")


def markdown_files() -> list[Path]:
    ignored = {".git", ".terraform", ".workshop", "node_modules"}
    return [
        path
        for path in ROOT.rglob("*.md")
        if not ignored.intersection(path.relative_to(ROOT).parts)
    ]


def heading_anchors(markdown: str) -> set[str]:
    anchors: set[str] = set()
    counts: dict[str, int] = {}
    in_fence = False

    for line in markdown.splitlines():
        if FENCE_PATTERN.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        match = re.match(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not match:
            continue

        heading = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", match.group(1))
        heading = heading.replace("`", "").lower()
        anchor = re.sub(r"[^\w -]", "", heading, flags=re.UNICODE)
        anchor = re.sub(r"\s+", "-", anchor.strip())
        anchor = re.sub(r"-{2,}", "-", anchor)
        count = counts.get(anchor, 0)
        counts[anchor] = count + 1
        anchors.add(anchor if count == 0 else f"{anchor}-{count}")

    return anchors


def check_markdown(files: list[Path]) -> list[str]:
    errors: list[str] = []
    anchors_by_path = {path.resolve(): heading_anchors(path.read_text(encoding="utf-8")) for path in files}

    for path in files:
        markdown = path.read_text(encoding="utf-8")
        relative = path.relative_to(ROOT)
        prose = re.sub(r"```.*?```", "", markdown, flags=re.DOTALL)
        prose = re.sub(r"`[^`]*`", "", prose)
        details_open = len(re.findall(r"<details(?:\s[^>]*)?>", prose, re.IGNORECASE))
        details_close = len(re.findall(r"</details\s*>", prose, re.IGNORECASE))
        if details_open != details_close:
            errors.append(f"{relative}: unbalanced <details> blocks ({details_open} open, {details_close} close)")

        in_fence = False
        fence_language = ""
        bash_lines: list[str] = []
        block_number = 0
        for line in markdown.splitlines(keepends=True):
            fence = FENCE_PATTERN.match(line.rstrip("\r\n"))
            if fence:
                if not in_fence:
                    in_fence = True
                    fence_language = fence.group(1).lower()
                    bash_lines = []
                    block_number += 1
                else:
                    if fence_language == "bash":
                        result = subprocess.run(
                            ["bash", "-n"],
                            input="".join(bash_lines),
                            text=True,
                            capture_output=True,
                            check=False,
                        )
                        if result.returncode:
                            message = result.stderr.strip().splitlines()
                            errors.append(
                                f"{relative}: Bash block {block_number} syntax error: "
                                f"{message[-1] if message else 'bash -n failed'}"
                            )
                    in_fence = False
                    fence_language = ""
                continue
            if in_fence and fence_language == "bash":
                bash_lines.append(line)

        for match in LINK_PATTERN.finditer(markdown):
            destination = match.group(1) or match.group(2) or ""
            parsed = urlparse(destination)
            if parsed.scheme or parsed.netloc:
                continue

            target_text = unquote(parsed.path)
            target = (path.parent / target_text).resolve() if target_text else path.resolve()
            fragment = unquote(parsed.fragment)
            directory_target = target.is_dir()
            if directory_target and fragment:
                target = target / "README.md"
            elif directory_target:
                continue
            if not target.is_file():
                errors.append(f"{relative}: broken local link target {destination!r}")
                continue
            if fragment and target.suffix.lower() == ".md":
                known_anchors = anchors_by_path.get(target.resolve())
                if known_anchors is None:
                    known_anchors = heading_anchors(target.read_text(encoding="utf-8"))
                if fragment not in known_anchors:
                    errors.append(f"{relative}: missing heading anchor {destination!r}")

    return errors


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(f"cross-file invariant failed: {message}")


def check_workshop_invariants() -> list[str]:
    errors: list[str] = []
    read = lambda path: (ROOT / path).read_text(encoding="utf-8")
    demo = read("apps/demo/manifest.yaml")
    application = read("labs/06-gitops/application.yaml")
    project = read("labs/06-gitops/project.yaml")
    blob = read("infrastructure/blob.tf")
    identity_lab = read("labs/04-identity-storage/README.md")
    persistent = read("apps/persistent-demo/manifest.yaml")

    app_repos = re.findall(r"^\s*repoURL:\s*(\S+)", application, re.MULTILINE)
    project_repos = re.findall(r"^\s*-\s*(https://github\.com/\S+)", project, re.MULTILINE)
    require("namespace:" not in demo, "the shared demo manifest must remain namespace-neutral", errors)
    require("type: ClusterIP" in demo, "the shared demo Service must remain ClusterIP in Git", errors)
    require("path: apps/demo" in application, "Argo CD must source the shared apps/demo path", errors)
    require(
        len(app_repos) == 1 and len(project_repos) == 1 and app_repos[0] == project_repos[0],
        "the Argo CD Application source URL must match the AppProject allowlist",
        errors,
    )
    require("namespace: gitops-demo" in application and "namespace: gitops-demo" in project,
            "the GitOps Application destination must match its project allowlist", errors)
    require(
        'subject                   = "system:serviceaccount:identity-demo:blob-reader"' in blob
        and "system:serviceaccount:identity-demo:blob-reader" in identity_lab,
        "the Blob Workload Identity subject must match the Lab 4 ServiceAccount",
        errors,
    )
    require(
        "namespace: storage-demo" in persistent
        and "storageClassName: managed-csi" in persistent
        and "accessModes:\n    - ReadWriteOnce" in persistent,
        "the persistent demo must retain its storage-demo managed-csi RWO claim",
        errors,
    )
    return errors


def main() -> int:
    errors = check_markdown(markdown_files()) + check_workshop_invariants()
    if errors:
        print("\n".join(f"ERROR: {error}" for error in errors), file=sys.stderr)
        return 1
    print("Repository documentation and cross-file checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
