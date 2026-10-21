# Final cleanup

[Workshop home](../README.md)

**These steps delete lab resources and data.** Do not run them when continuing
to another lab. Check every subscription, cluster context, resource group, and
Entra object ID before confirming deletion.

Run from the repository root. Perform only the sections for labs you actually
completed. If an object is already gone, verify that fact and skip its command;
do not hide unexpected authorization or dependency errors.

## 1. Recover the correct cluster settings

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
export AKS_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query id -o tsv)
export MC_RG=$(terraform -chdir=infrastructure output -raw node_resource_group_name)
export AGC_SUBNET_ID=$(terraform -chdir=infrastructure output -raw agc_subnet_id)
export MC_RG_ID=$(az group show --name "$MC_RG" --query id -o tsv)
az account show --query '{subscription:name,id:id}' -o table
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
az group show --name "$RESOURCE_GROUP" --query '{name:name,location:location}' -o table
```

If you completed **only Lab 1**, use its portal resource-group cleanup instead;
you will not have Terraform outputs.

Stop port-forwards in their terminals with `Ctrl+C`.

## 2. Stop monitoring and remove the monitoring resources

For Lab 6, inspect the collection rules associated with **this cluster** before
disabling collection. Container Insights leaves its rule behind when its
association is removed, so record that specific rule's ID first:

```bash
export MONITORING_RG="rg-aksintro-${LAB_ID}-monitoring"
az monitor data-collection rule association list --resource "$AKS_ID" \
  --query '[].{name:name,rule:dataCollectionRuleId}' --output table
export CI_DCR_ID=$(az monitor data-collection rule association show \
  --resource "$AKS_ID" --name ContainerInsightsExtension \
  --query dataCollectionRuleId -o tsv)
az resource show --ids "$CI_DCR_ID" \
  --query '{name:name,id:id,destinations:properties.destinations}' --output json
```

Verify the rule is the lab's Container Insights rule, named like
`MSCI-<region>-<cluster>`, and points to your lab Log Analytics workspace.
If collection was already disabled during troubleshooting, inspect the
remaining rules in the cluster resource group and recover this exact ID before
deleting anything:

```bash
az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type Microsoft.Insights/dataCollectionRules --output table
```

For a fully completed lab, stop both collection paths before deleting their
destinations:

```bash
kubectl delete namespace monitoring-demo
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --disable-azure-monitor-metrics
az aks disable-addons --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --addons monitoring
az resource delete --ids "$CI_DCR_ID"
```

The managed Prometheus disable command removes its cluster-specific rules,
associations, endpoint, and recording rules. The explicit resource deletion
removes the now-unassociated Container Insights rule. Do not delete rules used
by another cluster, or manually delete the Azure Monitor workspace's default
ingestion resources.

Remove the `log_analytics_workspace_id` line added in Lab 6 from
`infrastructure/terraform.tfvars` (or set it to `null`) so Terraform no longer
expects the add-ons to be enabled. Keep all other inputs and state.

Review and delete only the dedicated lab monitoring resource group:

```bash
az resource list --resource-group "$MONITORING_RG" --output table
az group delete --name "$MONITORING_RG"
```

This deletes Managed Grafana, Log Analytics, the Azure Monitor workspace, and
their resource-scoped role assignments. Azure also deletes the Azure Monitor
workspace's `MA_..._managed` resource group. Prometheus data is irrecoverable
when the workspace is deleted; Log Analytics normally uses soft deletion.
Retained telemetry is not a backup of your application's persistent data.
Closing a dashboard or deleting the sample alone would not stop these charges.

## 3. Remove the GitOps application before its controller

For Lab 5:

```bash
kubectl -n argocd delete application aksintro-demo
kubectl -n argocd delete appproject aksintro
kubectl delete namespace gitops-demo
az k8s-extension delete --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$AKS_NAME" --cluster-type managedClusters --name argocd
```

The sample Application has no cascading-deletion finalizer, so deleting it alone
does not delete its workloads; we explicitly delete the lab namespace.
Uninstalling the managed extension, rather than running Helm uninstall, lets
Azure manage its lifecycle correctly. Review the extension-deletion prompt.

## 4. Remove persistent storage while the CSI driver is running

For Lab 4, first copy out any file you want to keep:

```bash
kubectl -n storage-demo exec deployment/persistent-web -- \
  cat /usr/share/nginx/html/index.html > .workshop/saved-page.txt
