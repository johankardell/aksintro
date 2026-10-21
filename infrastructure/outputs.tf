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
