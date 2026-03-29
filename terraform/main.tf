locals {
  pool_id     = "azure-${var.environment}"
  provider_id = "azure-entra-id"

  # Build attribute condition for allowed managed identities
  attribute_condition = length(var.azure_allowed_subjects) > 0 ? join(" || ", [
    for sub in var.azure_allowed_subjects : "assertion.sub == '${sub}'"
  ]) : ""

  sa_role_pairs = flatten([
    for sa_key, sa in var.service_accounts : [
      for role in sa.roles : {
        key  = "${sa_key}--${replace(role, "roles/", "")}"
        sa   = sa_key
        role = role
      }
    ]
  ])
}

# ─── Workload Identity Pool ───

resource "google_iam_workload_identity_pool" "this" {
  project                   = var.project_id
  workload_identity_pool_id = local.pool_id
  display_name              = "Azure ${title(var.environment)}"
  description               = "WIF pool for Azure workloads (${var.environment})"
  disabled                  = false
}

# ─── OIDC Provider (Entra ID) ───

resource "google_iam_workload_identity_pool_provider" "this" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.this.workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id

  display_name = "Microsoft Entra ID"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
    "attribute.tid"  = "assertion.tid"
  }

  attribute_condition = local.attribute_condition != "" ? local.attribute_condition : null

  oidc {
    issuer_uri        = "https://sts.windows.net/${var.azure_tenant_id}/"
    allowed_audiences = [var.azure_app_id_uri]
  }
}

# ─── Service Accounts ───

resource "google_service_account" "this" {
  for_each     = var.service_accounts
  project      = var.project_id
  account_id   = "azure-${each.key}-${var.environment}"
  display_name = "${each.value.display_name} (${var.environment})"
  description  = each.value.description != "" ? each.value.description : "WIF SA for Azure ${each.key} workloads"
}

# ─── IAM: SA -> GCP Resource Roles ───

resource "google_project_iam_member" "sa_roles" {
  for_each = { for pair in local.sa_role_pairs : pair.key => pair }
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${google_service_account.this[each.value.sa].email}"
}

# ─── IAM: Azure -> SA Impersonation ───

resource "google_service_account_iam_member" "workload_identity_user" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.this.name}/*"
}

resource "google_service_account_iam_member" "token_creator" {
  for_each           = var.service_accounts
  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.this.name}/*"
}

# ─── Enable Required APIs ───

resource "google_project_service" "apis" {
  for_each = toset([
    "iam.googleapis.com",
    "sts.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
