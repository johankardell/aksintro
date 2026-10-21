# Lab 4: Managed identities and persistent volumes

[Home](../../README.md) | [Previous: Lab 3](../03-agc/README.md) | [Next: Lab 5](../05-gitops/README.md)

**Goal:** Use an application identity to read a private blob without a password,
and prove that a persistent volume survives pod replacement.

**Time:** 75-90 minutes. **Prerequisites:** Lab 2 cluster, preferably Lab 3
completed, Azure role-assignment permissions, and permission to seed Blob
Storage. No new cluster, SDK installation, or container build is required.

## Two separate concepts

| Identity/storage mechanism | What it does |
| --- | --- |
| AKS cluster identity | Lets the AKS service manage Azure infrastructure |
| ALB Controller identity | Lets the controller configure AGC |
| Application Workload Identity | Exchanges a pod's projected token for an Entra token to call Azure APIs |
| Azure Disk CSI driver and PVC | Provision and attach storage to a pod |

**A PVC does not give an application permission to Azure Blob Storage.** The
blob exercise and disk exercise are deliberately separate, so you can see
which identity and storage mechanism is responsible for each result.

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

## 6. Deploy a web application with a persistent volume

Inspect [`apps/persistent-demo/manifest.yaml`](../../apps/persistent-demo/manifest.yaml).
It requests an Azure Disk through the AKS-provided `managed-csi` StorageClass.
The init container writes an initial page **only if it does not already exist**.

<details>
<summary>Solution: claim, web deployment, and first request</summary>

```bash
kubectl get storageclass managed-csi -o yaml
kubectl apply -f apps/persistent-demo/manifest.yaml
kubectl -n storage-demo rollout status deployment/persistent-web --timeout=600s
kubectl -n storage-demo get pods,pvc
kubectl get pv
```

Expect the claim `web-content` to be `Bound`. The StorageClass uses
`WaitForFirstConsumer`, so a newly created PVC can remain `Pending` until a pod
that uses it is scheduled. A 1-GiB request can be billed at the disk SKU's minimum
size; requested size is not an exact cost estimate.

In a **second local terminal**, load settings and start a port-forward:

```bash
source .workshop/env.sh
kubectl config current-context
kubectl -n storage-demo port-forward service/persistent-web 8081:80
```

Keep it running. From the first terminal:

```bash
curl http://localhost:8081
```

Expect `Hello from a persistent Azure Disk!`.

</details>

## 7. Prove persistence across pod replacement

Change the served file on the mounted volume, record the PVC/PV, and delete the
pod, **not the PVC**. Verify the new pod serves the same file from the same disk.

<details>
<summary>Solution: write, replace, reconnect, and verify</summary>

```bash
kubectl -n storage-demo exec deployment/persistent-web -- sh -c \
  'printf "Written before pod replacement.\n" > /usr/share/nginx/html/index.html'
kubectl -n storage-demo get pods,pvc
kubectl -n storage-demo get pvc web-content -o jsonpath='{.spec.volumeName}{"\n"}'
curl http://localhost:8081
kubectl -n storage-demo delete pod -l app=persistent-web
kubectl -n storage-demo rollout status deployment/persistent-web --timeout=600s
kubectl -n storage-demo get pods,pvc
kubectl -n storage-demo get pvc web-content -o jsonpath='{.spec.volumeName}{"\n"}'
```

The new pod has a different name; the PVC and backing PV are unchanged.
Port-forwards target a particular pod and can stop when it is replaced.
Stop/restart the port-forward in the second terminal:

```bash
kubectl -n storage-demo port-forward service/persistent-web 8081:80
```

Then, in the first terminal:

```bash
curl http://localhost:8081
```

Expect `Written before pod replacement.`, not the initial page.

`ReadWriteOnce` means the disk can be mounted read/write by one node at a time;
it is not multi-node shared storage. This one-replica demo uses a `Recreate`
deployment strategy to avoid competing disk attachments during updates.
Do not scale it to several nodes. Persistent storage is also **not a backup**.

</details>

## Checkpoint

You have read a private blob without stored credentials, demonstrated a denied
write, and preserved an edited web page across pod replacement.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| `AZURE_FEDERATED_TOKEN_FILE` is missing | Check the label on the **pod template**, the ServiceAccount annotation, and cluster Workload Identity; restart the Deployment after correcting configuration |
| `AADSTS70021` / no matching federated identity | Compare exact issuer, namespace, ServiceAccount name, subject, and audience; allow federation propagation |
| Blob read gets 403 after successful login | Check the reader role's principal and container scope; allow propagation and retry the login/read block |
| `KeyBasedAuthenticationNotPermitted` | Use `--auth-mode login`; do not enable keys |
| PVC remains pending | Describe PVC and pod; `WaitForFirstConsumer` is normal before scheduling, but insufficient node capacity or Azure disk quota is not |
| Pod reports multi-attach | Ensure one replica, wait for old-node detach, and retain `Recreate`; do not delete the disk |
| File disappears after restart | Check that you deleted only the pod and wrote under the mounted path; inspect PVC/PV names |
| Port-forward stops after deletion | Restart it against the Service once the replacement pod is ready |

## Continue or stop

Keep the identity, storage, and cluster for Lab 5. Stop the localhost
port-forward with `Ctrl+C` when finished testing.

Deleting a pod retains its PVC. Deleting the PVC with the default `Delete`
reclaim policy deletes the backing disk and data. Use
[Final cleanup](../../docs/cleanup.md) only when you are finished.

References: [AKS Workload Identity](https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster),
[Azure Disk CSI storage](https://learn.microsoft.com/azure/aks/azure-csi-disk-storage-provision).
