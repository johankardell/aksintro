resource "azurerm_resource_group" "monitoring" {
  count    = var.enable_monitoring_resources ? 1 : 0
  name     = "rg-${var.prefix}-monitoring"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "lab" {
  count               = var.enable_monitoring_resources ? 1 : 0
  name                = "${var.prefix}-logs"
  location            = azurerm_resource_group.monitoring[0].location
  resource_group_name = azurerm_resource_group.monitoring[0].name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_workspace" "lab" {
  count               = var.enable_monitoring_resources ? 1 : 0
  name                = "${var.prefix}-metrics"
  location            = azurerm_resource_group.monitoring[0].location
  resource_group_name = azurerm_resource_group.monitoring[0].name
}

resource "azurerm_dashboard_grafana" "lab" {
  count                 = var.enable_monitoring_resources ? 1 : 0
  name                  = "${var.prefix}-grafana"
  location              = azurerm_resource_group.monitoring[0].location
  resource_group_name   = azurerm_resource_group.monitoring[0].name
  grafana_major_version = var.grafana_major_version
  sku                   = "Standard"
  sku_size              = "X1"

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    # The supported AKS CLI onboarding owns this linkage.
    ignore_changes = [azure_monitor_workspace_integrations]
  }
}

resource "azurerm_role_assignment" "grafana_metrics_reader" {
  count                = var.enable_monitoring_resources ? 1 : 0
  scope                = azurerm_monitor_workspace.lab[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.lab[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "grafana_editor" {
  count                = var.enable_monitoring_resources ? 1 : 0
  scope                = azurerm_dashboard_grafana.lab[0].id
  role_definition_name = "Grafana Editor"
  principal_id         = var.attendee_object_id
  principal_type       = "User"

  lifecycle {
    precondition {
      condition     = var.attendee_object_id != ""
      error_message = "Set attendee_object_id before enabling Lab 7 monitoring resources."
    }
  }
}

resource "azurerm_role_assignment" "logs_reader" {
  count                = var.enable_monitoring_resources ? 1 : 0
  scope                = azurerm_log_analytics_workspace.lab[0].id
  role_definition_name = "Log Analytics Reader"
  principal_id         = var.attendee_object_id
  principal_type       = "User"

  lifecycle {
    precondition {
      condition     = var.attendee_object_id != ""
      error_message = "Set attendee_object_id before enabling Lab 7 monitoring resources."
    }
  }
}
