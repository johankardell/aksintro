# Lab 7: Container Insights, managed Prometheus, and Managed Grafana

[Home](../../README.md) | [Previous: Lab 6](../06-gitops/README.md)

**Goal:** Collect container logs and Kubernetes metrics, find a workload in
Container Insights, and explore its metrics in Azure Managed Grafana.

**Time:** 60-90 minutes, including provisioning and ingestion delays.
**Prerequisites:** the existing upgraded Lab 2 cluster and Terraform state,
setup completed, and permission to create resources and assign Azure roles. Labs 3-6 can remain
running but are not required for monitoring. No new cluster is needed.

## What you are building

```text
AKS monitoring-demo workload -> stdout -> Azure Monitor agent
                                          -> Log Analytics workspace
                                          -> Container Insights / Logs (KQL)

AKS default metric targets -> managed metrics agent
                               -> Azure Monitor workspace (managed Prometheus)
                               -> Azure Managed Grafana dashboards / PromQL

Your browser -> Entra sign-in -> Azure Managed Grafana
```

These are **three different resources**, not three names for the same workspace:

| Resource / feature | Purpose |
| --- | --- |
| Log Analytics workspace + Container Insights | Container logs, Kubernetes events/inventory, and cluster investigation |
| Azure Monitor workspace + managed Prometheus | Time-series metrics collected from Kubernetes targets |
| Azure Managed Grafana | Visualize/query Prometheus metrics using a managed Grafana instance |

We use default collection settings, the default Prometheus **minimal ingestion
profile**, and built-in Grafana dashboards. There is no self-hosted Prometheus,
Grafana Helm release, custom exporter, ServiceMonitor, scrape ConfigMap, or
application instrumentation to maintain. Container Insights uses its standard
collection, including performance data, so its built-in views remain available.
Reducing duplicate performance collection is a later optimization, not required
to understand this basic setup.

**Costs:** Managed Grafana Standard has ongoing charges even when nobody opens a
dashboard. Log ingestion/retention and Prometheus ingestion/queries also cost
money. The sample emits one short log line every ten seconds; keep the exercise
short and clean up afterward. Do not enable extra diagnostic categories,
control-plane logs/metrics, alerts, private endpoints, or all-metrics collection.

## 1. Reconnect and prepare the monitoring services

Use the same cluster and a separate resource group for the three monitoring
resources. Use the same region to keep the example simple; the instructor must
check that all three services are available there.

<details>
<summary>Solution: cluster settings, providers, and the Grafana CLI extension</summary>

Run from the repository root:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
export AKS_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query id -o tsv)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.AlertsManagement --wait
az provider register --namespace Microsoft.Monitor --wait
az provider register --namespace Microsoft.Dashboard --wait
az extension add --name amg --upgrade
az extension add --name monitor-control-service --upgrade
az extension list --output table
```

The local components, installed during setup, are Azure CLI's **`amg` extension**
for Grafana and **`monitor-control-service` extension** for collection-rule
diagnostics and cleanup, not separate monitoring servers. The commands above
install or update them if you skipped setup or switched machines. If
`aks-preview` is listed, Microsoft's monitoring onboarding guidance requires
removing it with `az extension remove --name aks-preview` before using these
stable commands. Earlier workshop labs do not require it. If you need that
extension for unrelated work, use a separate training CLI environment.

You need Contributor plus permission to assign roles on these resources.
The onboarding command grants Grafana's identity access to metrics, so role
assignment permission is required in addition to resource creation permission.
New resource providers and role assignments can take several minutes to become
usable.

</details>

## 2. Create the workspaces and grant access

[`infrastructure/monitoring.tf`](../../infrastructure/monitoring.tf) creates a
pay-as-you-go Log Analytics workspace with 30-day retention, an Azure Monitor
workspace, and a basic **Standard X1** Managed Grafana instance running major
version **12**. Grafana's system-assigned managed identity stays enabled.
The instructor must check regional availability for this Grafana version.

<details>
<summary>Solution: Terraform resources, scoped permissions, and outputs</summary>

```bash
export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
printf 'attendee_object_id = "%s"\n' "$USER_OBJECT_ID"
```

Add `enable_monitoring_resources = true` and the printed `attendee_object_id`
to the existing `infrastructure/terraform.tfvars`. If Lab 4 already set the
user ID, verify it rather than adding a duplicate variable.
Leave `log_analytics_workspace_id` unset for now: creating destinations does
**not** enable collection.

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure fmt -check
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=monitoring.tfplan
```

