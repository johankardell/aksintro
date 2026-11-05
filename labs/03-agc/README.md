# Lab 3: Application Gateway for Containers

[Home](../../README.md) | [Previous: Lab 2](../02-terraform/README.md)

**Goal:** Put Application Gateway for Containers (AGC) in front of the existing
demo using Kubernetes Gateway API.

**Time:** 60-90 minutes. **Prerequisites:** upgraded Lab 2 cluster and its Terraform
state, Terraform, Helm 3, AGC providers registered, and permission to assign roles.
No new cluster is needed.

## What you are building

```text
Browser -> AGC public frontend -> demo Service -> demo pods
             |
             + association to the dedicated agc subnet

ALB Controller in AKS -> translates Gateway / HTTPRoute into Azure configuration
```

**AGC is not Application Gateway Ingress Controller (AGIC).** Do not enable the
older `ingress-appgw` add-on. This lab uses the **Helm ALB Controller** installation
and the **managed-by-controller** resource lifecycle. The preview AKS ALB add-on
is not required.

## 1. Reconnect and verify prerequisites

Use the existing Terraform outputs, then verify Azure CNI, OIDC, and Workload
Identity. Inspect the reserved subnet rather than creating another VNet.

<details>
<summary>Solution: cluster and subnet checks</summary>

