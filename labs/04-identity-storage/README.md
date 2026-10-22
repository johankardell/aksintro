# Lab 4: Managed identities and Blob Storage

[Home](../../README.md) | [Previous: Lab 3](../03-agc/README.md)

**Goal:** Use an application identity to read a private blob without a password,
and confirm that read-only access does not permit writes.

**Time:** 45-60 minutes. **Prerequisites:** Lab 2 cluster, preferably Lab 3
completed, Azure role-assignment permissions, and permission to seed Blob
Storage. No new cluster, SDK installation, or container build is required.

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
export OIDC_ISSUER=$(terraform -chdir=infrastructure output -raw oidc_issuer_url)
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

Give **your signed-in user** permission to upload the sample file. Azure
Contributor alone does not grant Blob data access.

<details>
<summary>Solution: Storage account, private container, and sample blob</summary>

Generate a globally unique account name once and save it for resuming:

```bash
export STORAGE_ACCOUNT="staks$(date +%s)${RANDOM}"
printf 'export STORAGE_ACCOUNT="%s"\n' "$STORAGE_ACCOUNT" > .workshop/storage.env
az storage account create --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --allow-shared-key-access false \
  --min-tls-version TLS1_2
export STORAGE_ID=$(az storage account show --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" --query id -o tsv)
az storage container-rm create --storage-account "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" --name labdata --public-access off
export CONTAINER_SCOPE="${STORAGE_ID}/blobServices/default/containers/labdata"
export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User --role "Storage Blob Data Contributor" \
  --scope "$CONTAINER_SCOPE"
printf 'Read from Blob Storage using Workload Identity.\n' > .workshop/message.txt
az storage blob upload --account-name "$STORAGE_ACCOUNT" \
  --container-name labdata --name message.txt --file .workshop/message.txt \
  --auth-mode login --overwrite
```

If upload returns `AuthorizationPermissionMismatch` immediately after the role
assignment, wait several minutes and retry the upload. Do not enable shared
keys to work around propagation. If tenant policy blocks querying your user
object ID, have the instructor supply that tenant-local ID or seed the file.

On resuming, run `source .workshop/storage.env`; do not generate another account
name. The storage account and container were created with CLI, not Terraform.

</details>

## 3. Create a least-privilege application identity

Create a dedicated identity and federate only
`system:serviceaccount:identity-demo:blob-reader`. Give it **Storage Blob Data
Reader** on the single container, not Contributor on the subscription.

<details>
<summary>Solution: managed identity, role, and federated credential</summary>

```bash
export BLOB_IDENTITY_NAME="aksintro-${LAB_ID}-blob"
az identity create --resource-group "$RESOURCE_GROUP" \
  --name "$BLOB_IDENTITY_NAME" --location "$LOCATION"
export BLOB_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" \
  --name "$BLOB_IDENTITY_NAME" --query clientId -o tsv)
export BLOB_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" \
  --name "$BLOB_IDENTITY_NAME" --query principalId -o tsv)
az role assignment create --assignee-object-id "$BLOB_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" --scope "$CONTAINER_SCOPE"
az identity federated-credential create --name blob-reader \
  --identity-name "$BLOB_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
  --issuer "$OIDC_ISSUER" \
  --subject system:serviceaccount:identity-demo:blob-reader \
  --audiences api://AzureADTokenExchange
```

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
