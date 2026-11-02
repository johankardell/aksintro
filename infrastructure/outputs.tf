output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.lab.name
}

output "node_resource_group_name" {
  value = azurerm_kubernetes_cluster.lab.node_resource_group
}

output "vnet_name" {
  value = azurerm_virtual_network.lab.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "agc_subnet_id" {
  value = azurerm_subnet.agc.id
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.lab.oidc_issuer_url
}

output "alb_client_id" {
  description = "Client ID for the Helm ALB Controller installation; available when enable_agc is true."
  value       = var.enable_agc ? azurerm_user_assigned_identity.alb[0].client_id : null
}

output "storage_account_name" {
  value = var.enable_blob_storage ? azurerm_storage_account.blob[0].name : null
}

output "blob_client_id" {
  value = var.enable_blob_storage ? azurerm_user_assigned_identity.blob[0].client_id : null
}

output "argocd_managed_identity_client_id" {
  value = var.enable_argocd ? azurerm_user_assigned_identity.argocd[0].client_id : null
}

output "monitoring_resource_group_name" {
  value = var.enable_monitoring_resources ? azurerm_resource_group.monitoring[0].name : null
}

output "log_analytics_workspace_id" {
  value = var.enable_monitoring_resources ? azurerm_log_analytics_workspace.lab[0].id : null
}

output "azure_monitor_workspace_id" {
  value = var.enable_monitoring_resources ? azurerm_monitor_workspace.lab[0].id : null
}

output "grafana_id" {
  value = var.enable_monitoring_resources ? azurerm_dashboard_grafana.lab[0].id : null
}

output "grafana_endpoint" {
  value = var.enable_monitoring_resources ? azurerm_dashboard_grafana.lab[0].endpoint : null
}
