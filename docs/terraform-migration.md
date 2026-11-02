# Adopt resources from older CLI-based labs

[Workshop home](../README.md) | [Final cleanup](cleanup.md)

New deployments can skip this page. Existing CLI-created resources from Labs
4, 6, and 7 must be **imported**, not recreated. Use the retained Lab 2 state,
subscription, prefix, region, and upgraded Kubernetes version. Do not delete
working identities, change resource names, or discard state.

Lab 3's separate [migration instructions](../labs/03-agc/README.md#migrating-an-existing-cli-based-lab-3)
cover its ALB identity.

## 1. Set inputs matching the existing deployment

Run from the repository root with the existing workshop environment loaded.
Back up the local Terraform state securely before importing; it can contain
credentials and must never be committed.

For each completed lab, add its flag and inputs to the existing
`infrastructure/terraform.tfvars`:

| Lab | Inputs |
| --- | --- |
| 4 | `enable_blob_storage = true`, existing `storage_account_name`, and the seeding user's `attendee_object_id` |
| 6 | `enable_argocd = true`, existing `argocd_sso_client_id`, and `argocd_group_object_id` |
| 7 | `enable_monitoring_resources = true`, existing `attendee_object_id`, and existing `grafana_major_version` (`11` or `12`) |

For Lab 4, recover the account name from your old `.workshop/storage.env`.
For Lab 6, recover the app and group IDs from `.workshop/entra.env`; do not
import the Entra objects or the SSO app's federated credential.
For Lab 7, retain the existing `log_analytics_workspace_id` if collection is
enabled. Do not run onboarding again just to migrate ownership.

Terraform resource names derive from `prefix` and match the original labs.
If you used different names, adjust the relevant resource configuration to
match before applying; imports alone do not change desired configuration.

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
terraform -chdir=infrastructure init
```

If a lock file pins AzureRM below 4.81, use `init -upgrade` and review the
provider change. Do not alter the subscription or delete the lock/state to
work around initialization errors.

## 2. Inspect and import the existing resources

Import one resource at a time using its **full Azure resource ID**:

```bash
terraform -chdir=infrastructure import 'RESOURCE-ADDRESS[0]' "AZURE-RESOURCE-ID"
```

Replace both placeholders with one row from the following tables. Skip rows
already listed in `terraform -chdir=infrastructure state list`.

### Lab 4

| Terraform address (append `[0]`) | Existing Azure resource |
| --- | --- |
| `azurerm_storage_account.blob` | Storage account |
| `azurerm_storage_container.labdata` | `<account-id>/blobServices/default/containers/labdata` |
| `azurerm_user_assigned_identity.blob` | Managed identity named `<prefix>-blob` |
| `azurerm_federated_identity_credential.blob` | `<identity-id>/federatedIdentityCredentials/blob-reader` |
| `azurerm_role_assignment.blob_reader` | Storage Blob Data Reader for the application on `labdata` |
| `azurerm_role_assignment.blob_uploader` | Storage Blob Data Contributor for the seeding user on `labdata` |

The container import uses its Resource Manager ID, not its blob endpoint URL.
Import the container before the roles so Terraform can resolve their scope.

### Lab 6

| Terraform address (append `[0]`) | Existing Azure resource |
| --- | --- |
| `azurerm_user_assigned_identity.argocd` | Managed identity named `<prefix>-argocd` |
| `azurerm_federated_identity_credential.argocd` | `<identity-id>/federatedIdentityCredentials/argocd-repo-server` |
| `azurerm_kubernetes_cluster_extension.argocd` | `<aks-id>/providers/Microsoft.KubernetesConfiguration/extensions/argocd` |

The extension configuration remains equivalent to the CLI-based lab. Formatting
of generated OIDC YAML can cause an in-place configuration update; inspect it
and retain the same tenant, app/group IDs, ServiceAccounts, and scoped RBAC.

### Lab 7

| Terraform address (append `[0]`) | Existing Azure resource |
| --- | --- |
| `azurerm_resource_group.monitoring` | `rg-<prefix>-monitoring` |
| `azurerm_log_analytics_workspace.lab` | `<prefix>-logs` workspace |
| `azurerm_monitor_workspace.lab` | `<prefix>-metrics` workspace |
| `azurerm_dashboard_grafana.lab` | `<prefix>-grafana` instance |
| `azurerm_role_assignment.grafana_metrics_reader` | Monitoring Data Reader for Grafana on the Azure Monitor workspace |
| `azurerm_role_assignment.grafana_editor` | Grafana Editor for the attendee on Grafana |
| `azurerm_role_assignment.logs_reader` | Log Analytics Reader for the attendee on Log Analytics |

Do not import default ingestion resources, recording rules, collection
rules/associations, or additional onboarding-created Monitoring Reader roles.
They remain Azure/CLI-managed. Terraform preserves the existing Grafana
workspace integrations rather than replacing them.

Use Azure CLI inspection commands to retrieve IDs, for example:

```bash
az resource list --resource-group "$RESOURCE_GROUP" \
  --query '[].{name:name,type:type,id:id}' --output json
az resource list --resource-group "rg-aksintro-${LAB_ID}-monitoring" \
  --query '[].{name:name,type:type,id:id}' --output json
az role assignment list --assignee-object-id "PRINCIPAL-OBJECT-ID" --all \
  --query '[].{role:roleDefinitionName,scope:scope,id:id}' --output json
```

Run only the commands for resource groups you actually created. For each role,
verify both principal and scope; do not import an inherited or unrelated role.

## 3. Review the complete plan

```bash
terraform -chdir=infrastructure plan -out=migration.tfplan
```

Expect the existing resources to be retained, with new outputs and possibly
reviewed in-place extension configuration changes. Stop if the plan proposes
creating duplicate resources, destroying/replacing storage or AKS, upgrading
Grafana unexpectedly, or removing collection. Complete missing imports or
correct mismatched inputs before proceeding.

```bash
terraform -chdir=infrastructure apply migration.tfplan
terraform -chdir=infrastructure plan
```

Expect a no-change final plan. Use the updated Terraform outputs and
[ordered cleanup](cleanup.md) from now on; retain the local state.
