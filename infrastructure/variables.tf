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
  description = "Available AKS system-pool VM size. Check regional and VM-family quota."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "kubernetes_version" {
  description = "Explicit supported patch version; start older, then change this to practice an upgrade."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "Choose an explicit supported version such as MAJOR.MINOR.PATCH from az aks get-versions."
  }
}

variable "log_analytics_workspace_id" {
  description = "Lab 6 only: Log Analytics workspace ID. Null leaves both monitoring add-ons disabled."
  type        = string
  default     = null
}
