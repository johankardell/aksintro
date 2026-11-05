# Setup and prerequisites

[Workshop home](../README.md) | [Next: Lab 1](../labs/01-portal/README.md)

Allow 30-60 minutes. Complete permission checks **before** the workshop; missing
Azure or Entra permissions generally cannot be fixed by installing another tool.

## 1. What you need

| Requirement | Why |
| --- | --- |
| An Azure subscription and Microsoft Entra tenant | Hosts the resources and identities |
| A sandbox resource allowance and spending approval | Nodes, disks, public IPs, AGC, and Lab 7 monitoring incur charges |
| Permission to create resources and assign Azure roles | Terraform and the identity labs create role assignments |
| Permission to register Azure resource providers | Enables the resource types used by the labs |
| Permission to create an Entra app registration, its federated credential, and a security group | Required for Argo CD SSO in Lab 6 |
| GitHub account and permission to create a public fork | Lets you change the GitOps source without changing the instructor's repository |
| Browser and a Bash terminal | Portal, Entra sign-in, and command-line exercises |

For a dedicated training subscription, an instructor can grant **Contributor**
plus **Role Based Access Control Administrator**, scoped appropriately. An Owner
can also perform these tasks, but do not request subscription Owner in production.
Lab 6 additionally needs permission to create
`Microsoft.KubernetesConfiguration/extensions`; the
**Kubernetes Extension Contributor** role includes extension management.
Role-assignment conditions may limit which roles you can grant.
Lab 7 also assigns Grafana Editor to the attendee and grants Grafana's managed
identity access to its metrics workspace; permission to create monitoring
resources alone is not sufficient.

**Azure roles and Entra directory permissions are separate.** Subscription Owner
does not automatically allow app registrations or group creation. Ask the
instructor or tenant administrator to pre-create Lab 6 objects if tenant policy
blocks them. Group-based enterprise-application assignment may require Entra ID
P1; this lab does not require that assignment feature.

Use individual lab IDs and resource groups when sharing a subscription. Do not
share a cluster, Terraform state, or managed identity with another attendee.

## 2. Choose your terminal

All subsequent command blocks marked `bash` run in Bash, not PowerShell or
Command Prompt. `$NAME` is a shell variable; text such as `YOUR-SUBSCRIPTION-ID`
must be replaced before running a command.

### Windows

In an administrator PowerShell terminal, install WSL:

```powershell
wsl --install -d Ubuntu
```

Restart if prompted, open **Ubuntu**, and create your Linux username. Use the
Linux installation steps below **inside Ubuntu**. Keep the repository under your
Linux home directory rather than mixing Windows and Linux tool installations.
Use your normal Windows browser for portal and device-code sign-in.

If you only want the native Windows Azure CLI, install it with
`winget install --exact --id Microsoft.AzureCLI`, then reopen the terminal.
The remaining lab commands still require Bash; WSL is the supported path here.

### macOS

