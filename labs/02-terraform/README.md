# Lab 2: Terraform, a virtual network, and a Kubernetes upgrade

[Home](../../README.md) | [Previous: Lab 1](../01-portal/README.md) | [Next: Lab 3](../03-agc/README.md)

**Goal:** Provision a repeatable AKS environment in your own VNet, deploy the
demo again, and upgrade an older supported Kubernetes version.

**Time:** 90-120 minutes. **Prerequisites:** setup completed, Terraform installed,
Lab 1 cluster deleted, permission to create resources and assign Azure roles.

## What you are building

```text
VNet: 10.0.0.0/16
  aks subnet: 10.0.0.0/22 -> two AKS nodes and Azure CNI pod IPs
  agc subnet: 10.0.4.0/24 -> reserved/delegated for Lab 3

Kubernetes Service range: 10.2.0.0/16 (virtual IPs, not a VNet subnet)
```

The example uses **Azure CNI with VNet-addressed pods**, not kubenet. The ranges
do not overlap. A cluster in a VNet can still have a public API endpoint; this is
not a private-cluster lab.

Terraform describes desired Azure resources in `.tf` files. `plan` previews
changes, `apply` performs them, and local **state** records what Terraform owns.
Do not delete state while the resources still exist.

## 1. Read the Terraform solution

Inspect the files in [`infrastructure/`](../../infrastructure/):

- `main.tf`: provider, resource group, VNet, two subnets, cluster identity,
  subnet role assignment, and AKS.
- `variables.tf`: subscription, naming prefix, region, VM size, Kubernetes version,
  and the optional Lab 7 monitoring workspace.
- `outputs.tf`: values used to connect and to complete subsequent labs.

Find why the cluster depends on the subnet role assignment and why the AGC
subnet is not shared with nodes.

<details>
<summary>Solution: design choices</summary>

The cluster uses a user-assigned managed identity. That identity receives
Network Contributor on the **AKS subnet** before AKS provisioning starts, so AKS
can use the custom network. This is the cluster identity, not an application
identity.

The separate AGC `/24` has the required
`Microsoft.ServiceNetworking/trafficControllers` delegation. It is reserved now
to avoid redesigning the network in Lab 3, but no AGC gateway is billed yet.

Two small nodes leave room for the later controllers and applications. OIDC and
Workload Identity are enabled now because ALB Controller needs them in Lab 3;
you will explore application identities in Lab 4.

The AzureRM provider's automatic resource-provider registration is disabled.
The setup guide explicitly registers the providers, making permissions and
registration failures easier to understand.

</details>

## 2. Supply your variables

Run from the repository root. Generate your own ignored `terraform.tfvars`.
The checked-in `.example` file shows an alternative you can copy and edit.

<details>
<summary>Solution: attendee-specific inputs</summary>

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
cat > infrastructure/terraform.tfvars <<EOF
subscription_id    = "$SUBSCRIPTION_ID"
prefix             = "aksintro-$LAB_ID"
location           = "$LOCATION"
node_vm_size       = "Standard_D4s_v5"
kubernetes_version = "$K8S_VERSION"
EOF
```

If the instructor selected another VM size, change `node_vm_size` before
planning. `K8S_VERSION` must be the older supported patch selected during setup,
not the placeholder. Keep the naming, region, and networking unchanged for Labs
2-6; you will deliberately change the version later in this lab.

</details>

## 3. Initialize, preview, and create

Initialize Terraform, check formatting and configuration, then save a plan.
Read the plan before applying it. Do not use `-auto-approve` for this exercise.

<details>
<summary>Solution: Terraform workflow</summary>

```bash
terraform -chdir=infrastructure init
terraform -chdir=infrastructure fmt -check
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=lab.tfplan
terraform -chdir=infrastructure apply lab.tfplan
```

`-chdir` keeps the working directory, state, and generated files under
`infrastructure/`. Initial provisioning can take 10-20 minutes. Applying a saved
plan does not ask again: reviewing `plan` is the approval step.

If `fmt -check` lists a file you edited, run
`terraform -chdir=infrastructure fmt`, then repeat the check.

The included `.terraform.lock.hcl` pins the selected provider version. Keep it
for repeatability; if you intentionally update providers later, review and
commit the changed lock file in your own fork. Do not commit
`.terraform/`, `terraform.tfvars`, state, or saved plans. State can contain
cluster credentials even though they are not printed as outputs.

If apply fails, read the actual error and fix its cause, then create a **new**
plan and apply it. Terraform normally retains successful partial work; do not
delete the state or start over in a new directory.

</details>

## 4. Connect and inspect the network

Recover the names from Terraform outputs, connect, and inspect the subnet.

<details>
<summary>Solution: connect to the Terraform cluster</summary>

```bash
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes -o wide
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{network:networkProfile.networkPlugin,subnet:agentPoolProfiles[0].vnetSubnetId,oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled}' \
  --output yaml
```

Expect two `Ready` nodes, network plugin `azure`, your AKS subnet ID, and both
identity features enabled. Compare the node IPs with `10.0.0.0/22`.

</details>

## 5. Deploy and expose the demo

Use the same manifest as Lab 1. The manifest remains ClusterIP in Git; patch it
only in this pre-GitOps cluster to obtain a temporary public endpoint.

<details>
<summary>Solution: application and public IP</summary>

```bash
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n demo apply -f apps/demo/manifest.yaml
kubectl -n demo rollout status deployment/demo --timeout=180s
kubectl -n demo get pods -o wide
kubectl -n demo patch service demo \
  --type merge --patch '{"spec":{"type":"LoadBalancer"}}'
