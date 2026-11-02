resource "azurerm_user_assigned_identity" "alb" {
  count               = var.enable_agc ? 1 : 0
  name                = "${var.prefix}-alb"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_federated_identity_credential" "alb" {
  count                     = var.enable_agc ? 1 : 0
  name                      = "alb-controller"
  user_assigned_identity_id = azurerm_user_assigned_identity.alb[0].id
  issuer                    = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  subject                   = "system:serviceaccount:azure-alb-system:alb-controller-sa"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "alb_reader" {
  count                = var.enable_agc ? 1 : 0
  scope                = azurerm_kubernetes_cluster.lab.node_resource_group_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.alb[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "alb_configuration_manager" {
  count                = var.enable_agc ? 1 : 0
  scope                = azurerm_kubernetes_cluster.lab.node_resource_group_id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.alb[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "alb_subnet" {
  count                = var.enable_agc ? 1 : 0
  scope                = azurerm_subnet.agc.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb[0].principal_id
  principal_type       = "ServicePrincipal"
}