Run from the repository root:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
export AGC_SUBNET_ID=$(terraform -chdir=infrastructure output -raw agc_subnet_id)
export MC_RG=$(terraform -chdir=infrastructure output -raw node_resource_group_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
kubectl -n demo get pods,service
az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query '{network:networkProfile.networkPlugin,oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled}' \
  --output yaml
az network vnet subnet show --ids "$AGC_SUBNET_ID" \
  --query '{prefix:addressPrefix,delegations:delegations[].serviceName}' --output yaml
```

Expect `azure`, both identity features `true`, subnet `10.0.4.0/24`, and the
traffic-controller delegation. AGC needs a dedicated delegated subnet with at
least 250 available addresses. The existing nodes and pods stay in the AKS
subnet.

If the demo is missing because you skipped its deployment, create namespace
`demo`, apply `apps/demo/manifest.yaml` with `kubectl -n demo apply -f`, and wait
for `deployment/demo` to become ready.

</details>

## 2. Give ALB Controller its own identity

Use Terraform to create a dedicated identity, not the cluster identity or a
future application's identity. [`infrastructure/agc.tf`](../../infrastructure/agc.tf)
grants Reader and AGC Configuration Manager on the node resource group, and
Network Contributor only on the AGC subnet.

Add `enable_agc = true` to your existing `infrastructure/terraform.tfvars`.
Keep all Lab 2 inputs, including the upgraded Kubernetes version. Do not
regenerate the file or create another Terraform state directory.

<details>
<summary>Solution: plan and apply the controller identity resources</summary>

```bash
terraform -chdir=infrastructure fmt -check
terraform -chdir=infrastructure validate
terraform -chdir=infrastructure plan -out=agc.tfplan
```

Review the plan: expect **five new resources** (one identity, one federated
credential, and three role assignments), with no cluster or network changes.
Stop if it proposes AKS replacement or unrelated updates.

```bash
terraform -chdir=infrastructure apply agc.tfplan
export ALB_CLIENT_ID=$(terraform -chdir=infrastructure output -raw alb_client_id)
terraform -chdir=infrastructure plan
```

Expect the final plan to show no changes. When resuming, recover `ALB_CLIENT_ID`
with the same output command; it is available only after enabling and applying
these resources.

Inspect `agc.tf`: the federated subject must exactly match the controller's
namespace and ServiceAccount. Its issuer comes from the existing AKS cluster.
Allow several minutes for new identities and role assignments to propagate.
If apply reports that the principal does not exist yet, wait, create a **new**
plan, and retry; do not grant broader roles.

Terraform owns the identity, federated credential, and role assignments.
AGC resources are created in the AKS **node resource group** by ALB Controller,
not managed by Terraform. Keep `enable_agc = true` until the controller has
deleted AGC during [Final cleanup](../../docs/cleanup.md).

</details>

## 3. Install ALB Controller

Install the chart with its dedicated identity. We pin the chart to a documented
version rather than silently changing it each time the workshop runs.

<details>
<summary>Solution: Helm installation and controller verification</summary>

```bash
helm upgrade --install alb-controller \
  oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --version 1.12.2 \
  --namespace azure-alb-system --create-namespace \
  --set albController.namespace=azure-alb-system \
  --set albController.podIdentity.clientID="$ALB_CLIENT_ID" \
  --wait --timeout 5m
kubectl -n azure-alb-system get pods
kubectl get gatewayclass azure-alb-external -o yaml
kubectl wait --for=condition=Accepted gatewayclass/azure-alb-external --timeout=120s
```

Expect controller pods running and the GatewayClass `Accepted=True`. The chart
supplies the required custom resource definitions. Do not install another
controller or unrelated Gateway API CRD bundle to fix a failed Helm release.

</details>

## 4. Create the ApplicationLoadBalancer

This custom resource asks the controller to provision AGC and associate it with
the delegated subnet. Keep the infrastructure object separate from the demo.

<details>
<summary>Solution: controller-managed AGC resource</summary>

```bash
kubectl create namespace alb-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: workshop-alb
  namespace: alb-infra
spec:
  associations:
    - "$AGC_SUBNET_ID"
EOF
kubectl -n alb-infra get applicationloadbalancer workshop-alb -o yaml
kubectl -n alb-infra wait --for=condition=Deployment=True \
  applicationloadbalancer/workshop-alb --timeout=600s
```

Provisioning can take 5-10 minutes. Inspect status conditions if it takes longer.
Expect `Accepted=True` and the `Deployment` condition `True` with reason `Ready`.
Look in the node resource group in the portal for the new
`Microsoft.ServiceNetworking/trafficControllers` resource.

</details>

## 5. Route HTTP traffic to the demo

Create a Gateway in `demo`, reference the ApplicationLoadBalancer using
annotations, and add an HTTPRoute to the demo Service's **port 80**.

<details>
<summary>Solution: Gateway and HTTPRoute</summary>

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-gateway
  namespace: demo
  annotations:
    alb.networking.azure.io/alb-namespace: alb-infra
    alb.networking.azure.io/alb-name: workshop-alb
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-route
  namespace: demo
spec:
  parentRefs:
    - name: demo-gateway
      sectionName: http
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: demo
          port: 80
EOF
kubectl -n demo wait --for=condition=Programmed \
  gateway/demo-gateway --timeout=600s
kubectl -n demo get gateway demo-gateway -o yaml
kubectl -n demo get httproute demo-route -o yaml
```

Expect the Gateway to be `Accepted` and `Programmed`, with an address. Under the
HTTPRoute's `status.parents[].conditions`, expect `Accepted=True` and
`ResolvedRefs=True`. If either is false, read its message before testing traffic.

</details>

## 6. Verify AGC, then remove the old public Service endpoint

The Gateway advertises an Azure-managed hostname; no custom DNS is necessary.
First test it, then make the Service internal-only.

<details>
<summary>Solution: verify the new path and remove the old one</summary>

```bash
export AGC_HOST=$(kubectl -n demo get gateway demo-gateway \
  -o jsonpath='{.status.addresses[0].value}')
printf 'AGC endpoint: http://%s\n' "$AGC_HOST"
curl "http://${AGC_HOST}"
kubectl -n demo patch service demo \
  --type merge --patch '{"spec":{"type":"ClusterIP"}}'
kubectl -n demo get service demo
curl "http://${AGC_HOST}"
```

Expect `Hello from AKS! Version 1` both times and Service type `ClusterIP`.
The old Service's external IP is no longer the application's entry point.
The Azure load balancer used for cluster outbound connectivity can remain;
changing one Service does not remove all AKS networking resources.

This demonstrates HTTP only. AGC is publicly reachable and must not carry
credentials or sensitive data in this exercise.

</details>

## Checkpoint

The demo works through AGC with a ClusterIP Service. You can trace Gateway ->
HTTPRoute -> Service -> pods, and identify the controller's separate identity.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| Helm installation fails or times out | `helm status alb-controller -n azure-alb-system`; inspect namespace events and pod scheduling/image-pull errors |
| Gateway or ApplicationLoadBalancer kind is unknown | Verify that the chart installed successfully; inspect `kubectl get crds` |
| Controller reports authorization failures | Check its client ID, exact federated subject/issuer/audience, three role assignments, and propagation time |
| ApplicationLoadBalancer never becomes ready | Inspect its status and controller logs; check subnet delegation, size, region support, and identity scope |
| HTTPRoute has `ResolvedRefs=False` | Check Service name, namespace, and port 80; the route uses the Service port, not container port 5678 |
| HTTP 503 | Check ready pods and `kubectl -n demo get endpointslices`; describe the route and Gateway |
| Hostname is empty or DNS fails initially | Wait for Gateway provisioning; verify the `Programmed` condition before copying its address |

Useful diagnostic commands:

```bash
kubectl -n azure-alb-system get events --sort-by=.lastTimestamp
kubectl -n azure-alb-system get pods
kubectl -n demo describe gateway demo-gateway
kubectl -n demo describe httproute demo-route
```

For controller logs, copy a controller pod name from `get pods` and run
`kubectl -n azure-alb-system logs POD-NAME --all-containers --tail=100`.

## Continue or stop

Keep the cluster and AGC for Lab 4. AGC continues to incur charges. If you are
done, follow [Final cleanup](../../docs/cleanup.md); the Gateway and
ApplicationLoadBalancer must be deleted **while ALB Controller is still running**.

References: [ALB Controller with Helm](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm),
[controller-managed AGC](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-managed-by-alb-controller),
[Gateway API routing](https://learn.microsoft.com/azure/application-gateway/for-containers/how-to-path-header-query-string-routing-gateway-api).

[Next: Lab 4 - Managed identities and Blob Storage](../04-identity-storage/README.md)
