# Lab 5: Persistent volumes with Azure Disks

[Home](../../README.md) | [Previous: Lab 4](../04-identity-storage/README.md)

**Goal:** Mount an Azure Disk in a web application and prove that its data
survives pod replacement.

**Time:** 30-45 minutes. **Prerequisites:** the existing Lab 2 cluster and setup
completed. Keep earlier labs running; no new cluster, Storage account,
application identity, or role assignment is needed.

## What connects to what?

```text
Pod -> PersistentVolumeClaim (PVC) -> PersistentVolume (PV) -> Azure Disk
```

| Term | What it means in this lab |
| --- | --- |
| StorageClass (`managed-csi`) | AKS-provided instructions for provisioning an Azure Disk through the CSI driver |
| PVC (`web-content`) | The application's request for 1 GiB of persistent storage |
| PV (automatically named) | The cluster resource representing the provisioned disk |
| Volume mount | Makes the disk's files available inside the container |

You create the **PVC**, not a disk or PV by hand. The Azure Disk CSI driver
provisions the disk and PV, then binds the claim. Unlike Lab 4's Blob API
access, this is a filesystem mounted into the pod.

## 1. Reconnect and inspect the manifest

<details>
<summary>Solution: existing cluster and storage settings</summary>

Run from the repository root:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
kubectl get storageclass managed-csi -o yaml
```

Open [`apps/persistent-demo/manifest.yaml`](../../apps/persistent-demo/manifest.yaml).
Find the PVC's `storageClassName`, the Deployment's `claimName`, and the web
container's mount at `/usr/share/nginx/html`. An init container writes the
initial page **only if the file does not already exist**.

The app has one replica and uses `Recreate` to avoid competing disk attachments
during updates. `ReadWriteOnce` means read/write access from **one node at a
time**, not shared storage across nodes. Keep one replica for this exercise.

</details>

## 2. Deploy and find the backing disk

Apply the manifest, wait for the web application, and trace the claim to its PV
and Azure Disk.

<details>
<summary>Solution: deploy, inspect the claim, and inspect the PV</summary>

```bash
kubectl apply -f apps/persistent-demo/manifest.yaml
kubectl -n storage-demo rollout status deployment/persistent-web --timeout=600s
kubectl -n storage-demo get pods,pvc
export LAB_PV=$(kubectl -n storage-demo get pvc web-content -o jsonpath='{.spec.volumeName}')
kubectl get pv "$LAB_PV"
kubectl get pv "$LAB_PV" -o jsonpath='{.spec.csi.driver}{"\n"}{.spec.csi.volumeHandle}{"\n"}'
```

Expect the claim and PV to be `Bound`, the driver to be `disk.csi.azure.com`,
and the volume handle to be the Azure Disk resource ID. You can find that disk
in the portal's **All resources**, usually in the AKS node resource group.

The StorageClass uses `WaitForFirstConsumer`: a claim can remain `Pending`
until a pod using it is scheduled. A 1-GiB request can be billed at the disk
SKU's minimum size; requested capacity is not an exact cost estimate.

</details>

## 3. Write data and replace the pod

Read the initial page, edit it on the disk, then delete the **pod, not the
PVC**. Compare the old and new pod names and PV names.

<details>
<summary>Solution: write, replace, and verify the same data and volume</summary>

```bash
kubectl -n storage-demo exec deployment/persistent-web -- \
  cat /usr/share/nginx/html/index.html
kubectl -n storage-demo exec deployment/persistent-web -- sh -c \
  'printf "Written before pod replacement.\n" > /usr/share/nginx/html/index.html'
kubectl -n storage-demo get pods
printf 'PV before replacement: %s\n' "$LAB_PV"
kubectl -n storage-demo delete pod -l app=persistent-web
kubectl -n storage-demo wait --for=condition=Ready pod -l app=persistent-web --timeout=600s
kubectl -n storage-demo get pods,pvc
kubectl -n storage-demo get pvc web-content -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl -n storage-demo exec deployment/persistent-web -- \
  cat /usr/share/nginx/html/index.html
```

The first read shows `Hello from a persistent Azure Disk!`. The last read must
show `Written before pod replacement.` The pod name changed, but the PVC and PV
are unchanged: the data lives on the disk, not in the deleted container.

To see the page over HTTP, start this in a **second local terminal** using the
same Kubernetes context:

```bash
kubectl config current-context
kubectl -n storage-demo port-forward service/persistent-web 8081:80
```

In the first terminal:

```bash
curl http://localhost:8081
```

Expect `Written before pod replacement.` Stop the port-forward with `Ctrl+C`.
If you replace the pod again, restart the port-forward once the new pod is ready.

</details>

## Checkpoint

You can explain the PVC -> PV -> Azure Disk relationship and have preserved an
edited page across pod replacement. **Persistent storage is not a backup**:
this exercise does not protect against disk deletion or data corruption.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| PVC stays `Pending` | Run `kubectl -n storage-demo describe pvc web-content` and `kubectl -n storage-demo describe pods`; check scheduling, node capacity, and disk quota |
| Pod reports multi-attach | Keep one replica and `Recreate`; wait for old-node detach, and do not delete the disk |
| File resets to the initial page | Confirm you deleted only the pod and wrote under `/usr/share/nginx/html`; compare the PVC/PV names |
| Port-forward stops | Restart it after the replacement pod is ready |

## Continue or stop

Keep the Deployment, PVC, and cluster for
[Lab 6: managed Argo CD and Entra ID](../06-gitops/README.md).
Deleting a pod keeps its PVC. With `managed-csi`'s default **Delete** reclaim
policy, deleting the PVC deletes the backing disk and its data. Do not delete
the claim just to restart the application.

When finished with the workshop, follow
[Final cleanup](../../docs/cleanup.md), which removes the claim while the CSI
driver is still running. Disks incur charges even when no pod uses them.

Reference: [Azure Disk CSI storage](https://learn.microsoft.com/azure/aks/azure-csi-disk-storage-provision).

[Next: Lab 6 - Managed Argo CD, GitOps, and Entra ID](../06-gitops/README.md)
