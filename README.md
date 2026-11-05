# Getting started with Azure Kubernetes Service

Seven hands-on labs for people who are new to Azure and Kubernetes. Start with a
small cluster in the Azure portal, then build a reusable environment with
Terraform, Application Gateway for Containers, identities, storage, GitOps, and
managed monitoring.

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

Allow additional time for tool installation, permissions, and discussion.
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

Lab 2 intentionally starts on an **older, still-supported Kubernetes minor
version**, chosen from the live regional version list. Attendees upgrade the
control plane and both node pools through Terraform before Lab 3. No obsolete version
is hard-coded, and no unsupported-version or paid LTS exception is required.

## Repository map

| Path | Purpose |
| --- | --- |
| `docs/00-setup.md` | Installation, login, permissions, terminology, and resuming work |
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
- Argo CD available only through a localhost port-forward, with Entra sign-in.
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

## Checking the Terraform solution

With Terraform 1.7+ (or OpenTofu with mock-provider support), run:

```bash
terraform -chdir=infrastructure fmt -check -recursive
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure test
```

Initialize the provider first if needed. The tests use a mocked AzureRM provider;
they do not create Azure resources or modify the workshop's live state.