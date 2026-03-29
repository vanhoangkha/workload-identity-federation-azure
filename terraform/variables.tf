variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "azure_tenant_id" {
  description = "Microsoft Entra ID Tenant ID (GUID)"
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.azure_tenant_id))
    error_message = "Must be a valid GUID."
  }
}

variable "azure_app_id_uri" {
  description = "Entra ID Application ID URI (e.g. api://<client-id>)"
  type        = string
}

variable "azure_allowed_subjects" {
  description = "List of Managed Identity Object IDs allowed to authenticate. Empty = all identities in the tenant."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment (production, staging, development)"
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Must be production, staging, or development."
  }
}

variable "service_accounts" {
  description = "Map of service accounts to create"
  type = map(object({
    display_name = string
    description  = optional(string, "")
    roles        = list(string)
  }))
}
