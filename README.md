# Getting started with Azure Kubernetes Service

Seven hands-on labs for people who are new to Azure and Kubernetes. Start with a
small cluster in the Azure portal, then build a reusable environment with
Terraform, Application Gateway for Containers, identities, storage, GitOps, and
managed monitoring.

The through-line is **how an AKS workload is exposed, authorized, persisted,
reconciled, and observed**. Labs 1-3 follow the same small web demo from a
public Service to an Azure-managed Gateway. Later labs use separate, deliberately
small workloads to isolate identity, disk, GitOps, and telemetry concepts; they
share the cluster, not one application lifecycle.

**These labs create billable Azure resources.** Use a sandbox subscription, not a
production cluster. Free AKS control-plane pricing does not make the worker
nodes, disks, networking, Application Gateway for Containers, or monitoring free.

## Learning path

Complete [Setup and prerequisites](docs/00-setup.md) before starting.

| Lab | You will learn | Approximate time, including provisioning |
| --- | --- | --- |
| [1. A cluster in the portal](labs/01-portal/README.md) | Create AKS, connect, deploy a web application, and use a public Service | 45-60 minutes |
| [2. Terraform, a VNet, and an upgrade](labs/02-terraform/README.md) | Create reproducible infrastructure, understand networking, and upgrade Kubernetes | 90-120 minutes |
| [3. Application Gateway for Containers](labs/03-agc/README.md) | Install ALB Controller and route HTTP traffic using Gateway API | 60-90 minutes |
| [4. Managed identities and Blob Storage](labs/04-identity-storage/README.md) | Read Azure Blob Storage without a password and verify read-only access | 45-60 minutes |
| [5. Persistent volumes with Azure Disks](labs/05-persistent-volumes/README.md) | Connect a PVC to its PV and Azure Disk, and preserve data across pod replacement | 30-45 minutes |
| [6. Managed Argo CD and Entra ID](labs/06-gitops/README.md) | Sign in with Entra ID, deploy from Git, and reconcile changes and drift | 90-120 minutes |
| [7. Managed monitoring](labs/07-monitoring/README.md) | Investigate Container Insights logs, query managed Prometheus, and use Azure Managed Grafana | 60-90 minutes |

**Lab 6 alternative:** If you do not have permission to create app registrations
in Microsoft Entra ID, use [Lab 6 fallback: local Argo CD login](labs/06-gitops-local/README.md)
instead of the Entra version. It covers the same GitOps exercises using a local
Argo CD account, without creating an Entra app registration or security group.
Azure subscription roles do not automatically grant these Entra permissions.

The seven labs total about **7-9¾ hours**, excluding setup, breaks, permission
delays, discussion, and cleanup. Plan this as a multi-session workshop; a
reasonable split is Labs 1-3, then Labs 4-7. Complete the setup guide before
the first session and reserve time for final cleanup.

Exercises have **collapsed solution blocks**. Try the task first, then expand
the solution for commands and explanations. Run the commands in order; the
solutions are also the worked path through each lab.

## Optional bonus: compare AKS Automatic

