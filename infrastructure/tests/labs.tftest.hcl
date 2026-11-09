# Mock-provider tests require Terraform 1.7+ or OpenTofu with mock support.
mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg"
    }
  }

  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.ContainerService/managedClusters/test-lab-aks"
      oidc_issuer_url        = "https://issuer.example.test/"
      node_resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/MC_test-lab"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-identity"
      principal_id = "00000000-0000-0000-0000-000000000002"
      client_id    = "00000000-0000-0000-0000-000000000003"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.Network/virtualNetworks/test-lab-vnet/subnets/aks"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.Network/networkSecurityGroups/test-nsg"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.Storage/storageAccounts/teststorage"
    }
  }

  mock_resource "azurerm_storage_container" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test-lab-rg/providers/Microsoft.Storage/storageAccounts/teststorage/blobServices/default/containers/labdata"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-lab-monitoring/providers/Microsoft.OperationalInsights/workspaces/test-lab-logs"
    }
  }

  mock_resource "azurerm_monitor_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-lab-monitoring/providers/Microsoft.Monitor/accounts/test-lab-metrics"
    }
  }

  mock_resource "azurerm_dashboard_grafana" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-lab-monitoring/providers/Microsoft.Dashboard/grafana/test-lab-grafana"
      endpoint = "https://grafana.example.test"
      identity = {
        principal_id = "00000000-0000-0000-0000-000000000004"
        tenant_id    = "00000000-0000-0000-0000-000000000005"
      }
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000005"
    }
  }
}

variables {
  subscription_id                     = "00000000-0000-0000-0000-000000000001"
  prefix                              = "test-lab"
  kubernetes_version                  = "1.34.1"
  enable_agc                          = false
  enable_blob_storage                 = false
  enable_argocd                       = false
  enable_monitoring_resources         = false
  attendee_object_id                  = ""
  argocd_sso_client_id                = ""
  argocd_group_object_id              = ""
  storage_account_name                = null
  allow_storage_policy_exemption      = false
  grafana_major_version               = "12"
  log_analytics_workspace_id          = null
  defender_log_analytics_workspace_id = null
}

run "application_pool_and_system_isolation" {
  command = apply

  variables {
    node_vm_size       = "Standard_D8as_v7"
    kubernetes_version = "1.35.1"
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.lab.default_node_pool[0].only_critical_addons_enabled &&
      azurerm_kubernetes_cluster.lab.default_node_pool[0].node_count == 2 &&
      azurerm_kubernetes_cluster_node_pool.apps.name == "apps" &&
      azurerm_kubernetes_cluster_node_pool.apps.mode == "User" &&
      azurerm_kubernetes_cluster_node_pool.apps.node_count == 2 &&
      azurerm_kubernetes_cluster_node_pool.apps.vm_size == azurerm_kubernetes_cluster.lab.default_node_pool[0].vm_size &&
      length(azurerm_kubernetes_cluster_node_pool.apps.node_taints) == 0 &&
      azurerm_kubernetes_cluster_node_pool.apps.vnet_subnet_id == azurerm_subnet.aks.id &&
      azurerm_kubernetes_cluster_node_pool.apps.max_pods == 30
    )
    error_message = "Reserve two system nodes for critical add-ons and provide two untainted, same-sized apps nodes on the AKS subnet."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.lab.kubernetes_version == var.kubernetes_version &&
      azurerm_kubernetes_cluster.lab.default_node_pool[0].orchestrator_version == var.kubernetes_version &&
      azurerm_kubernetes_cluster_node_pool.apps.orchestrator_version == var.kubernetes_version &&
      azurerm_kubernetes_cluster_node_pool.apps.upgrade_settings[0].max_surge == "1"
    )
    error_message = "Both pools must follow the workshop Kubernetes version and the apps pool must allow one surge node."
  }
}

