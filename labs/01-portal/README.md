# Lab 1: Your first cluster in the Azure portal

[Home](../../README.md) | [Setup](../../docs/00-setup.md) | [Next: Lab 2](../02-terraform/README.md)

**Goal:** Create a simple AKS cluster without writing infrastructure code, deploy
a web application, and access it over a public IP.

**Time:** 45-60 minutes. **Prerequisites:** setup completed; Azure CLI and
`kubectl` installed. Terraform and Helm are not used yet.

**Before starting:** create your local `.workshop/env.sh` file using
[Setup guide, section 4: Get the repository and save your settings](../../docs/00-setup.md#4-get-the-repository-and-save-your-settings).
Use the saved `LAB_ID` and `LOCATION` when creating the portal cluster below.
The file stays local and must not be committed to Git.

## What you are building

```text
Browser -> public LoadBalancer Service -> demo pod on an AKS node
```

AKS manages the Kubernetes control plane. You pay for the VM nodes and related
resources. A Deployment keeps your application running; a Service exposes it.

## 1. Create the cluster

In the Azure portal, find **Kubernetes services** and create a Kubernetes
cluster. Choose the simplest development/test preset available. Portal labels
change; the following settings matter more than matching a screenshot.

<details>
<summary>Solution: portal settings</summary>

1. Select your training subscription.
2. Create a resource group named `rg-aksintro-YOUR-LAB-ID-portal`.
3. Name the cluster `aksintro-YOUR-LAB-ID-portal`.
4. Use the agreed training region and the default supported Kubernetes version.
5. Select a development/test preset and the **Free** control-plane pricing tier.
6. Use a Linux system node pool with two nodes. Select an available
   system-pool-compatible VM with at least 4 vCPUs and 4 GiB of memory, such as
   `Standard_D4s_v5` (4 vCPUs / 16 GiB). Do not use a B-series VM.
7. Keep the default managed identity and default networking. Use a **public**
   API endpoint. Do not add AGC, private endpoints, or optional integrations.
8. If shown, select Kubernetes RBAC with local accounts for this introductory
   cluster. Do not select automatic/fully managed provisioning if it hides the
   standard cluster settings used here.
9. Review optional monitoring services and their costs; no paid monitoring
   integration is needed for this exercise.
10. Select **Review + create**, read the validation results, then **Create**.

Wait until deployment completes. Record the resource group, cluster name, and
Kubernetes version. Azure also creates an `MC_...` **node resource group** for
VMs, disks, and networking; do not manually edit those managed resources.

</details>

## 2. Connect from your terminal

Return to the repository root, load your settings, select the subscription, and
download cluster credentials. Confirm that `kubectl` targets the new cluster.

If `.workshop/env.sh` is missing, create it using
[Setup guide, section 4](../../docs/00-setup.md#4-get-the-repository-and-save-your-settings)
before running the commands below. Set `LAB_ID` and `LOCATION` to match the
portal cluster you just created.

<details>
<summary>Solution: login, credentials, and nodes</summary>

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export PORTAL_RG="rg-aksintro-${LAB_ID}-portal"
export PORTAL_AKS="aksintro-${LAB_ID}-portal"
az aks get-credentials --resource-group "$PORTAL_RG" --name "$PORTAL_AKS" --overwrite-existing
kubectl config current-context
kubectl get nodes
```

Expect two nodes in `Ready` state. `get-credentials` updates the local
`~/.kube/config` file; it does not create the cluster. Keep that file private.
If the cluster uses Entra authentication due to tenant policy, follow the
instructor's login instructions and use `kubelogin` from setup rather than
trying to bypass the policy.

</details>

## 3. Deploy the sample workload

Inspect [`apps/demo/manifest.yaml`](../../apps/demo/manifest.yaml). Identify the
Deployment, container image, readiness probe, and Service.

Create a `demo` namespace, deploy there, and wait for the pod to become ready.
The sample leaves namespace selection to the caller so Lab 6 can reuse it in a
separate namespace. GitOps is not involved yet.

<details>
<summary>Solution: deploy and inspect the web application</summary>

```bash
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n demo apply -f apps/demo/manifest.yaml
kubectl -n demo rollout status deployment/demo --timeout=180s
kubectl -n demo get deployments,pods,services
kubectl -n demo logs deployment/demo
```

`READY 1/1` indicates a ready pod. The Service selects pods with label
`app: demo`, and forwards port 80 to the named container port `http` (5678).

</details>

## 4. Expose it through a public Service

The checked-in Service is `ClusterIP`, reachable inside Kubernetes. Change its
type to `LoadBalancer` and wait for Azure to allocate an external IP.

<details>
<summary>Solution: public endpoint and browser test</summary>

```bash
kubectl -n demo patch service demo \
  --type merge --patch '{"spec":{"type":"LoadBalancer"}}'
kubectl -n demo get service demo --watch
```

Wait until `EXTERNAL-IP` is an IP address, not `<pending>`, then press `Ctrl+C`.
This can take several minutes.

```bash
export DEMO_IP=$(kubectl -n demo get service demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl "http://${DEMO_IP}"
```

Open `http://YOUR-EXTERNAL-IP` in a browser. Expect:

```text
Hello from AKS! Version 1
```

Use **HTTP**, not HTTPS. This public lab endpoint has no TLS certificate. Do
not submit credentials or sensitive data to it.

</details>

## 5. Observe Kubernetes replacing a pod

Delete only the demo pod, then watch the Deployment create its replacement.
Does the public Service IP change?

<details>
<summary>Solution: replacement pod, stable Service</summary>

```bash
kubectl -n demo get pods -l app=demo
kubectl -n demo delete pod -l app=demo
kubectl -n demo rollout status deployment/demo --timeout=180s
kubectl -n demo get pods,services
curl "http://${DEMO_IP}"
```

The replacement pod has a new name; the Service retains its IP. A brief
interruption is possible because this demo has one replica.

</details>

## Checkpoint

You can identify the cluster's resource groups, see a ready node, reach the
demo over HTTP, and explain why deleting a pod does not delete its Deployment.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| Portal deployment fails | Open deployment operation details; check quota, region/SKU availability, permissions, and Azure Policy |
| Node is `NotReady` | Wait for initial provisioning; inspect `kubectl describe node NODE-NAME` if it persists |
| Pod is `Pending` | `kubectl -n demo describe pod POD-NAME`; look for CPU/memory or scheduling errors |
| `ImagePullBackOff` | Describe the pod; check registry egress and image availability before changing the manifest |
| External IP stays pending | Describe the Service; inspect Azure permissions, public-IP quota, and policy |
| Browser cannot connect | Use HTTP, confirm the external IP and `kubectl -n demo get endpointslices`, then check pod readiness |

## Cleanup before Lab 2

This cluster is intentionally disposable. Lab 2 creates a new cluster under
Terraform rather than importing portal-created resources.

<details>
<summary>Solution: delete only this lab's portal resource group</summary>

Confirm the displayed name is your **portal** resource group:

```bash
az group show --name "$PORTAL_RG" --query '{name:name,location:location}' -o table
az group delete --name "$PORTAL_RG"
```

Review the prompt and confirm. Wait for deletion to finish before provisioning
Lab 2 so that quota is released. AKS removes its node resource group as part of
cluster deletion.

</details>

[Continue to Lab 2](../02-terraform/README.md).
