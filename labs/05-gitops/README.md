# Lab 5: Managed Argo CD, GitOps, and Entra ID

[Home](../../README.md) | [Previous: Lab 4](../04-identity-storage/README.md) | [Next: Lab 6](../06-monitoring/README.md)

**Goal:** Install Microsoft's managed Argo CD extension, sign in using Microsoft
Entra ID, and reconcile a demo application from your GitHub fork.

**Time:** 90-120 minutes. **Prerequisites:** the existing upgraded Lab 2 cluster
with Workload Identity, a public GitHub fork containing these files, local Bash,
and permission to create extensions, Entra app registrations, federated
credentials, service principals, and security groups.

**No Argo CD CLI, Helm-installed Argo CD, DNS name, or public TLS certificate is
needed.** Lab 4's persistent data stays in `storage-demo`; this lab deploys a
fresh copy of the HTTP demo in **`gitops-demo`**. Labs 2-3's `demo` namespace is
not adopted, overwritten, or pruned.

## What is managed, and what you still configure

The Azure extension type is **`Microsoft.ArgoCD`**. Microsoft manages the
extension's installation/lifecycle; Argo CD components still run on your nodes,
and you remain responsible for their configuration, access, and applications.
This is not a separate externally hosted Argo CD control plane.

The default extension configuration is HA and requires four nodes. We explicitly
disable Redis HA for this two-node learning cluster. This is not the production
HA configuration.

Two identity paths are involved:

- **Human sign-in:** Entra app registration + OIDC + group-to-Argo-CD RBAC.
- **Server credential:** Workload Identity federation lets `argocd-server`
  authenticate as that app registration without a client secret.

The managed extension's workload-identity configuration also takes a dedicated
managed identity for its other components. We create one rather than reuse the
Lab 4 blob reader. A public GitHub repository needs no Azure data role or GitHub
token.

## 1. Reconnect and check the existing cluster

<details>
<summary>Solution: reconnect and verify capacity</summary>

Run from the repository root on the machine where your browser runs:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
export OIDC_ISSUER=$(terraform -chdir=infrastructure output -raw oidc_issuer_url)
export TENANT_ID=$(az account show --query tenantId -o tsv)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
kubectl get pods --all-namespaces
az extension add --name k8s-extension --upgrade
```

Keep the Lab 4 deployment and PVC; do not destroy/recreate AKS. Check node
capacity if earlier workloads are not healthy. The cluster already has a
managed identity, OIDC issuer, and Workload Identity enabled.

An instructor should check the
[managed extension's current requirements](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd)
before the class. Use current configuration keys; pre-1.0 preview-extension
examples used different keys.

</details>

## 2. Create the Entra application and a lab access group

Use a single-tenant app with the **Web** redirect URI
`http://localhost:8080/auth/callback`. Our UI address will be
`http://localhost:8080`, reached only through a local port-forward. This is not
the separate Argo CD CLI callback on port 8085.

<details>
<summary>Solution: app registration, service principal, group, and group claims</summary>

```bash
export SSO_APP_ID=$(az ad app create \
  --display-name "aksintro-${LAB_ID}-argocd" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris http://localhost:8080/auth/callback \
  --query appId -o tsv)
printf 'export SSO_APP_ID="%s"\n' "$SSO_APP_ID" > .workshop/entra.env
az ad sp create --id "$SSO_APP_ID" --output none
az ad app update --id "$SSO_APP_ID" --set groupMembershipClaims=SecurityGroup
az ad app permission add --id "$SSO_APP_ID" \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope
export ARGOCD_GROUP_ID=$(az ad group create \
  --display-name "aksintro-${LAB_ID}-argocd-users" \
  --mail-nickname "aksintro-${LAB_ID}-argocd-users" --query id -o tsv)
printf 'export ARGOCD_GROUP_ID="%s"\n' "$ARGOCD_GROUP_ID" >> .workshop/entra.env
export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az ad group member add --group "$ARGOCD_GROUP_ID" --member-id "$USER_OBJECT_ID"
```

The permission GUID is Microsoft Graph's delegated **User.Read**, not a broad
directory-read permission. Your tenant may require administrator approval for
consent; arrange that with the instructor instead of granting unrelated rights.

In the portal, inspect **Entra ID -> App registrations** and **Groups**. Confirm
the callback, single-tenant setting, security-group claims, and your membership.
The service principal appears under **Enterprise applications**.

On resuming, `source .workshop/entra.env`; do not create duplicate apps or
groups. If the instructor pre-created these objects, put their app client ID
and group object ID into that local file and skip creation commands.