run "subnet_network_security" {
  command = apply

  assert {
    condition = (
      azurerm_subnet_network_security_group_association.aks.subnet_id == azurerm_subnet.aks.id &&
      azurerm_subnet_network_security_group_association.aks.network_security_group_id == azurerm_network_security_group.aks.id &&
      azurerm_subnet_network_security_group_association.agc.subnet_id == azurerm_subnet.agc.id &&
      azurerm_subnet_network_security_group_association.agc.network_security_group_id == azurerm_network_security_group.agc.id
    )
    error_message = "Each subnet must be associated with its Terraform-managed NSG."
  }

  assert {
    condition = (
      length(azurerm_network_security_group.agc.security_rule) == 1 &&
      alltrue([
        for rule in azurerm_network_security_group.agc.security_rule :
        rule.direction == "Inbound" &&
        rule.access == "Allow" &&
        rule.protocol == "Tcp" &&
        rule.source_address_prefix == "Internet" &&
        toset(rule.destination_port_ranges) == toset(["80", "443"]) &&
        rule.destination_port_range == null &&
        rule.priority < 65000
      ]) &&
      length(azurerm_network_security_group.aks.security_rule) == 1 &&
      alltrue([
        for rule in azurerm_network_security_group.aks.security_rule :
        rule.direction == "Inbound" &&
        rule.access == "Allow" &&
        rule.protocol == "Tcp" &&
        rule.source_address_prefix == "Internet" &&
        rule.destination_port_range == "80" &&
        rule.destination_port_ranges == null &&
        rule.priority < 65000
      ])
    )
    error_message = "Allow only AGC HTTP/HTTPS and the existing Lab 2 HTTP endpoint; retain Azure's default internal, health-probe and outbound rules."
  }
}

run "later_labs_disabled" {
  command = plan

  assert {
    condition = (
      length(azurerm_user_assigned_identity.alb) == 0 &&
      length(azurerm_storage_account.blob) == 0 &&
      length(azurerm_storage_container.labdata) == 0 &&
      length(azurerm_user_assigned_identity.blob) == 0 &&
      length(azurerm_role_assignment.blob_uploader) == 0 &&
      length(azurerm_user_assigned_identity.argocd) == 0 &&
      length(azurerm_kubernetes_cluster_extension.argocd) == 0 &&
      length(azurerm_resource_group.monitoring) == 0 &&
      length(azurerm_dashboard_grafana.lab) == 0 &&
      length(azurerm_kubernetes_cluster.lab.microsoft_defender) == 0 &&
      length(azurerm_kubernetes_cluster.lab.oms_agent) == 0 &&
      length(azurerm_kubernetes_cluster.lab.monitor_metrics) == 0 &&
      output.blob_client_id == null &&
      output.argocd_managed_identity_client_id == null &&
      output.grafana_endpoint == null
    )
    error_message = "Lab 2 must stay unchanged with all later-lab features disabled."
  }
}

run "blob_storage_and_least_privilege" {
  command = apply

  variables {
    enable_blob_storage = true
    attendee_object_id  = "00000000-0000-0000-0000-000000000006"
  }

  assert {
    condition = (
      azurerm_storage_account.blob[0].shared_access_key_enabled == false &&
      azurerm_storage_account.blob[0].allow_nested_items_to_be_public == false &&
      azurerm_storage_account.blob[0].min_tls_version == "TLS1_2" &&
      !contains(keys(azurerm_storage_account.blob[0].tags), "SecurityControl") &&
      azurerm_storage_container.labdata[0].container_access_type == "private" &&
      azurerm_storage_container.labdata[0].storage_account_id == azurerm_storage_account.blob[0].id &&
      azurerm_role_assignment.blob_reader[0].scope == azurerm_storage_container.labdata[0].id &&
      azurerm_role_assignment.blob_reader[0].principal_id == azurerm_user_assigned_identity.blob[0].principal_id &&
      azurerm_role_assignment.blob_reader[0].role_definition_name == "Storage Blob Data Reader" &&
      azurerm_role_assignment.blob_uploader[0].scope == azurerm_storage_container.labdata[0].id &&
      azurerm_role_assignment.blob_uploader[0].principal_id == var.attendee_object_id &&
      azurerm_role_assignment.blob_uploader[0].role_definition_name == "Storage Blob Data Contributor"
    )
    error_message = "Blob Storage must remain private/keyless with separate container-scoped reader and uploader access."
  }

  assert {
    condition = (
      azurerm_federated_identity_credential.blob[0].user_assigned_identity_id == azurerm_user_assigned_identity.blob[0].id &&
      azurerm_federated_identity_credential.blob[0].issuer == azurerm_kubernetes_cluster.lab.oidc_issuer_url &&
      azurerm_federated_identity_credential.blob[0].subject == "system:serviceaccount:identity-demo:blob-reader" &&
      azurerm_federated_identity_credential.blob[0].audience == tolist(["api://AzureADTokenExchange"]) &&
      output.blob_client_id == azurerm_user_assigned_identity.blob[0].client_id &&
      can(regex("^[a-z0-9]{3,24}$", output.storage_account_name))
    )
    error_message = "Lab 4 federation and outputs must match the blob-reader ServiceAccount."
  }
}