After Lab 1, create a separate, disposable AKS Automatic cluster and deploy
[`apps/demo/manifest.yaml`](apps/demo/manifest.yaml). Explore the running
workload and cluster defaults, then compare the setup and operational choices
with Lab 1's standard AKS cluster and Lab 2's Terraform-managed cluster. Discuss
which decisions AKS Automatic makes for you and where standard AKS offers more
direct control. Use the
[AKS Automatic quickstart](https://learn.microsoft.com/azure/aks/automatic/quick-automatic-managed-network)
for current creation, connection, and cleanup instructions.

This exercise is separate from the seven-lab path: use its own resource group,
review the estimated charges and quota before creating it, and delete the
cluster when finished. Do not use it for Labs 2-7, which rely on the shared
Terraform-managed cluster.

## How the clusters are reused

```text
Lab 1: portal cluster -> deploy demo -> delete portal resource group

Lab 2: Terraform cluster in a VNet
         -> Lab 3: add AGC and route the demo
         -> Lab 4: add the identity and Blob Storage demo
         -> Lab 5: add a persistent-volume demo using an Azure Disk
         -> Lab 6: add managed Argo CD and a separate GitOps demo
         -> Lab 7: add Container Insights, managed Prometheus, and Managed Grafana
         -> final cleanup
```

Create **two clusters over the course of the workshop**, not seven. Delete the
first before creating the second. Labs 2-7 reuse the same cluster and Terraform
state; do not run `terraform destroy` between them.

Lab 2 enables OIDC and Workload Identity because the Lab 3 controller needs them.
Lab 4 explains and uses them for an application. Lab 3 uses Helm for the ALB
Controller; Lab 6 uses Microsoft's managed `Microsoft.ArgoCD` extension, **not** a
second Helm-installed Argo CD.

Lab 7 adds managed monitoring to that cluster with default agent collection
and built-in dashboards. Its paid monitoring resources are not created in
earlier labs. Grafana uses its built-in Entra authentication, independent of
the Argo CD app registration.

The examples after Lab 3 are separate on purpose:

| Lab | Why it uses a separate workload |
| --- | --- |
| 4 | A minimal CLI pod makes the Workload Identity token exchange and read-only Blob authorization visible without an application SDK. |
| 5 | A single web pod makes the PVC-to-PV-to-disk relationship and data survival easy to observe. |
| 6 | A fresh `gitops-demo` namespace lets Argo CD own its application without adopting or pruning the earlier demo or disk workload. |
| 7 | A small log-emitting workload makes telemetry searchable and keeps the exercise's log volume controlled. |

Lab 7 also revisits the earlier namespaces in cluster dashboards so monitoring
connects back to the environment built in Labs 2-6.

Lab 2 intentionally starts on a **still-supported Kubernetes version with an
available upgrade**, chosen from the live regional version list. For Labs 1-2, prefer
**1.35.1** if still available with standard support in **Sweden Central
(`swedencentral`)**; otherwise choose the oldest available supported patch at
or above **1.35**, excluding previews and LTS-only releases. Confirm a newer
supported upgrade is available before Lab 2. Attendees upgrade the control
plane and both node pools through Terraform before Lab 3, preferably to the
next minor or to a newer patch if no next minor is offered.

## Workshop wrap-up

Before cleanup, trace a request from the browser through the Gateway, route,
Service, and pod. Then explain which layer owns the cluster, Azure resources,
Kubernetes workloads, GitOps desired state, and monitoring collection. Finally,
explain why the disk, GitOps application, and AGC controller must be removed in
the order shown in [Final cleanup](docs/cleanup.md).

## Repository map

| Path | Purpose |
| --- | --- |
| `docs/00-setup.md` | Installation, login, permissions, terminology, and resuming work |
| `docs/instructor-guide.md` | Delivery plan and live-integration smoke checks for a fresh workshop environment |
| `infrastructure/` | Shared cluster/network and optional Azure resources for Labs 3, 4, 6, and 7 |
| `apps/demo/manifest.yaml` | Small HTTP demo for Labs 1-3 and the GitOps source for Lab 6 |
| `apps/persistent-demo/manifest.yaml` | Web application and Azure Disk claim for Lab 5 |
| `apps/monitoring-demo/manifest.yaml` | Small log-emitting workload for Lab 7's log and metric exercises |
| `labs/` | Tasks, inline solutions, checkpoints, and troubleshooting |
| `docs/cleanup.md` | Ordered teardown, including Entra objects outside resource groups |

No custom shell scripts, container build, private registry, custom DNS name,
public TLS certificate, or Argo CD CLI is required. Commands use **Bash**.
Windows attendees should use WSL 2 with Ubuntu; see the setup guide.

## Lab-only choices

This is a learning environment, not a production reference architecture:

- Public AKS API endpoint and local Kubernetes administrator credentials.
- Two Linux system nodes reserved for critical add-ons, two application nodes,
  and non-HA Argo CD.
- HTTP for the public demo, containing no sensitive data.
- Argo CD available only through a localhost port-forward, with Entra sign-in
  (or a local administrator account in the fallback Lab 6).
- Terraform state stored locally; never commit it or lose it during the labs.
- A public GitHub fork for GitOps, containing manifests but no credentials.
- Default managed monitoring collection and Grafana Standard without optional
  HA/networking features; not a production observability design.

Production designs need separate decisions about private networking, AKS Entra
authentication, least-privilege administration, TLS, resilience, remote state,
monitoring retention/alerts, backups, and policy. Entra sign-in to **Argo CD**
in Lab 6 is distinct from Entra authentication to the **Kubernetes API**.

When finished, follow [Final cleanup](docs/cleanup.md). Closing your terminal or
deleting a Kubernetes Deployment does not stop Azure billing.

## Repository checks

The GitHub Actions validation checks local Markdown links and heading anchors,
balanced solution blocks, Bash code-block syntax, key cross-file workload
boundaries, and the mocked Terraform configuration. These checks do not contact
Azure or prove that live services are available in a particular region.

## Checking the Terraform solution

With Terraform 1.7+ (or OpenTofu with mock-provider support), run:

```bash
terraform -chdir=infrastructure fmt -check -recursive
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure test
```

Initialize the provider first if needed. The tests use a mocked AzureRM provider;
they do not create Azure resources or modify the workshop's live state.