We do not require enterprise-application group assignment or its licensing.
Sign-in alone does not grant application access: the Argo CD role mapping in
step 4 does that. Other tenant users get no default Argo CD permissions.

</details>

## 3. Federate Kubernetes identities without a client secret

Trust exactly the cluster issuer and ServiceAccount that the server will use.
The app registration needs its **own** federated credential; a credential on a
managed identity does not automatically authenticate the SSO application.

<details>
<summary>Solution: SSO app federation and the extension's separate managed identity</summary>

```bash
cat > .workshop/argocd-sso-federation.json <<EOF
{
  "name": "aks-argocd-server",
  "issuer": "$OIDC_ISSUER",
  "subject": "system:serviceaccount:argocd:argocd-server",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
az ad app federated-credential create --id "$SSO_APP_ID" \
  --parameters .workshop/argocd-sso-federation.json
export ARGOCD_IDENTITY_NAME="aksintro-${LAB_ID}-argocd"
az identity create --resource-group "$RESOURCE_GROUP" \
  --name "$ARGOCD_IDENTITY_NAME" --location "$LOCATION"
export ARGOCD_MI_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" \
  --name "$ARGOCD_IDENTITY_NAME" --query clientId -o tsv)
az identity federated-credential create --name argocd-repo-server \
  --identity-name "$ARGOCD_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
  --issuer "$OIDC_ISSUER" \
  --subject system:serviceaccount:argocd:argocd-repo-server \
  --audiences api://AzureADTokenExchange
```

The **app client ID** is for browser OIDC/server authentication. The **managed
identity client ID** configures the extension's other workload-identity use.
Neither is a password. Do not create a client secret or grant this identity
Blob access merely because Lab 4 did so.

Allow a few minutes for federation to propagate.

</details>

## 4. Install the managed extension with SSO and scoped permissions

Prepare the non-secret OIDC and RBAC configuration. Members of the lab group
can view, sync, and update applications **only in the `aksintro` project**.
They do not receive Argo CD's unrestricted administrator role.

<details>
<summary>Solution: OIDC, group RBAC, and Microsoft.ArgoCD extension</summary>

```bash
export OIDC_CONFIG=$(cat <<EOF
name: Microsoft Entra ID
issuer: https://login.microsoftonline.com/$TENANT_ID/v2.0
clientID: $SSO_APP_ID
azure:
  useWorkloadIdentity: true
requestedIDTokenClaims:
  groups:
    essential: true
requestedScopes:
  - openid
  - profile
  - email
EOF
)
export RBAC_POLICY=$(cat <<EOF
p, role:lab-operator, applications, get, aksintro/*, allow
p, role:lab-operator, applications, sync, aksintro/*, allow
p, role:lab-operator, applications, update, aksintro/*, allow
p, role:lab-operator, projects, get, aksintro, allow
g, $ARGOCD_GROUP_ID, role:lab-operator
EOF
)
az k8s-extension create --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$AKS_NAME" --cluster-type managedClusters \
  --name argocd --extension-type Microsoft.ArgoCD \
  --scope cluster --release-namespace argocd \
  --config "fullnameOverride=argocd" \
  --config "redis-ha.enabled=false" \
  --config "azure.workloadIdentity.enabled=true" \
  --config "azure.workloadIdentity.clientId=$ARGOCD_MI_CLIENT_ID" \
  --config "azure.workloadIdentity.entraSSOClientId=$SSO_APP_ID" \
  --config "server.serviceAccount.name=argocd-server" \
  --config "server.serviceAccount.annotations.azure\.workload\.identity/client-id=$SSO_APP_ID" \
  --config "repoServer.serviceAccount.name=argocd-repo-server" \
  --config "repoServer.serviceAccount.annotations.azure\.workload\.identity/client-id=$ARGOCD_MI_CLIENT_ID" \
  --config "server.service.type=ClusterIP" \
  --config "configs.params.server\.insecure=true" \
  --config "configs.cm.url=http://localhost:8080" \
  --config "configs.cm.admin\.enabled=false" \
  --config "configs.cm.oidc\.config=$OIDC_CONFIG" \
  --config "configs.rbac.policy\.default=role:no-access" \
  --config "configs.rbac.scopes=[groups]" \
  --config "configs.rbac.policy\.csv=$RBAC_POLICY"
az k8s-extension show --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$AKS_NAME" --cluster-type managedClusters --name argocd \
  --query '{state:provisioningState,version:version}' --output table
kubectl -n argocd get deployments,statefulsets,pods,services
kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
```

The escaped dots are intentional: keys such as `oidc.config` contain a literal
dot inside Helm chart values. Keep each quoted `--config` argument intact.
`[groups]` is the RBAC scopes list.