run "blob_storage_policy_exemption_is_opt_in" {
  command = apply

  variables {
    enable_blob_storage            = true
    attendee_object_id             = "00000000-0000-0000-0000-000000000006"
    allow_storage_policy_exemption = true
  }

  assert {
    condition     = azurerm_storage_account.blob[0].tags["SecurityControl"] == "Ignore"
    error_message = "Add the policy-exemption tag only when explicitly enabled for an approved training subscription."
  }
}

run "argocd_extension_and_identity_separation" {
  command = apply

  variables {
    enable_argocd          = true
    argocd_sso_client_id   = "00000000-0000-0000-0000-000000000007"
    argocd_group_object_id = "00000000-0000-0000-0000-000000000008"
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster_extension.argocd[0].extension_type == "Microsoft.ArgoCD" &&
      azurerm_kubernetes_cluster_extension.argocd[0].cluster_id == azurerm_kubernetes_cluster.lab.id &&
      azurerm_kubernetes_cluster_extension.argocd[0].release_namespace == "argocd" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["server.serviceAccount.annotations.azure\\.workload\\.identity/client-id"] == var.argocd_sso_client_id &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["repoServer.serviceAccount.annotations.azure\\.workload\\.identity/client-id"] == output.argocd_managed_identity_client_id &&
      azurerm_federated_identity_credential.argocd[0].subject == "system:serviceaccount:argocd:argocd-repo-server" &&
      azurerm_federated_identity_credential.argocd[0].issuer == azurerm_kubernetes_cluster.lab.oidc_issuer_url
    )
    error_message = "Argo CD must use the managed extension and keep its SSO app separate from the repo-server managed identity."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["server.service.type"] == "ClusterIP" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.url"] == "http://localhost:8080" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.admin\\.enabled"] == "false" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["redis-ha.enabled"] == "false" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.rbac.policy\\.default"] == "role:no-access" &&
      strcontains(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.rbac.policy\\.csv"], "g, ${var.argocd_group_object_id}, role:lab-operator") &&
      !strcontains(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.rbac.policy\\.csv"], "role:admin") &&
      yamldecode(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.oidc\\.config"]).clientID == var.argocd_sso_client_id &&
      yamldecode(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.oidc\\.config"]).azure.useWorkloadIdentity == true
    )
    error_message = "Argo CD must preserve the localhost-only, non-admin, scoped-RBAC SSO configuration."
  }
}

run "argocd_local_auth_without_entra_objects" {
  command = apply

  variables {
    enable_argocd             = true
    argocd_local_auth_enabled = true
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster_extension.argocd[0].extension_type == "Microsoft.ArgoCD" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.admin\\.enabled"] == "true" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["server.service.type"] == "ClusterIP" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.params.server\\.insecure"] == "true" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.cm.url"] == "http://localhost:8080" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["configs.rbac.policy\\.default"] == "role:no-access" &&
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["redis-ha.enabled"] == "false" &&
      !contains(keys(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings), "configs.cm.oidc\\.config") &&
      !contains(keys(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings), "azure.workloadIdentity.entraSSOClientId") &&
      !contains(keys(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings), "server.serviceAccount.annotations.azure\\.workload\\.identity/client-id") &&
      !contains(keys(azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings), "configs.rbac.policy\\.csv")
    )
    error_message = "The opt-in fallback must allow local login without SSO settings, while retaining localhost-only access and no default permissions."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster_extension.argocd[0].configuration_settings["repoServer.serviceAccount.annotations.azure\\.workload\\.identity/client-id"] == output.argocd_managed_identity_client_id &&
      azurerm_federated_identity_credential.argocd[0].subject == "system:serviceaccount:argocd:argocd-repo-server"
    )
    error_message = "Local UI authentication must not replace the separately managed repo-server identity or federation."
  }
}

