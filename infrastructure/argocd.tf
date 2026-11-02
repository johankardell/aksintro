data "azurerm_client_config" "argocd" {
  count = var.enable_argocd ? 1 : 0
}

resource "azurerm_user_assigned_identity" "argocd" {
  count               = var.enable_argocd ? 1 : 0
  name                = "${var.prefix}-argocd"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_federated_identity_credential" "argocd" {
  count                     = var.enable_argocd ? 1 : 0
  name                      = "argocd-repo-server"
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd[0].id
  issuer                    = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  subject                   = "system:serviceaccount:argocd:argocd-repo-server"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_kubernetes_cluster_extension" "argocd" {
  count             = var.enable_argocd ? 1 : 0
  name              = "argocd"
  cluster_id        = azurerm_kubernetes_cluster.lab.id
  extension_type    = "Microsoft.ArgoCD"
  release_namespace = "argocd"

  configuration_settings = {
    "fullnameOverride"                                                            = "argocd"
    "redis-ha.enabled"                                                            = "false"
    "azure.workloadIdentity.enabled"                                              = "true"
    "azure.workloadIdentity.clientId"                                             = azurerm_user_assigned_identity.argocd[0].client_id
    "azure.workloadIdentity.entraSSOClientId"                                     = var.argocd_sso_client_id
    "server.serviceAccount.name"                                                  = "argocd-server"
    "server.serviceAccount.annotations.azure\\.workload\\.identity/client-id"     = var.argocd_sso_client_id
    "repoServer.serviceAccount.name"                                              = "argocd-repo-server"
    "repoServer.serviceAccount.annotations.azure\\.workload\\.identity/client-id" = azurerm_user_assigned_identity.argocd[0].client_id
    "server.service.type"                                                         = "ClusterIP"
    "configs.params.server\\.insecure"                                            = "true"
    "configs.cm.url"                                                              = "http://localhost:8080"
    "configs.cm.admin\\.enabled"                                                  = "false"
    "configs.cm.oidc\\.config" = yamlencode({
      name     = "Microsoft Entra ID"
      issuer   = "https://login.microsoftonline.com/${data.azurerm_client_config.argocd[0].tenant_id}/v2.0"
      clientID = var.argocd_sso_client_id
      azure    = { useWorkloadIdentity = true }
      requestedIDTokenClaims = {
        groups = { essential = true }
      }
      requestedScopes = ["openid", "profile", "email"]
    })
    "configs.rbac.policy\\.default" = "role:no-access"
    "configs.rbac.scopes"           = "[groups]"
    "configs.rbac.policy\\.csv"     = <<-EOT
      p, role:lab-operator, applications, get, aksintro/*, allow
      p, role:lab-operator, applications, sync, aksintro/*, allow
      p, role:lab-operator, applications, update, aksintro/*, allow
      p, role:lab-operator, projects, get, aksintro, allow
      g, ${var.argocd_group_object_id}, role:lab-operator
    EOT
  }

  depends_on = [azurerm_federated_identity_credential.argocd]

  lifecycle {
    precondition {
      condition     = var.argocd_sso_client_id != "" && var.argocd_group_object_id != ""
      error_message = "Set argocd_sso_client_id and argocd_group_object_id from the externally created Entra objects before enabling Lab 6."
    }
  }
}