Install [Homebrew](https://brew.sh/) using its official instructions if needed.
Then:

```bash
brew update
brew install azure-cli kubectl helm@3 git
brew install Azure/kubelogin/kubelogin
export PATH="$(brew --prefix helm@3)/bin:$PATH"
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Add the Helm 3 PATH setting to your shell profile if Homebrew reports that the
versioned formula is keg-only. Recheck `helm version --short` in a new terminal.

macOS normally opens a Zsh terminal. Run `bash` before following the remaining
workshop commands, and ensure the Helm PATH setting is available in that shell.

### Ubuntu / WSL Ubuntu

Install Azure CLI using Microsoft's installer. This installs system packages;
review the downloaded installer before executing it.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release git unzip less
curl -fsSL https://aka.ms/InstallAzureCLIDeb -o /tmp/install-azure-cli.sh
less /tmp/install-azure-cli.sh
sudo bash /tmp/install-azure-cli.sh
```

Press `q` to leave `less`. Install Terraform from HashiCorp's package repository:

```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform
```

Install `kubectl` and `kubelogin`:

```bash
mkdir -p "$HOME/.local/bin"
az aks install-cli \
  --install-location "$HOME/.local/bin/kubectl" \
  --kubelogin-install-location "$HOME/.local/bin/kubelogin"
export PATH="$HOME/.local/bin:$PATH"
```

Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` to preserve this PATH
setting in new terminals. `kubelogin` is useful for Entra-enabled clusters, but
the provided Terraform cluster uses local credentials.

Install Helm 3 using its official installer:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  -o /tmp/install-helm.sh
less /tmp/install-helm.sh
bash /tmp/install-helm.sh
```

For another Linux distribution, use the official
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-linux),
[Terraform](https://developer.hashicorp.com/terraform/install), and
[Helm](https://helm.sh/docs/intro/install/) installation instructions.

### Azure Cloud Shell alternative

Cloud Shell Bash includes Azure CLI, `kubectl`, Git, Terraform, and Helm, but
check their versions. It can be used for Lab 1.

**Use a local Bash terminal for Labs 2-7.** This keeps Terraform state and the
ignored workshop settings together on your machine. Labs 5-6 also use localhost
port-forwards, and Lab 6's Entra redirect URI must match the machine running your
browser. Cloud Shell's web preview has a different URL and does not match those
instructions.

If you use Cloud Shell for Lab 1, clone your fork and repeat the settings and
login steps below on your computer before Lab 2. No Terraform state exists yet.

## 3. Verify tools and sign in

Use a current stable Azure CLI (**2.75.0 or newer** for the Grafana extension),
Terraform **1.6 or newer, below 2.0**, and Helm **3**.
`kubectl` should be within one minor version of the cluster's Kubernetes
version. If the latest installed client is too far ahead, reinstall a matching
client after choosing the cluster version, using
`az aks install-cli --client-version vMAJOR.MINOR.PATCH` and the installation
paths above.

```bash
az version
terraform version
kubectl version --client
kubelogin --version
helm version --short
git --version
curl --version
az login
az account list --output table
```

If the browser does not open in WSL or a remote terminal, run
`az login --use-device-code` and follow its instructions in your browser.
For multiple tenants, use `az login --tenant YOUR-TENANT-ID`.

Select the subscription explicitly:

```bash
az account set --subscription "YOUR-SUBSCRIPTION-ID"
az account show --query '{subscription:name,id:id,tenant:tenantId}' --output table
```

A **tenant** is the identity directory. A **subscription** is the Azure billing
and resource boundary. A **resource group** holds related Azure resources.
Confirm that the displayed subscription is your training subscription.

## 4. Get the repository and save your settings

Complete this section **before Lab 1**. It creates the local `.workshop/env.sh`
file used in Lab 1's **Connect from your terminal** step and subsequent labs.

Fork [johankardell/aksintro](https://github.com/johankardell/aksintro) in GitHub,
then clone your fork using its HTTPS URL. A public fork avoids repository
credentials inside Argo CD. Never put private information in it.

```bash
git clone https://github.com/YOUR-GITHUB-USERNAME/aksintro.git
cd aksintro
mkdir -p .workshop
```

Choose a short, unique lowercase lab ID: for example `jk01`. The Terraform
prefix `aksintro-jk01` must be at most 15 characters, so keep your lab ID to
**2-6 lowercase letters or digits**. The example region is North Europe;
the instructor should confirm AKS, AGC, Azure Monitor workspace, Log Analytics,
and Managed Grafana availability, VM capacity, and quota in the chosen region
before the workshop.

Create a local settings file. Replace the two `YOUR-...` values and `jk01`:

```bash
cat > .workshop/env.sh <<EOF
export WORKSHOP_ROOT="$PWD"
export SUBSCRIPTION_ID="YOUR-SUBSCRIPTION-ID"
export LAB_ID="jk01"
export LOCATION="northeurope"
export GITHUB_USERNAME="YOUR-GITHUB-USERNAME"
EOF
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
```

This generated file is local configuration, not a required wrapper script.
`.workshop/` is ignored by Git. Never store tokens, passwords, or kubeconfig
in the repository. Shell variables do not survive a new terminal.

## 5. Prepare Azure providers, extensions, and quota

An instructor can register these once per subscription. `--wait` can take
several minutes:

```bash
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Network --wait
az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ManagedIdentity --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.NetworkFunction --wait
az provider register --namespace Microsoft.ServiceNetworking --wait
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.AlertsManagement --wait
az provider register --namespace Microsoft.Monitor --wait
az provider register --namespace Microsoft.Dashboard --wait
```

Install all Azure CLI extensions needed by the full workshop now, so later labs
do not depend on downloading tools during an exercise:

```bash
az extension add --name k8s-extension --upgrade
az extension add --name amg --upgrade
az extension add --name monitor-control-service --upgrade
az extension list --output table
```

| Extension | Used for |
| --- | --- |
| `k8s-extension` | Lab 6: install and manage the Microsoft-managed Argo CD extension |
| `amg` | Lab 7: create and inspect Azure Managed Grafana |
| `monitor-control-service` | Lab 7 and cleanup: inspect data collection rules and associations |

We use Helm for ALB Controller, so the AGC preview AKS add-on and `aks-preview`
extension are **not required**. We do not need the `alb` CLI extension because
the controller creates AGC resources from Kubernetes manifests.
The lab commands do not require `k8s-configuration`, the Argo CD CLI, or a local
Grafana/Prometheus installation.

If `aks-preview` is listed, Microsoft's
[monitoring onboarding guidance](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable)
requires removing it before the stable Lab 7 commands:
`az extension remove --name aks-preview`. Only remove it from your training CLI
environment; if you need it for unrelated work, use a separate environment.

Check that the command groups are available. These help commands do not create
Azure resources:

```bash
az aks --help
az k8s-extension --help
az grafana --help
az monitor account --help
az monitor data-collection rule association --help
```

Installing an extension only adds commands to your local CLI. It does not
enable a cluster add-on or create billable resources. Later labs repeat the
extension installation/update commands as a recovery step if setup was skipped
or you switched machines.

Check availability:

```bash
az aks get-versions --location "$LOCATION" --output table
az vm list-usage --location "$LOCATION" --output table
az vm list-skus --location "$LOCATION" \
  --resource-type virtualMachines --size Standard_D4s_v5 --output table
```

For **Lab 2's upgrade exercise**, the instructor should select a generally
available Kubernetes minor version one minor behind a newer supported version
in this region. Choose an explicit patch version, not a preview or an
unsupported/LTS-only release. Save it locally:

```bash
export K8S_VERSION="REPLACE-WITH-OLDER-SUPPORTED-PATCH-VERSION"
printf 'export K8S_VERSION="%s"\n' "$K8S_VERSION" >> .workshop/env.sh
```

Replace the placeholder before running it. The instructor should confirm both
the starting version and its next-minor upgrade path shortly before the class,
including compatibility with the Lab 3 controller and Lab 6 extension. AKS
availability rolls out regionally; do not copy a stale version from an old
workshop. Lab 1 can keep the portal's default version.

Lab 2 requests **four `Standard_D4s_v5` nodes**: two in the `system` pool and two
in the `apps` pool, for 16 vCPUs in total. Each pool allows one temporary upgrade
node. Reserve quota and capacity for two surge nodes (eight more vCPUs), for
**24 vCPUs including upgrade headroom**. Check both the regional vCPU quota and the
VM-family quota. AKS system nodes require at least 4 vCPUs and 4 GiB of memory;
B-series VMs are not supported. See the
[system node pool requirements](https://learn.microsoft.com/azure/aks/use-system-pools).
Ask the instructor for an available compatible size if this SKU is restricted;
do not repeatedly create clusters hoping to bypass a quota error.

Make a cost estimate with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).
Include four worker VMs, OS disks, load balancer/public IP resources, AGC, a small
managed data disk, Blob Storage, Managed Grafana Standard, Log Analytics
ingestion/retention, and managed Prometheus ingestion/queries. Monitoring has
ongoing charges even when you are not viewing dashboards. Budget alerts notify;
they do not enforce a hard spending limit.

## 6. Kubernetes concepts you will use

| Term | Meaning in these labs |
| --- | --- |
| Cluster / node | Kubernetes environment / VM that runs your workloads |
| Namespace | Logical grouping of Kubernetes resources; not an Azure resource group |
| Pod / Deployment | Running container(s) / controller that replaces and scales pods |
| Service | Stable network address and port for a changing set of pods |
| Manifest | YAML describing a Kubernetes resource's desired state |
| Gateway / HTTPRoute | HTTP entry point / routing rule used by AGC |
| ServiceAccount | Kubernetes identity attached to a pod |
| Managed identity | Entra identity that can receive Azure role assignments |
| PVC / PV | Request for persistent storage / provisioned backing volume |
| GitOps | A controller reconciles the cluster to desired configuration in Git |

`kubectl apply -f file.yaml` creates or updates desired state. `kubectl get`
lists resources, `describe` includes events, and `logs` shows container output.
`Ctrl+C` stops a watch or port-forward, **not** the workload or cluster.

## Resuming in a new terminal

From the repository root:

```bash
source .workshop/env.sh
az account set --subscription "$SUBSCRIPTION_ID"
```

After Lab 2, also recover cluster settings:

```bash
export RESOURCE_GROUP=$(terraform -chdir=infrastructure output -raw resource_group_name)
export AKS_NAME=$(terraform -chdir=infrastructure output -raw cluster_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl config current-context
kubectl get nodes
```

Do not copy the old portal context after deleting Lab 1. Later labs start with
these checks so that commands target the correct cluster.

## Common setup problems

| Symptom | Action |
| --- | --- |
| `az`, `terraform`, `helm`, or `kubectl`: command not found | Reopen the terminal, check `command -v TOOL`, and verify PATH in the same OS/shell where you installed it |
| Login shows the wrong subscription | Run `az account list -o table`, then `az account set`; use the correct tenant if necessary |
| `AuthorizationFailed` or provider registration denied | Have the instructor check the required Azure role and scope; re-login after a new assignment propagates |
| Cannot create app registrations or groups | Tenant policy, not an AKS problem; arrange Entra objects with the instructor before Lab 6 |
| Download, image pull, or repository access fails | Check corporate proxy/firewall access to Microsoft, GitHub, HashiCorp, Docker Hub, and the container registries; do not disable certificate verification |
| `kubectl` talks to localhost or another cluster | Get credentials for the intended AKS cluster and check the current context |
| Quota exceeded or SKU unavailable | Request quota or agree on a supported region/SKU before provisioning |

[Continue to Lab 1](../labs/01-portal/README.md).
