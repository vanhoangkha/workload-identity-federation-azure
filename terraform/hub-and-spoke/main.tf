# Azure Hub-and-Spoke WIF — Terraform Module

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_number" {
  description = "GCP project number"
  type        = string
}

variable "tenant_id" {
  description = "Azure Entra ID tenant ID"
  type        = string
}

variable "hub_app_id_uri" {
  description = "Hub App ID URI (api://<CLIENT_ID>)"
  type        = string
}

variable "pool_id" {
  description = "Workload Identity Pool ID"
  type        = string
  default     = "azure-production"
}

variable "provider_id" {
  description = "WIF Provider ID"
  type        = string
  default     = "azure-hub"
}

variable "workloads" {
  description = "Map of workloads to onboard"
  type = map(object({
    managed_identity_object_id = string
    gcp_sa_id                  = string
    gcp_sa_display_name        = string
    gcp_roles                  = list(string)
  }))
}

# --- Pool & Provider ---

resource "google_iam_workload_identity_pool" "pool" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Azure Production Pool"
}

resource "google_iam_workload_identity_pool_provider" "azure" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Azure Hub (Entra ID)"

  oidc {
    issuer_uri        = "https://sts.windows.net/${var.tenant_id}/"
    allowed_audiences = [var.hub_app_id_uri]
  }

  attribute_mapping = {
    "google.subject"   = "assertion.sub"
    "attribute.tenant" = "assertion.tid"
  }

  attribute_condition = "assertion.tid == '${var.tenant_id}'"
}

# --- Per-workload SA + binding ---

resource "google_service_account" "workload" {
  for_each     = var.workloads
  project      = var.project_id
  account_id   = each.value.gcp_sa_id
  display_name = each.value.gcp_sa_display_name
}

resource "google_service_account_iam_member" "wif_binding" {
  for_each           = var.workloads
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/subject/${each.value.managed_identity_object_id}"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.workloads
  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.pool_id}/subject/${each.value.managed_identity_object_id}"
}

resource "google_project_iam_member" "workload_roles" {
  for_each = { for pair in flatten([
    for wk, wv in var.workloads : [
      for role in wv.gcp_roles : { key = "${wk}-${role}", workload = wk, role = role }
    ]
  ]) : pair.key => pair }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.workload[each.value.workload].email}"
}

output "pool_name" {
  value = google_iam_workload_identity_pool.pool.name
}

output "provider_name" {
  value = google_iam_workload_identity_pool_provider.azure.name
}

output "service_accounts" {
  value = { for k, v in google_service_account.workload : k => v.email }
}
