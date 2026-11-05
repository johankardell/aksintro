# Lab 4: Managed identities and Blob Storage

[Home](../../README.md) | [Previous: Lab 3](../03-agc/README.md)

**Goal:** Use an application identity to read a private blob without a password,
and confirm that read-only access does not permit writes.

**Time:** 45-60 minutes. **Prerequisites:** Lab 2 cluster and Terraform state,
preferably Lab 3 completed, Azure role-assignment permissions, and permission
to seed Blob Storage. No new cluster, SDK installation, or container build is
required.

## Which identity does what?

| Identity/storage mechanism | What it does |
| --- | --- |
| AKS cluster identity | Lets the AKS service manage Azure infrastructure |
| ALB Controller identity | Lets the controller configure AGC |
| Application Workload Identity | Exchanges a pod's projected token for an Entra token to call Azure APIs |

This lab uses the Blob Storage API, not a mounted disk. Lab 5 introduces
persistent volumes backed by Azure Disks. **A PVC does not give an application
permission to Azure Blob Storage.**

## 1. Reconnect and confirm identity support

<details>
<summary>Solution: existing cluster and OIDC issuer</summary>

Run from the repository root:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled}' \
  --output yaml
```

Both features were enabled by Terraform in Lab 2. Keep those settings in
Terraform; do not replace the cluster to enable them.

</details>

## 2. Create private Blob Storage and seed one file

Create a small LRS Storage account with public blob access and shared-key
authentication disabled. The endpoint is reachable over the network, but
access to data still requires Entra authorization.

[`infrastructure/blob.tf`](../../infrastructure/blob.tf) provisions the account,
private container, application identity, federation, and two container-scoped
data roles. **Your signed-in user** gets permission to upload the sample file;
the application gets read-only access. Azure Contributor alone does not grant
Blob data access.

<details>
<summary>Solution: provision with Terraform, then seed the sample blob</summary>

Recover your tenant-local user object ID:

```bash
export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
printf 'attendee_object_id = "%s"\n' "$USER_OBJECT_ID"
```

Add that value and `enable_blob_storage = true` to the existing
`infrastructure/terraform.tfvars`, preserving all earlier inputs. The default
account name is stable and derived from the subscription and attendee prefix.
If Azure reports a global name collision, set `storage_account_name` to another
valid, unique name before retrying. Do not change an existing account's name
after it contains data: that would replace it.

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure fmt -check
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=blob.tfplan
```

Expect **six additions** and no AKS replacement or unrelated changes. Review
the roles: the user gets Storage Blob Data Contributor and the application
gets Storage Blob Data Reader, both on `labdata` only.

```bash
terraform -chdir=infrastructure apply blob.tfplan
export STORAGE_ACCOUNT=$(terraform -chdir=infrastructure output -raw storage_account_name)
export BLOB_CLIENT_ID=$(terraform -chdir=infrastructure output -raw blob_client_id)
printf 'Read from Blob Storage using Workload Identity.\n' > .workshop/message.txt
az storage blob upload --account-name "$STORAGE_ACCOUNT" \
  --container-name labdata --name message.txt --file .workshop/message.txt \
  --auth-mode login --overwrite
```

If upload returns `AuthorizationPermissionMismatch` immediately after the role
assignment, wait several minutes and retry the upload. Do not enable shared
keys to work around propagation. If tenant policy blocks querying your user
object ID, have the instructor supply it. An instructor can seed the blob if
you cannot upload it; do not grant the application write access.

On resuming, recover both values with the same Terraform output commands;
`.workshop/storage.env` is no longer needed. Terraform uses the Resource Manager
API to create the container, so account keys stay disabled. The blob's contents
are deliberately seeded with CLI, not stored in Terraform state.

</details>

## 3. Inspect the least-privilege application identity

Inspect the dedicated identity in `blob.tf`. It federates only
`system:serviceaccount:identity-demo:blob-reader` and receives **Storage Blob Data
Reader** on the single container, not Contributor on the subscription.

<details>
<summary>Solution: inspect the identity and verify repeatability</summary>

