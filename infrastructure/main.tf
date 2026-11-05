terraform {
  required_version = ">= 1.6, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {}
}

resource "azurerm_resource_group" "lab" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.0.0/22"]
}

resource "azurerm_subnet" "agc" {
  name                 = "agc"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.4.0/24"]

  delegation {
    name = "application-gateway-for-containers"

    service_delegation {
      name = "Microsoft.ServiceNetworking/trafficControllers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.prefix}-cluster"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_role_assignment" "cluster_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "lab" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  dns_prefix          = var.prefix
  sku_tier            = "Free"
  kubernetes_version  = var.kubernetes_version

  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true

  dynamic "microsoft_defender" {
    for_each = var.defender_log_analytics_workspace_id == null ? [] : [var.defender_log_analytics_workspace_id]

    content {
      log_analytics_workspace_id = microsoft_defender.value
    }
  }

  dynamic "oms_agent" {
    for_each = var.log_analytics_workspace_id == null ? [] : [var.log_analytics_workspace_id]

    content {
      log_analytics_workspace_id      = oms_agent.value
      msi_auth_for_monitoring_enabled = true
    }
  }

  dynamic "monitor_metrics" {
    for_each = var.log_analytics_workspace_id == null ? [] : [var.log_analytics_workspace_id]

    content {}
  }

  default_node_pool {
    name                         = "system"
    node_count                   = 2
    vm_size                      = var.node_vm_size
    orchestrator_version         = var.kubernetes_version
    vnet_subnet_id               = azurerm_subnet.aks.id
    max_pods                     = 30
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtemp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  network_profile {
    network_plugin    = "azure"
    service_cidr      = "10.2.0.0/16"
    dns_service_ip    = "10.2.0.10"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  depends_on = [
    azurerm_role_assignment.cluster_subnet,
    azurerm_subnet_network_security_group_association.aks,
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                        = "apps"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.lab.id
  mode                        = "User"
  node_count                  = 2
  node_taints                 = []
  vm_size                     = var.node_vm_size
  orchestrator_version        = var.kubernetes_version
  vnet_subnet_id              = azurerm_subnet.aks.id
  max_pods                    = 30
  temporary_name_for_rotation = "appsrotate"

  upgrade_settings {
    max_surge = "1"
  }
}
