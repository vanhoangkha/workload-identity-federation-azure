# Terraform: Azure to GCP Workload Identity Federation

Production-ready Terraform module that creates all GCP resources needed for Azure workloads to authenticate via Workload Identity Federation.

## What it creates

- Workload Identity Pool (per environment)
- OIDC Provider for Microsoft Entra ID
- Service Accounts with least-privilege roles
- IAM bindings (workloadIdentityUser + serviceAccountTokenCreator)
- Required GCP APIs auto-enabled

## Prerequisites (Azure side)

Before running Terraform, manually create on Azure:
1. Entra ID App Registration with Application ID URI
2. Managed Identity assigned to your workload (VM, Functions, AKS)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init
terraform plan
terraform apply
```

After apply, generate credential config:
```bash
terraform output -json credential_config_commands
```

## Inputs

| Name | Description | Type | Required | Default |
|------|-------------|------|----------|---------|
| project_id | GCP Project ID | string | yes | - |
| azure_tenant_id | Entra ID Tenant ID (GUID) | string | yes | - |
| azure_app_id_uri | Application ID URI | string | yes | - |
| environment | Environment name | string | no | production |
| azure_allowed_subjects | Managed Identity Object IDs allowed | list(string) | no | [] (all) |
| service_accounts | Map of SAs with roles | map(object) | yes | - |

## Outputs

| Name | Description |
|------|-------------|
| pool_name | Full resource name of the WIF Pool |
| provider_name | Full resource name of the WIF Provider |
| service_account_emails | Map of SA key -> email |
| credential_config_commands | gcloud commands to generate credential configs |

## Security features

- OIDC issuer validation against Entra ID tenant
- Optional subject-level filtering via `azure_allowed_subjects`
- Per-environment pool isolation
- Least-privilege SA roles
- Auto-enables only required APIs