kubectl -n demo get service demo --watch
```

Once an external IP appears, press `Ctrl+C`, then:

```bash
export DEMO_IP=$(kubectl -n demo get service demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl "http://${DEMO_IP}"
```

Expect `Hello from AKS! Version 1`. Pod IPs should be in the AKS subnet, while
the Service's internal virtual IP is in `10.2.0.0/16`.

</details>

## 6. Check repeatability

Run another Terraform plan. Does deploying Kubernetes objects change the
Terraform plan?

<details>
<summary>Solution: infrastructure versus workload ownership</summary>

```bash
terraform -chdir=infrastructure plan
```

Expect no infrastructure changes immediately after the successful apply.
Terraform owns Azure resources here; `kubectl` owns the Kubernetes demo. We do
not use a Terraform Kubernetes provider, so application changes are not shown
in this plan.

Later labs create extra Azure resources with CLI/controller commands. They do
not become Terraform-managed just because they share the resource group.
Follow the ordered cleanup rather than assuming Terraform can delete every
dependency in any order.

</details>

## 7. Upgrade the cluster without recreating it

Start with an **older supported minor**, not an end-of-life cluster. Check the
actual running version and the upgrades offered to **this cluster**. The
regional version list alone does not prove that a particular upgrade is valid.

<details>
<summary>Solution: inspect upgrade choices and prepare the workload</summary>

```bash
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{controlPlane:kubernetesVersion,pools:agentPoolProfiles[].{name:name,version:orchestratorVersion}}' \
  --output yaml
az aks get-upgrades --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --output table
kubectl get nodes
kubectl get pods --all-namespaces
kubectl -n demo scale deployment demo --replicas=2
kubectl -n demo rollout status deployment/demo --timeout=180s
kubectl -n demo get pods -o wide
```

Choose the next supported minor version from `get-upgrades`. If AKS requires a
patch update first, perform that update and check again. **Do not skip minor
versions or attempt a downgrade.** If no newer minor is offered, consult the
instructor's regional version choice; do not bypass validation.

Two replicas reduce interruption risk but do not guarantee availability. Check
whether they are on different nodes. The workload has readiness probes but no
production availability guarantee or Pod Disruption Budget. Real upgrades also
require deprecated-API checks, compatible add-ons, backups, and a tested
disruption policy.

</details>

Edit **only** `kubernetes_version` in `infrastructure/terraform.tfvars` to the
selected target. Both the control plane and default node pool reference that
variable. Do not run a separate `az aks upgrade`: Terraform remains the source
of truth.

<details>
<summary>Solution: apply the version change and verify both control plane and nodes</summary>

```bash
terraform -chdir=infrastructure plan -out=upgrade.tfplan
```

Inspect the plan: expect an **in-place update** to the AKS version and default
node-pool version, not cluster destruction or replacement. Stop if it proposes
replacement and identify the unrelated input change.

```bash
terraform -chdir=infrastructure apply upgrade.tfplan
kubectl get nodes -o wide
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{controlPlane:kubernetesVersion,pools:agentPoolProfiles[].{name:name,version:orchestratorVersion}}' \
  --output yaml
kubectl -n demo rollout status deployment/demo --timeout=300s
curl "http://${DEMO_IP}"
terraform -chdir=infrastructure plan
```

Expect the **control plane and both nodes** on the target version, both nodes
`Ready`, the expected HTTP response, and a no-change Terraform plan. The cluster
name and resource ID remain the same. Upgrades can take 15-30 minutes or longer.
The configured surge of one allows an extra node during rotation; quota and
subnet space must cover it.

Update `K8S_VERSION` in your local `.workshop/env.sh` to the target version so
you do not accidentally generate old inputs later. Keep the upgraded
`terraform.tfvars`. Kubernetes upgrades cannot be rolled back by changing this
value to the old version.

</details>

## Checkpoint

You can connect to two nodes, explain the two subnets and Service range, reach
the demo, and verify an in-place upgrade of the control plane **and** node pool.
Keep the state and upgraded cluster.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| AzureRM requests a subscription ID | Check `infrastructure/terraform.tfvars` and `az account show` |
| `LinkedAuthorizationFailed` / subnet permissions | Check your right to assign roles and the cluster identity's Network Contributor assignment; allow propagation, then re-plan |
| Provider is not registered | Complete the provider registration steps in setup |
| Quota or allocation failure | Inspect the detailed Azure error; agree on a supported VM size or region, then re-plan with the retained state |
| Plan unexpectedly replaces AKS | Stop and inspect the changed inputs; do not replace a cluster containing later labs' data |
| Upgrade fails to allocate a surge node | Check regional and VM-family quota, SKU capacity, and subnet IP space; retain state and retry a new plan after fixing the cause |
| Upgrade reports a blocked drain | Inspect pod events and Pod Disruption Budgets; do not force-delete unfamiliar system workloads |
| State lock error | Confirm no other Terraform process is running; do not force-unlock an active operation |
| Apply succeeds but pods do not run | Check node readiness and `kubectl describe pod`; infrastructure success does not guarantee image pulls or scheduling |

## Continue or stop

**Continuing:** keep everything. Lab 3 adds resources without replacing AKS.

**Finished for now:** Azure keeps billing. Either resume later with the same
state or follow [Final cleanup](../../docs/cleanup.md). Do not simply delete
the resource group in the portal while keeping stale Terraform state.