Expect **seven additions**: the monitoring resource group, three monitoring
resources, and three scoped role assignments. Expect no AKS changes or replacement.

```bash
terraform -chdir=infrastructure apply monitoring.tfplan
export MONITORING_RG=$(terraform -chdir=infrastructure output -raw monitoring_resource_group_name)
export LAW_ID=$(terraform -chdir=infrastructure output -raw log_analytics_workspace_id)
export AMW_ID=$(terraform -chdir=infrastructure output -raw azure_monitor_workspace_id)
export GRAFANA_ID=$(terraform -chdir=infrastructure output -raw grafana_id)
export GRAFANA_NAME="${GRAFANA_ID##*/}"
```

Recover these same outputs when resuming. Grafana creation can take several
minutes. Terraform grants only the explicit scoped roles: no subscription-wide
Monitoring Reader access or unnecessary Grafana Admin role.
**Grafana Editor** permits Explore and dashboard editing; Contributor on the
Azure resource alone is not a Grafana sign-in role.

The Monitoring Data Reader assignment lets **Grafana's managed identity** query
Prometheus; it is separate from the human user's Grafana role. Managed Grafana uses Entra
authentication out of the box: no new app registration, client secret, or
Lab 6 Argo CD SSO configuration is needed.

The Azure Monitor workspace also creates a managed resource group named like
`MA_<workspace>_<region>_managed` containing its default ingestion resources.
Azure removes that managed group when you delete the workspace. Do not modify
it manually.

</details>

## 3. Enable collection and link Grafana

Use the supported onboarding commands so Azure creates the agents, data
collection rules/associations, and standard Prometheus recording rules for you.
Always pass the workspace IDs to avoid creating shared default workspaces in
unexpected resource groups.

<details>
<summary>Solution: Container Insights and managed Prometheus onboarding</summary>

```bash
az aks enable-addons --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --addons monitoring --workspace-resource-id "$LAW_ID"
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --enable-azure-monitor-metrics \
  --azure-monitor-workspace-resource-id "$AMW_ID" \
  --grafana-resource-id "$GRAFANA_ID"
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{containerInsights:addonProfiles.omsagent.enabled,logWorkspace:addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID,prometheus:azureMonitorProfile.metrics.enabled}' \
  --output yaml
kubectl -n kube-system get pods
```

Expect both monitoring features enabled. In `kube-system`, look for healthy
**`ama-logs`** and **`ama-metrics`** agents. Do not install another agent chart.
The CLI uses managed identity authentication for Container Insights by default;
no Log Analytics workspace key is needed.

The Prometheus onboarding command links the Azure Monitor workspace to Grafana
and configures the required access/recording rules. It can create an additional
workspace-scoped Monitoring Reader role assignment as part of that process.
We keep the explicit Monitoring Data Reader assignment for Grafana's query
access.

If a previous attempt already enabled metrics without Grafana linkage, follow
Microsoft's disable/re-enable guidance before retrying the combined command;
do not repeatedly create more workspaces. This is not needed on the workshop's
previously unmonitored Terraform cluster.

</details>

### Keep Terraform consistent with the cluster

The root Terraform configuration separates destination provisioning
(`enable_monitoring_resources`) from the optional collection input
(`log_analytics_workspace_id`). The latter remains `null` until CLI onboarding
has configured the agents and collection resources. Set it now to preserve
the add-on settings you just enabled.

<details>
<summary>Solution: record the workspace ID and check for unintended drift</summary>

Print the value to copy:

```bash
printf 'log_analytics_workspace_id = "%s"\n' "$LAW_ID"
```

Add that line **once** to `infrastructure/terraform.tfvars` using your editor.
Do not regenerate the file from the Lab 2 example: retain the upgraded
`kubernetes_version` and all other existing inputs.

```bash
terraform -chdir=infrastructure plan
```

Expect no add-on removal or cluster replacement. The conditional `oms_agent`
and `monitor_metrics` blocks retain the enabled features. If the plan contains
other drift, inspect it before applying anything; never apply a plan that
disables the monitoring you are trying to demonstrate.

Terraform owns the monitoring resource group, workspaces, Grafana, three access
roles, and the cluster's two add-on settings. The CLI owns Grafana linkage,
data collection rules/associations, and recording rules. `monitoring.tf`
deliberately ignores changes only to Grafana's workspace integrations, so
another Terraform apply does not undo CLI onboarding. Final cleanup stops
collection before Terraform deletes the destinations.

</details>

## 4. Deploy a small telemetry workload

