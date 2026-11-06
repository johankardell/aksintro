# Instructor guide

This guide contains delivery guidance and pre-workshop checks for instructors.
Every workshop starts from zero: attendees create new lab resources, not
import or adapt resources from an earlier workshop. The attendee workflow
remains in [Setup](00-setup.md) and the numbered labs.

## Suggested delivery plan

The labs take about 7-9¾ hours before setup, breaks, permission delays,
discussion, and cleanup. A practical split is:

| Session | Labs | Teaching focus |
| --- | --- | --- |
| 1 | 1-3 | AKS fundamentals, repeatable infrastructure, and the demo's network path |
| 2 | 4-7 | Workload identity, storage, GitOps, and observing the shared cluster |

Complete setup and confirm permissions before the first session. Reserve
additional time after Lab 7 for the ordered cleanup. The optional AKS Automatic
comparison is separate and should not be included in this schedule.

## Pre-workshop availability and smoke checks

Azure Kubernetes versions, regional capacity, extension configuration, and CLI
behavior can change. Before attendees begin:

1. Confirm the region and node size in `infrastructure/terraform.tfvars.example`
   are available for AKS and all optional services, and verify quota for four
   nodes plus two temporary upgrade nodes.
2. Prefer Kubernetes **1.35.1** for Labs 1-2 if it is still available with
   standard support in **Sweden Central (`swedencentral`)**. Otherwise, select
   the oldest available, generally available patch version at or above **1.35**
   with standard support. Follow the [setup version checks](00-setup.md#5-prepare-azure-providers-extensions-and-quota)
   and confirm a newer supported version is offered for Lab 2's upgrade.
   Check compatibility with the pinned ALB Controller chart and the managed
   Argo CD extension.
3. In a disposable training subscription, run Labs 2-3 end to end: apply the
   Terraform base, perform the in-place upgrade, provision and remove the
   controller-managed AGC, then verify the cluster remains healthy.
4. Verify the current Workload Identity flow and Blob data-role behavior in Lab
   4. Confirm a read succeeds and the expected write denial occurs.
5. Verify the managed `Microsoft.ArgoCD` extension configuration, Entra sign-in,
   manual sync, Git change, and self-healing in Lab 6. Check tenant consent and
   app/group permissions separately from Azure RBAC.
6. Verify Lab 7 onboarding, the `ContainerLogV2` query, managed Prometheus
   queries, Grafana access, and the monitoring teardown commands.
7. Complete the documented cleanup in the disposable environment. Do not treat
   mocked Terraform tests or static checks as proof of live Azure behavior.

Record the tested date, region, Kubernetes patch, VM size, CLI versions, chart
version, extension state, and any tenant-specific setup for the class. Do not
copy an old Kubernetes version or assume regional service availability from a
previous delivery.
