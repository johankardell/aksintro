variable "subscription_id" {
  description = "Training subscription selected with az account set."
  type        = string
}

variable "prefix" {
  description = "Unique attendee prefix, for example aksintro-jk01."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,14}$", var.prefix))
    error_message = "Use 3-15 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "location" {
  description = "Azure region supporting AKS, AGC, and the selected node VM size."
  type        = string
  default     = "northeurope"
}

variable "node_vm_size" {
  description = "VM size shared by the system and apps pools. Must support AKS system nodes; check regional and VM-family quota."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "kubernetes_version" {
  description = "Explicit supported patch version; start older, then change this to practice an upgrade."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "Choose an explicit supported version such as MAJOR.MINOR.PATCH from az aks get-versions."
  }
}

variable "enable_agc" {
  description = "Lab 3: create the ALB Controller identity, federation, and Azure permissions. AGC itself remains controller-managed."
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Lab 7 only: Log Analytics workspace ID. Null leaves both monitoring add-ons disabled."
  type        = string
  default     = null
}

variable "enable_blob_storage" {
  description = "Lab 4: create private Blob Storage, its workload identity, and scoped data roles."
  type        = bool
  default     = false
}

variable "storage_account_name" {
  description = "Optional existing or instructor-selected Lab 4 account name. Null uses a stable subscription/prefix-derived name."
  type        = string
  default     = null

  validation {
    condition     = var.storage_account_name == null ? true : can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account names must contain 3-24 lowercase letters or digits."
  }
}

variable "attendee_object_id" {
  description = "Tenant-local user object ID for Lab 4 blob seeding and Lab 7 Grafana/log access."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.attendee_object_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.attendee_object_id))
    error_message = "Supply a user object ID in UUID format, not a display name or app client ID."
  }
}

variable "enable_argocd" {
  description = "Lab 6: create the Argo CD managed identity, federation, and Microsoft.ArgoCD extension. Entra objects stay externally managed."
  type        = bool
  default     = false
}

variable "argocd_sso_client_id" {
  description = "Client ID of the externally created single-tenant Entra application for Lab 6."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.argocd_sso_client_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.argocd_sso_client_id))
    error_message = "Supply the Entra application's client ID in UUID format."
  }
}

variable "argocd_group_object_id" {
  description = "Object ID of the externally created Lab 6 security group."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.argocd_group_object_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.argocd_group_object_id))
    error_message = "Supply the Entra security group's object ID in UUID format."
  }
}

variable "enable_monitoring_resources" {
  description = "Lab 7: create monitoring workspaces, Managed Grafana, and scoped access roles. CLI onboarding still enables collection."
  type        = bool
  default     = false
}

variable "grafana_major_version" {
  description = "Lab 7 Managed Grafana major version. Check availability in the training region."
  type        = string
  default     = "12"

  validation {
    condition     = contains(["11", "12"], var.grafana_major_version)
    error_message = "Select supported Managed Grafana major version 11 or 12."
  }
}
