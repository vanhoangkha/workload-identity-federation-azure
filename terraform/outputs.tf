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
