variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "project_number" {
  description = "GCP Project Number"
  type        = string
}

variable "azure_tenant_id" {
  description = "Microsoft Entra ID Tenant ID (GUID)"
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.azure_tenant_id))
    error_message = "Azure Tenant ID must be a valid GUID."
  }
}

variable "azure_app_id_uri" {
  description = "Azure Entra ID Application ID URI"
  type        = string
}

variable "environment" {
  description = "Environment name (production, staging, development)"
  type        = string
  default     = "production"
}

variable "pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "azure-pool"
}

variable "provider_id" {
  description = "Workload Identity Pool Provider ID"
  type        = string
  default     = "azure-provider"
}

variable "service_accounts" {
  description = "Map of service accounts to create with their roles"
  type = map(object({
    display_name = string
    roles        = list(string)
  }))
  default = {
    "bigquery" = {
      display_name = "Azure BigQuery SA"
      roles        = ["roles/bigquery.dataViewer", "roles/bigquery.jobUser"]
    }