Verify the actual workload-identity wiring before attempting sign-in:

```bash
kubectl -n argocd get serviceaccount argocd-server -o yaml
kubectl -n argocd get deployment argocd-server -o yaml
kubectl -n argocd get configmap argocd-cm -o yaml
kubectl -n argocd get configmap argocd-rbac-cm -o yaml
```

The server ServiceAccount's `azure.workload.identity/client-id` annotation must
equal **`SSO_APP_ID`**, not `ARGOCD_MI_CLIENT_ID`. Its pod template must carry
`azure.workload.identity/use: "true"`. The OIDC config must reference the same
app client ID and tenant. These checks catch mismatched extension configuration
instead of masking it with a client-secret fallback.

The extension owns its installation settings. Correct them with
`az k8s-extension update` using the relevant `--config` arguments, not
unrecorded Helm upgrades or direct edits to extension-owned ConfigMaps.
Do not install a second Argo CD to resolve a failed extension.

`server.insecure=true` means the server itself uses HTTP. That is acceptable
**only for this localhost port-forward exercise**: the Service remains
ClusterIP, no Ingress/Gateway/LoadBalancer exposes it, and port-forward uses
the authenticated Kubernetes connection. It is not a public deployment recipe.
The built-in Argo CD admin login is disabled; Kubernetes administrator access
is still available for troubleshooting.

</details>

## 5. Bootstrap the scoped project and sample Application

The complete sample manifests are
[`project.yaml`](project.yaml) and [`application.yaml`](application.yaml).
Copy them to the ignored workshop directory and change **both** repository URLs
to your public fork. Leave the source path as `apps/demo`.

<details>
<summary>Solution: local bootstrap manifests pointing at your fork</summary>

```bash
cp labs/05-gitops/project.yaml .workshop/project.yaml
cp labs/05-gitops/application.yaml .workshop/application.yaml
printf 'Use this repository URL in BOTH files: https://github.com/%s/aksintro.git\n' "$GITHUB_USERNAME"
```

Open `.workshop/project.yaml` and `.workshop/application.yaml` in your editor.
Set the AppProject's `spec.sourceRepos` entry and the Application's
`spec.source.repoURL` to the URL printed above. Verify your fork actually
contains `apps/demo/manifest.yaml` on `main`.

```bash
kubectl apply -f .workshop/project.yaml
kubectl apply -f .workshop/application.yaml
kubectl -n argocd get applications
```

The project allows only your repository, the `gitops-demo` destination, and the
resource types used by this sample. `CreateNamespace=true` creates the
destination namespace on sync. The application initially has **no automated
sync**, so an `OutOfSync`/missing-resource state is expected.

Only the files under `apps/demo` are reconciled. The bootstrap Application and
AppProject themselves are applied with `kubectl`; this is intentionally not an
app-of-apps or full platform GitOps lab.

</details>

## 6. Sign in using Entra ID and perform a manual sync

In a second local terminal, start the UI port-forward and keep it running.
Open the UI in a browser on the **same machine**.

<details>
<summary>Solution: local UI, Entra sign-in, and first deployment</summary>

```bash
kubectl config current-context
kubectl -n argocd port-forward service/argocd-server 8080:80
```

Open **http://localhost:8080**, choose **Log in via Microsoft Entra ID**, and sign
in with the account added to the lab group. Accept the requested consent if
tenant policy allows it.

Do not use `127.0.0.1`, a Cloud Shell preview URL, or an HTTPS URL: the configured
callback is specifically `http://localhost:8080/auth/callback`.

Select **aksintro-demo -> Sync**, inspect the resources, then confirm **Sync**.
Do not select pruning. Wait for **Synced** and **Healthy**.

In your main terminal:

```bash
kubectl -n gitops-demo rollout status deployment/demo --timeout=300s
kubectl -n gitops-demo get deployments,pods,services
kubectl -n argocd get application aksintro-demo \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

In a third terminal, forward the demo:

```bash
kubectl -n gitops-demo port-forward service/demo 8082:80
```

From the main terminal:

```bash
curl http://localhost:8082
```

Expect `Hello from AKS! Version 1`. You now have a fresh demo managed by Argo CD,
separate from the AGC demo and the persistent workload.

</details>

## 7. Make a change in Git

In **your fork** on GitHub, edit `apps/demo/manifest.yaml` on `main`: change
`Hello from AKS! Version 1` to `Hello from AKS! Version 2`. Commit the change using
GitHub's web editor; no local GitHub token or extra CLI installation is needed.

<details>
<summary>Solution: observe drift from Git, then sync the new version</summary>

In Argo CD, select **Refresh** to fetch the new revision. Expect **OutOfSync**.
Open **Diff** and verify that the change is the demo container's `-text`
argument, then select **Sync**.

In the terminal:

```bash
kubectl -n gitops-demo rollout status deployment/demo --timeout=300s
kubectl -n argocd get application aksintro-demo \
  -o jsonpath='{.status.sync.revision}{"\n"}'
