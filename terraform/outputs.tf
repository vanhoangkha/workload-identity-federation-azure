output "pool_name" {
  description = "Full resource name of the Workload Identity Pool"
  value       = google_iam_workload_identity_pool.this.name
}

output "provider_name" {
  description = "Full resource name of the WIF Provider"
  value       = google_iam_workload_identity_pool_provider.this.name
}

output "service_account_emails" {
  description = "Map of service account key -> email"
  value       = { for k, v in google_service_account.this : k => v.email }
}

output "credential_config_commands" {
  description = "gcloud commands to generate credential config files"
  value = {
    for k, v in google_service_account.this : k => join(" ", [
      "gcloud iam workload-identity-pools create-cred-config",
      google_iam_workload_identity_pool_provider.this.name,
      "--service-account=${v.email}",
      "--azure",
      "--app-id-uri=${var.azure_app_id_uri}",
      "--output-file=gcp-credentials-${k}.json",
    ])
  }
}
