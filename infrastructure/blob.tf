resource "azurerm_storage_account" "blob" {
  count                           = var.enable_blob_storage ? 1 : 0
  name                            = var.storage_account_name != null ? var.storage_account_name : "staks${substr(sha256("${var.subscription_id}/${var.prefix}"), 0, 19)}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false

  # Lab-only exemption from the subscription's public-network restriction.
  tags = {
    SecurityControl = "Ignore"
  }
}

resource "azurerm_storage_container" "labdata" {
  count                 = var.enable_blob_storage ? 1 : 0
  name                  = "labdata"
  storage_account_id    = azurerm_storage_account.blob[0].id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "blob" {
  count               = var.enable_blob_storage ? 1 : 0
  name                = "${var.prefix}-blob"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_federated_identity_credential" "blob" {
  count                     = var.enable_blob_storage ? 1 : 0
  name                      = "blob-reader"
  user_assigned_identity_id = azurerm_user_assigned_identity.blob[0].id
  issuer                    = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  subject                   = "system:serviceaccount:identity-demo:blob-reader"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "blob_reader" {
  count                = var.enable_blob_storage ? 1 : 0
  scope                = azurerm_storage_container.labdata[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.blob[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "blob_uploader" {
  count                = var.enable_blob_storage ? 1 : 0
  scope                = azurerm_storage_container.labdata[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.attendee_object_id
  principal_type       = "User"

  lifecycle {
    precondition {
      condition     = var.attendee_object_id != ""
      error_message = "Set attendee_object_id before enabling Lab 4 Blob Storage."
    }
  }
}
