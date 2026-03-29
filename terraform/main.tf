terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

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
  }
}

# Pool
resource "google_iam_workload_identity_pool" "azure" {
  workload_identity_pool_id = "${var.pool_id}-${var.environment}"
  display_name              = "Azure Pool (${var.environment})"
  description               = "Workload Identity Pool for Azure ${var.environment} workloads"
  project                   = var.project_id
}

# OIDC Provider
resource "google_iam_workload_identity_pool_provider" "azure" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.azure.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  project                            = var.project_id

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  oidc {
    issuer_uri        = "https://sts.windows.net/${var.azure_tenant_id}/"
    allowed_audiences = [var.azure_app_id_uri]
  }
}

# Service Accounts
resource "google_service_account" "workload" {
  for_each     = var.service_accounts
  account_id   = "azure-${each.key}-sa"
  display_name = each.value.display_name
  description  = "SA for Azure workloads - ${each.key} (${var.environment})"
  project      = var.project_id
}

# IAM roles
resource "google_project_iam_member" "sa_roles" {
  for_each = {
    for pair in flatten([
      for sa_key, sa in var.service_accounts : [
        for role in sa.roles : {
          key  = "${sa_key}-${replace(role, "/", "-")}"
          sa   = sa_key
          role = role
        }
      ]
    ]) : pair.key => pair
  }
  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload[each.value.sa].email}"
}

# WIF bindings
resource "google_service_account_iam_member" "wif_user" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.azure.name}/*"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.azure.name}/*"
}

output "pool_id" {
  value = google_iam_workload_identity_pool.azure.workload_identity_pool_id
}

output "provider_id" {
  value = google_iam_workload_identity_pool_provider.azure.workload_identity_pool_provider_id
}

output "service_account_emails" {
  value = { for k, v in google_service_account.workload : k => v.email }
}

output "credential_config_command" {
  value = <<-EOT
    gcloud iam workload-identity-pools create-cred-config \
      ${google_iam_workload_identity_pool_provider.azure.name} \
      --service-account=<SA_EMAIL> \
      --azure --app-id-uri="${var.azure_app_id_uri}" \
      --output-file=gcp-credentials.json
  EOT
}