run "defender_does_not_enable_lab7_collection" {
  command = plan

  variables {
    defender_log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-defender/providers/Microsoft.OperationalInsights/workspaces/defender-logs"
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.lab.microsoft_defender[0].log_analytics_workspace_id == var.defender_log_analytics_workspace_id &&
      length(azurerm_kubernetes_cluster.lab.oms_agent) == 0 &&
      length(azurerm_kubernetes_cluster.lab.monitor_metrics) == 0 &&
      length(azurerm_log_analytics_workspace.lab) == 0
    )
    error_message = "Preserve the existing Defender workspace without creating Lab 7 destinations or enabling its monitoring agents."
  }
}

run "monitoring_destinations_do_not_enable_collection" {
  command = apply

  variables {
    enable_monitoring_resources = true
    attendee_object_id          = "00000000-0000-0000-0000-000000000006"
  }

  assert {
    condition = (
      length(azurerm_kubernetes_cluster.lab.oms_agent) == 0 &&
      length(azurerm_kubernetes_cluster.lab.monitor_metrics) == 0 &&
      azurerm_log_analytics_workspace.lab[0].retention_in_days == 30 &&
      azurerm_dashboard_grafana.lab[0].sku == "Standard" &&
      azurerm_role_assignment.grafana_metrics_reader[0].scope == azurerm_monitor_workspace.lab[0].id &&
      azurerm_role_assignment.grafana_metrics_reader[0].role_definition_name == "Monitoring Data Reader" &&
      azurerm_role_assignment.grafana_metrics_reader[0].principal_id == azurerm_dashboard_grafana.lab[0].identity[0].principal_id &&
      azurerm_role_assignment.grafana_editor[0].scope == azurerm_dashboard_grafana.lab[0].id &&
      azurerm_role_assignment.grafana_editor[0].role_definition_name == "Grafana Editor" &&
      azurerm_role_assignment.logs_reader[0].scope == azurerm_log_analytics_workspace.lab[0].id &&
      azurerm_role_assignment.logs_reader[0].role_definition_name == "Log Analytics Reader"
    )
    error_message = "Provisioning monitoring destinations must not bypass CLI onboarding or broaden Grafana/user roles."
  }
}

run "all_labs_with_onboarded_collection" {
  command = apply

  variables {
    enable_agc                  = true
    enable_blob_storage         = true
    enable_argocd               = true
    enable_monitoring_resources = true
    attendee_object_id          = "00000000-0000-0000-0000-000000000006"
    argocd_sso_client_id        = "00000000-0000-0000-0000-000000000007"
    argocd_group_object_id      = "00000000-0000-0000-0000-000000000008"
    storage_account_name        = "existinglabstorage"
    log_analytics_workspace_id  = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-lab-monitoring/providers/Microsoft.OperationalInsights/workspaces/test-lab-logs"
  }

  assert {
    condition = (
      length(azurerm_kubernetes_cluster.lab.oms_agent) == 1 &&
      length(azurerm_kubernetes_cluster.lab.monitor_metrics) == 1 &&
      azurerm_kubernetes_cluster.lab.oms_agent[0].log_analytics_workspace_id == var.log_analytics_workspace_id &&
      azurerm_kubernetes_cluster.lab.oms_agent[0].msi_auth_for_monitoring_enabled == true &&
      output.storage_account_name == var.storage_account_name &&
      azurerm_role_assignment.alb_configuration_manager[0].scope == azurerm_kubernetes_cluster.lab.node_resource_group_id &&
      azurerm_federated_identity_credential.alb[0].user_assigned_identity_id == azurerm_user_assigned_identity.alb[0].id
    )
    error_message = "Combined lab flags must preserve existing storage names, AGC wiring, and CLI-onboarded collection settings."
  }
}

run "enabled_labs_require_identity_inputs" {
  command = plan

  variables {
    enable_blob_storage         = true
    enable_argocd               = true
    enable_monitoring_resources = true
  }

  expect_failures = [
    azurerm_role_assignment.blob_uploader,
    azurerm_kubernetes_cluster_extension.argocd,
    azurerm_role_assignment.grafana_editor,
    azurerm_role_assignment.logs_reader,
  ]
}