```

Compare the revision with your Git commit. Restart the demo port-forward if the
pod was replaced, then:

```bash
curl http://localhost:8082
```

Expect `Hello from AKS! Version 2`. Pull the committed change into your local
clone when convenient with `git pull --ff-only`; do not overwrite uncommitted
local changes.

</details>

## 8. Enable automatic sync and observe self-healing

Now let Argo CD reconcile automatically. Keep pruning disabled. Make an
intentional out-of-band change to replicas and watch Git's desired value win.

<details>
<summary>Solution: automatic sync and a controlled drift experiment</summary>

```bash
kubectl -n argocd patch application aksintro-demo --type merge --patch \
  '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}'
kubectl -n gitops-demo scale deployment demo --replicas=3
kubectl -n gitops-demo get deployment demo --watch
```

Argo CD restores the desired replica count from Git: **1**. Press `Ctrl+C` after
observing the result, then verify:

```bash
kubectl -n gitops-demo get deployment demo -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n argocd get application aksintro-demo \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

Expect `1` and eventually `Synced Healthy`. If reconciliation happens too fast
to see the transient count, inspect the UI's sync history and events.

The automatic-sync setting was changed on the live bootstrap Application, not
in `apps/demo`. Add it to your local `.workshop/application.yaml` if you want
that configuration to be reproducible. The checked-in sample deliberately
starts with manual sync.

**Pruning** deletes tracked resources removed from Git. It is different from
self-healing changed resources, and remains off in this lab. Never point this
Application at Lab 4's PVC manifests or experiment with pruning persistent
storage without a data-retention plan.

</details>

## Checkpoint

You can sign in using Entra ID without a local Argo CD password, deploy from
your fork, trace a running version to its Git commit, and observe self-healing.
The persistent workload from Lab 4 remains untouched.

## Troubleshooting

| Symptom | What to inspect or fix |
| --- | --- |
| Extension is not `Succeeded` | Inspect `az k8s-extension show` including error details, pod events, current region/version support, and install permissions |
| Redis pods stay pending | Confirm `redis-ha.enabled=false`; the default HA layout needs more nodes |
| Port 8080 is already used | Stop the conflicting local process or consistently change UI URL, port-forward, and registered callback; do not change only one |
| `AADSTS50011` redirect mismatch | Compare the Web redirect URI with `http://localhost:8080/auth/callback` exactly |
| `AADSTS70021` / invalid client credential | Check the **SSO app's** federated credential, issuer, server ServiceAccount annotation, pod label, and `azure.useWorkloadIdentity` OIDC setting |
| Consent or app registration blocked | Resolve tenant policy with the instructor; Azure subscription roles do not override it |
| Login succeeds but no app is visible | Check group object ID, membership propagation, requested groups claim, RBAC policy, and project name; sign out and back in after a group change |
| User belongs to more than 200 groups | Entra may emit a group-overage claim instead of group IDs; use an instructor-provided training account or configure Argo CD's documented overage handling with the tenant admin |
| Repo connection or comparison fails | Check public fork visibility, both repository URLs, `main`, `apps/demo`, and outbound HTTPS to GitHub |
| Sync says resource/project not permitted | Check the AppProject destination, allowlisted repository and resource types; do not switch to the unrestricted default project |
| Demo still serves Version 1 | Confirm the fetched Git revision, actual sync completion, Deployment rollout, and port-forward target |
| Drift is not corrected | Confirm `automated.selfHeal=true` and that the change was made to the `gitops-demo` deployment |

Useful diagnostics:

```bash
kubectl -n argocd get events --sort-by=.lastTimestamp
kubectl -n argocd logs deployment/argocd-server --tail=100
kubectl -n argocd describe application aksintro-demo
```

Do not print tokens, add a client secret to Git, or enable unrestricted admin
access to bypass an SSO configuration error.

## Continue or stop

Stop both local port-forwards with `Ctrl+C`. They do not stop Azure billing.
Keep the cluster and continue to [Lab 6: managed monitoring](../06-monitoring/README.md).
If you are done, follow [Final cleanup](../../docs/cleanup.md), including the app
registration and security group: **Entra objects are not deleted with an Azure
resource group**.

References: [Microsoft managed Argo CD extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd),
[Argo CD with Entra OIDC and federation](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/microsoft/),
[Argo CD automatic sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).