Inspect [`apps/monitoring-demo/manifest.yaml`](../../apps/monitoring-demo/manifest.yaml).
It emits a short message to stdout every ten seconds and has small resource
requests/limits. No public endpoint or additional disk is required.

<details>
<summary>Solution: deploy and confirm local logs first</summary>

```bash
kubectl apply -f apps/monitoring-demo/manifest.yaml
kubectl -n monitoring-demo rollout status deployment/telemetry-demo --timeout=180s
kubectl -n monitoring-demo get pods
kubectl -n monitoring-demo logs deployment/telemetry-demo --tail=5
```

Expect `AKS monitoring lab: app is running`. Kubernetes resource metrics for the
deployment and its containers are collected by default. The app does not expose
its own Prometheus endpoint; metrics such as HTTP request counts would require
separate application instrumentation.

Allow **5-15 minutes** for initial agent setup and data ingestion before
expecting portal/Grafana results. Monitoring is not a live mirror of
`kubectl logs`. If no data appears after that, use the troubleshooting section
rather than enabling more collection.

</details>

## 5. Find the workload in Container Insights and query logs

In the Azure portal, open your AKS cluster and select **Monitoring -> Insights**
(or **Monitor -> Insights**, depending on the portal layout). Set the time
range to the last 30 minutes, find the `monitoring-demo` namespace under
controllers/containers, and inspect pod health and resource usage.

Then switch the namespace filter to `demo`, `storage-demo`, or `gitops-demo`
to revisit workloads created in earlier labs. Their owners remain unchanged:
Argo CD still manages only `gitops-demo`, and the disk-backed app still uses
its Lab 5 claim. The following log query intentionally stays scoped to the
dedicated telemetry sample.

Then open **Logs** for the lab Log Analytics workspace and run a query against
`ContainerLogV2`.

<details>
<summary>Solution: scoped KQL query for the sample's stdout</summary>

Print the exact cluster ID:

```bash
printf '%s\n' "$AKS_ID"
```

Replace `PASTE-YOUR-AKS-RESOURCE-ID` below with that value. Run this in the
portal's Log Analytics query editor, **not** Bash or Grafana's PromQL editor:

```kusto
let clusterId = "PASTE-YOUR-AKS-RESOURCE-ID";
ContainerLogV2
| where TimeGenerated > ago(30m)
| where _ResourceId =~ clusterId
| where PodNamespace == "monitoring-demo"
| project TimeGenerated, PodName, ContainerName, Message = tostring(LogMessage)
| order by TimeGenerated desc
| take 50
```

Expect the same message you saw with `kubectl logs`, plus pod/container identity
and ingestion timestamps. Compare the pod name with Kubernetes. No secrets
should ever be written to this demo's stdout.

**KQL** queries logs in Log Analytics. **PromQL** queries time-series metrics in
managed Prometheus. They are different query languages and data stores.

</details>

## 6. Open Managed Grafana and explore Prometheus

Open the Managed Grafana endpoint and sign in with the same Entra account that
received the Grafana Editor role.

<details>
<summary>Solution: built-in dashboards and two small PromQL queries</summary>

```bash
terraform -chdir=infrastructure output -raw grafana_endpoint
```

Open the printed **HTTPS** URL. Under **Dashboards**, find the managed Prometheus
dashboards, such as **Kubernetes / Compute Resources / Cluster** and
**Kubernetes / Compute Resources / Namespace (Pods)**. Select the lab cluster,
namespace `monitoring-demo`, and a time range of the last 30 minutes.
Dashboard names and folder layout can vary by Grafana version.

In **Explore**, select the **managed Prometheus data source linked to your
Azure Monitor workspace**, not the general Azure Monitor/Logs data source.
Use Code/PromQL mode and run:

```promql
kube_deployment_status_replicas_available{
  namespace="monitoring-demo",
  deployment="telemetry-demo"
}
```

Expect **1** once the first samples arrive. Switch between table/instant and
time-series views to see the difference between a current value and history.

Next, query container memory:

```promql
sum by (pod) (
  container_memory_working_set_bytes{
    namespace="monitoring-demo",
    container="app"
  }
)
```

Expect a nonzero memory series for the sample pod. The units are **bytes**, not
percent. These metrics are in the default minimal ingestion profile; no
custom scraping or extra kube-state-metrics installation is needed.

You can optionally save a dashboard panel with the replica query using your
Editor role, but no custom dashboard is required to complete the lab.

</details>

## 7. Make a visible change and correlate the tools