kubectl -n storage-demo get pvc web-content -o wide
export LAB_PV=$(kubectl -n storage-demo get pvc web-content -o jsonpath='{.spec.volumeName}')
kubectl get pv "$LAB_PV" -o yaml
```

The default `managed-csi` class uses reclaim policy **Delete**. Deleting its
claim deletes the backing Azure Disk and stored data. A `Retain` policy, if your
environment changed it, requires separate disk cleanup after data review.

```bash
kubectl -n storage-demo delete deployment persistent-web --cascade=foreground --wait=true
kubectl -n storage-demo delete pvc web-content
kubectl wait --for=delete "pv/$LAB_PV" --timeout=600s
kubectl delete namespace storage-demo
kubectl delete namespace identity-demo
```

Wait for PV deletion before deleting AKS; do not remove storage finalizers to
force completion. If a volume remains, inspect events, reclaim policy, and the
Azure Disk before continuing.

For the Blob Storage exercise, optionally download the sample file before
deleting the storage account:

```bash
source .workshop/storage.env
az storage account show --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" --query '{name:name,id:id}' -o table
az storage account delete --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT"
```

This deletes all blobs in that account. Confirm only your lab account.

## 5. Let ALB Controller delete AGC before removing the controller

For Lab 3, remove the route and Gateway first, then the ApplicationLoadBalancer.
Its finalizer needs the running controller and its Azure permissions.

```bash
kubectl -n demo delete httproute demo-route
kubectl -n demo delete gateway demo-gateway
kubectl -n alb-infra delete applicationloadbalancer workshop-alb
kubectl -n alb-infra get applicationloadbalancers
az resource list --resource-group "$MC_RG" \
  --resource-type Microsoft.ServiceNetworking/trafficControllers --output table
```

Wait until there are no workshop traffic-controller resources in that list.
If deletion is stuck, inspect ALB Controller logs and its role assignments.
**Do not uninstall the controller, delete its identity, remove finalizers, or
destroy the subnet while its Azure resources still exist.**

Once deletion completes:

```bash
kubectl delete namespace alb-infra
helm uninstall alb-controller --namespace azure-alb-system
```

## 6. Remove extra Azure role assignments and managed identities

Terraform owns the cluster identity and its subnet assignment. Do not remove
those manually. The following identities were created by the lab commands.

For the **Lab 3 ALB identity**, remove its role assignments before deleting it.
The subnet-scoped assignment must be removed before Terraform deletes that
subnet:

```bash
export ALB_IDENTITY_NAME="aksintro-${LAB_ID}-alb"
export ALB_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" \
  --name "$ALB_IDENTITY_NAME" --query principalId -o tsv)
az role assignment list --assignee-object-id "$ALB_PRINCIPAL_ID" --all -o table
az role assignment delete --assignee "$ALB_PRINCIPAL_ID" \
  --role Reader --scope "$MC_RG_ID"
az role assignment delete --assignee "$ALB_PRINCIPAL_ID" \
  --role "AppGw for Containers Configuration Manager" --scope "$MC_RG_ID"
az role assignment delete --assignee "$ALB_PRINCIPAL_ID" \
  --role "Network Contributor" --scope "$AGC_SUBNET_ID"
az identity delete --resource-group "$RESOURCE_GROUP" --name "$ALB_IDENTITY_NAME"
```

For **Lab 4**, the container-scoped data-role assignments disappear with the
storage account. After deleting it, remove the application's managed identity:

```bash
az identity delete --resource-group "$RESOURCE_GROUP" --name "aksintro-${LAB_ID}-blob"
```

For **Lab 5**, remove its separate managed identity after extension deletion:

```bash
az identity delete --resource-group "$RESOURCE_GROUP" --name "aksintro-${LAB_ID}-argocd"
```

Federated credentials on each managed identity are removed with that identity.

## 7. Destroy Terraform-managed infrastructure

For Labs 2-6:

```bash
terraform -chdir=infrastructure plan -destroy -out=destroy.tfplan
terraform -chdir=infrastructure apply destroy.tfplan
terraform -chdir=infrastructure state list
```

Review the destroy plan before applying. Expect AKS, the network, cluster
identity, role assignment, and training resource group to be removed. AKS
deletes its node resource group. `state list` should be empty afterward.

If resource-group deletion is blocked by an unmanaged lab resource, inspect
the resource group, complete that resource's cleanup, then generate a new
destroy plan. Do not work around failures by deleting the state file.

## 8. Delete Entra objects separately

For Lab 5, only if **you created** the app registration and group:

```bash
source .workshop/entra.env
az ad app show --id "$SSO_APP_ID" --query '{name:displayName,clientId:appId}' -o table
az ad group show --group "$ARGOCD_GROUP_ID" --query '{name:displayName,id:id}' -o table
```

Verify that these are your lab objects, not shared instructor objects. Then:

```bash
az ad sp delete --id "$SSO_APP_ID"
az ad app delete --id "$SSO_APP_ID"
az ad group delete --group "$ARGOCD_GROUP_ID"
```

The app's federated credential is removed with the app registration. Deleting
an Azure resource group or running `terraform destroy` does **not** remove
these directory objects.

## 9. Verify that billing resources are gone

```bash
az group exists --name "$RESOURCE_GROUP"
az group exists --name "$MC_RG"
az group exists --name "rg-aksintro-${LAB_ID}-portal"
az group exists --name "rg-aksintro-${LAB_ID}-monitoring"
az group exists --name "MA_aksintro-${LAB_ID}-metrics_${LOCATION}_managed"
```

Expect `false` for all workshop groups you created. Review **All resources**
filtered to your lab names in the portal for unexpected leftovers, especially
disks, public IPs, Storage accounts, AGC, Managed Grafana, monitoring workspaces,
and orphaned data collection rules/endpoints.

Retain state until cleanup succeeds. Afterward, remove saved plans, stale local
settings, and old kubeconfig contexts as appropriate. Do not delete unrelated
contexts or shared Azure resources, unregister subscription-wide providers, or
remove software needed by other work.
