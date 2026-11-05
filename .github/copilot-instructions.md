# Repository guidance

## Workshop architecture

This is a Markdown-first, beginner AKS workshop with seven sequential labs.
`README.md` defines the learning path; `docs/00-setup.md` prepares attendees,
and `docs/cleanup.md` defines the dependency-sensitive teardown.

Lab 1 uses a disposable portal-created cluster. Labs 2-7 share one
Terraform-managed cluster, VNet, and local state. Lab 2 deliberately starts on
an older **still-supported**, regionally available Kubernetes patch and upgrades
the control plane and node pool through Terraform. Do not hard-code an expiring
Kubernetes release or replace the cluster between labs.

`infrastructure/` is one Terraform root configuration, split by concern.
It uses AzureRM `~> 4.81`; resource-provider auto-registration is disabled
because setup explicitly registers the providers.

| Lab | Ownership boundary |
| --- | --- |
| 2 | Terraform owns AKS, cluster identity, VNet, delegated subnets, NSGs, and subnet roles. |
| 3 | `enable_agc` adds Terraform-managed controller identity, federation, and roles. Helm installs ALB Controller; Kubernetes Gateway/HTTPRoute/ApplicationLoadBalancer resources drive controller-managed AGC. This is not AGIC. |
| 4 | `enable_blob_storage` adds Terraform-managed private, keyless Blob Storage, workload identity, federation, and container-scoped reader/uploader roles. CLI seeds and reads blob data. |
| 5 | Kubernetes manifests provision the PVC/PV-backed Azure Disk through AKS CSI, not a Terraform disk resource. |
| 6 | `enable_argocd` adds the Terraform-managed `Microsoft.ArgoCD` extension and repo-server identity/federation. Entra app, service principal, security group, and SSO-app federation remain externally managed. |
| 7 | `enable_monitoring_resources` creates Terraform-managed workspaces, Grafana, and scoped roles. AKS CLI onboarding owns collection rules, associations, recording rules, and Grafana linkage. |

Later-lab flags default to false. Creating monitoring destinations does not
enable collection: `log_analytics_workspace_id` remains null until CLI onboarding
and then preserves both AKS monitoring agents in Terraform. Grafana's
`azure_monitor_workspace_integrations` is intentionally ignored by Terraform.
Preserve this split when changing provisioning or cleanup.

## Validation commands

Run from the repository root. Configuration supports Terraform >=1.6,<2.0;
mock-provider tests require **1.7+**.

```bash
terraform -chdir=infrastructure init -backend=false
terraform -chdir=infrastructure fmt -check -recursive
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure test
```

To select a test file:

```bash
terraform -chdir=infrastructure test -filter=tests/labs.tftest.hcl
```

The current suite is entirely in that file; `-filter` selects files, not
individual named `run` blocks. Its AzureRM provider is mocked, including the
`command = apply` test, so it does not provision Azure or modify live state.
The tests cover subnet rules, disabled defaults, identity/role boundaries,
monitoring onboarding separation, and missing-input preconditions.

For Markdown changes, check relative links, heading anchors, fenced Bash syntax,
and balanced `<details>` blocks. Use `git diff --check` for whitespace.
Distinguish these checks and mocked tests from live Azure verification; do not
run workshop provisioning or teardown commands just to validate documentation.

## Cross-file conventions

- Write exercises for Azure/Kubernetes beginners, with worked solutions inside
  collapsed `<details><summary>Solution: ...</summary>` blocks. Keep scripts
  minimal; use inline Bash commands and checked-in sample manifests.
- Each lab has Home/Previous navigation at the top and Next navigation at the
  bottom. Lab 1 links back to setup; Lab 7 links forward to cleanup. Keep lab
  numbering, README learning-path entries, setup, and cleanup references aligned.
- Commands assume the repository root. Setup creates ignored `.workshop/env.sh`
  **before Lab 1**; later terminals source it. Recover resource names and IDs
  from Terraform outputs rather than introducing competing naming logic.
  Prefixes use `aksintro-${LAB_ID}` with a 2-6-character lowercase alphanumeric
  lab ID. Preserve existing tfvars inputs and the upgraded Kubernetes version
  when enabling later flags.
- Optional Terraform resources use `count` and `[0]` addresses, with null outputs
  while disabled. Existing CLI-created resources must be imported according to
  `docs/terraform-migration.md`, not recreated.
- Keep `apps/demo/manifest.yaml` namespace-neutral and its Service ClusterIP in
  Git. Labs 1-3 deploy it into `demo` and patch exposure locally; Lab 6 reconciles
  the same source into separate `gitops-demo`. Keep both GitOps repository URLs,
  the `apps/demo` path, AppProject allowlist, and workload types consistent.
  Initial sync is manual, without a cascading Application deletion finalizer.
- Keep cluster, ALB, blob-reader, Argo repo-server, and Argo SSO-app identities
  distinct. Federation subjects must exactly match namespace/ServiceAccount
  names in the lab manifests. Argo server uses the SSO app client ID, not the
  repo-server managed identity. Its UI is localhost-only with scoped group RBAC;
  this does not enable Entra authentication for the Kubernetes API.
- Persistent storage uses a single replica, `Recreate`, and a `managed-csi`
  ReadWriteOnce claim in `storage-demo`. The init container must not overwrite
  existing disk content. Monitoring's log-emitting sample is in `monitoring-demo`.
- Preserve teardown order: disable collection before deleting destinations,
  remove GitOps applications before their controller, delete PVCs while CSI
  runs, and let ALB Controller remove AGC before removing its permissions.
  Retain completed-lab flags until final Terraform destroy; Entra cleanup is
  separate.
- `.workshop/`, Terraform dependencies, lock files, tfvars, plans, and state are
  intentionally ignored. They can exist locally; do not incorporate their
  contents into instructions or commit them.