Scale only the dedicated monitoring deployment. Watch Kubernetes first, then
the managed Prometheus query, then the extra pod's log lines in Container
Insights. Do not scale the GitOps-managed deployment or Lab 5's disk-backed app.

<details>
<summary>Solution: see replicas and pod logs change, then restore the baseline</summary>

```bash
kubectl -n monitoring-demo scale deployment telemetry-demo --replicas=2
kubectl -n monitoring-demo rollout status deployment/telemetry-demo --timeout=180s
kubectl -n monitoring-demo get pods
```

Keep it at two replicas until Grafana's replica query shows **2**; allow a few
minutes and refresh. In the KQL query, confirm messages from **two distinct pod
names**. Inspect the same namespace in Container Insights.

Then restore one replica:

```bash
kubectl -n monitoring-demo scale deployment telemetry-demo --replicas=1
kubectl -n monitoring-demo rollout status deployment/telemetry-demo --timeout=180s
```

Refresh Grafana until the current replica value returns to **1**. The historical
graph should show **1 -> 2 -> 1**, provided each state lasted long enough to be
scraped. Logs from the deleted pod remain queryable during retention; a
recent-time-range KQL query can still contain both names after scale-down.

This is a controlled state change, not a load test. There is no need to exhaust
CPU/memory, crash system pods, or generate a large volume of billable logs.

</details>

## Checkpoint

You can find the sample in Container Insights, retrieve its stdout using KQL,
open a built-in Managed Grafana dashboard with Entra sign-in, query managed
Prometheus using PromQL, and observe the replica change.
Explain why the log and metric queries use different workspaces and query
languages, and identify one earlier workload visible in the cluster dashboards.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| `az grafana` is unknown | Install/update `amg`; reopen the same Bash environment used for Azure CLI |
| Onboarding command behaves differently or errors on flags | Use a current stable CLI without `aks-preview`, as required by Microsoft's onboarding guide |
| Grafana creation/linkage returns authorization errors | Check resource-creation and role-assignment permissions; do not replace identities with subscription-wide Owner |
| Agents are pending or restarting | Inspect `kube-system` pod events and available CPU/memory on the existing nodes |
| Logs query returns no rows | Confirm local stdout, both cluster/workspace selection, the copied resource ID, time range, `ContainerLogV2`, and ingestion delay |
| `ContainerLogV2` does not exist yet | Wait for the first log ingestion and check `ama-logs`; do not switch tables blindly |
| Container Insights is blank | Verify the selected AKS cluster is linked to this Log Analytics workspace and that the log agent is healthy; newly enabled views need data |
| Grafana says access denied after Entra sign-in | Check **Grafana Editor** on this Grafana resource for your tenant-local user object; re-login after propagation |
| Dashboard/Explore shows a data-source 401/403 | Check the Grafana system identity's Monitoring Data Reader assignment on the correct Azure Monitor workspace |
| Dashboard is empty but Explore works | Select the correct cluster, namespace, Prometheus data source, and time range |
| PromQL query returns no data | Confirm `ama-metrics`, Azure Monitor workspace linkage, and ingestion time; do not disable minimal ingestion |
| Replica change is missing from history | Hold each state for multiple scrape intervals and use a recent time range |
| Terraform proposes disabling add-ons | Check the single `log_analytics_workspace_id` entry in your existing tfvars before applying |

Useful diagnostics:

```bash
kubectl -n kube-system get pods
kubectl -n kube-system get events --sort-by=.lastTimestamp
kubectl -n monitoring-demo describe deployment telemetry-demo
az grafana show --resource-group "$MONITORING_RG" --name "$GRAFANA_NAME" \
  --query properties.grafanaIntegrations --output json
az monitor data-collection rule association list --resource "$AKS_ID" \
  --query '[].{name:name,rule:dataCollectionRuleId}' --output table
```

For agent logs, select a specific `ama-logs` or `ama-metrics` pod from `get pods`
and run `kubectl -n kube-system logs POD-NAME --all-containers --tail=100`.
Do not delete data collection rules or grant more roles before identifying
the failing collection/query stage.

## Finish and costs

Deleting the sample or closing Grafana does **not** stop managed monitoring
charges. Follow [Final cleanup](../../docs/cleanup.md), starting with the Lab 7
section: disable collection before deleting workspaces, remove the remaining
Container Insights rule, and delete the lab monitoring resource group.

References: [Enable AKS monitoring](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable),
[default Prometheus collection](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-default),
[link Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/how-to-connect-azure-monitor-workspace),
[disable monitoring](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-disable).

[Next: Final cleanup](../../docs/cleanup.md)