```bash
terraform -chdir=infrastructure state show 'azurerm_federated_identity_credential.blob[0]'
terraform -chdir=infrastructure state show 'azurerm_role_assignment.blob_reader[0]'
terraform -chdir=infrastructure plan
```

Expect the exact ServiceAccount subject, the existing AKS issuer,
`api://AzureADTokenExchange`, the container-scoped reader role, and a no-change
plan. Allow a few minutes for federation and permissions to propagate.

The **client ID** goes on the ServiceAccount. The **principal/object ID** is
used for Azure role assignments. They are different IDs.

</details>

## 4. Deploy a pod that can use the identity

Use an Azure CLI container so that you can inspect the authentication flow
without building an application. The pod template label enables token
injection; the ServiceAccount annotation selects the identity.

<details>
<summary>Solution: ServiceAccount and identity-enabled deployment</summary>

```bash
kubectl create namespace identity-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blob-reader
  namespace: identity-demo
  annotations:
    azure.workload.identity/client-id: "$BLOB_CLIENT_ID"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blob-reader
  namespace: identity-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: blob-reader
  template:
    metadata:
      labels:
        app: blob-reader
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: blob-reader
      containers:
        - name: cli
          image: mcr.microsoft.com/azure-cli:2.78.0
          command: ["/bin/sh", "-c", "sleep 86400"]
          env:
            - name: STORAGE_ACCOUNT
              value: "$STORAGE_ACCOUNT"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF
kubectl -n identity-demo rollout status deployment/blob-reader --timeout=300s
kubectl -n identity-demo describe deployment blob-reader
```

Do not print or copy the projected token. It is a short-lived credential.
The Azure CLI is installed **inside this image**; no extra local SDK is needed.

</details>

## 5. Authenticate inside the pod and read the blob

The Azure CLI needs an explicit federated login. Application SDKs would
normally perform this exchange through a credential library.

<details>
<summary>Solution: exchange the projected token and download the private blob</summary>

```bash
kubectl -n identity-demo exec deployment/blob-reader -- sh -c '
  az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --tenant "$AZURE_TENANT_ID" \
    --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" \
    --allow-no-subscriptions --output none &&
  az storage blob download --account-name "$STORAGE_ACCOUNT" \
    --container-name labdata --name message.txt --file /tmp/message.txt \
    --auth-mode login --no-progress --only-show-errors --output none &&
  cat /tmp/message.txt
'
```

Expect `Read from Blob Storage using Workload Identity.` There is no client
secret, account key, or connection string in the manifest.
`--allow-no-subscriptions` is appropriate because this identity has a
container-scoped data role, not subscription-wide resource access.

Now attempt a write using the same identity:

```bash
kubectl -n identity-demo exec deployment/blob-reader -- \
  az storage blob upload --account-name "$STORAGE_ACCOUNT" \
  --container-name labdata --name forbidden.txt --file /tmp/message.txt \
  --auth-mode login --overwrite
```

Expect authorization failure: **reader is not writer**. If it succeeds, inspect
inherited Azure role assignments and correct the identity's excessive access.
This expected denial is part of the exercise, not a lab setup error.

</details>

## Checkpoint

You have read a private blob without stored credentials, demonstrated a denied
write, and distinguished the application identity from the cluster identity.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| `AZURE_FEDERATED_TOKEN_FILE` is missing | Check the label on the **pod template**, the ServiceAccount annotation, and cluster Workload Identity; restart the Deployment after correcting configuration |
| `AADSTS70021` / no matching federated identity | Compare exact issuer, namespace, ServiceAccount name, subject, and audience; allow federation propagation |
| Blob read gets 403 after successful login | Check the reader role's principal and container scope; allow propagation and retry the login/read block |
| `KeyBasedAuthenticationNotPermitted` | Use `--auth-mode login`; do not enable keys |

## Continue or stop

Keep the identity, Blob Storage, and cluster, and continue to
[Lab 5: persistent volumes with Azure Disks](../05-persistent-volumes/README.md).
Use [Final cleanup](../../docs/cleanup.md) only when you are finished.

Reference: [AKS Workload Identity](https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster).

[Next: Lab 5 - Persistent volumes with Azure Disks](../05-persistent-volumes/README.md)
