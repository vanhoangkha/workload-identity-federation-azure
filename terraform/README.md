# Terraform Module: AZURE to GCP Workload Identity Federation

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

## Inputs

| Name | Description | Required |
|------|-------------|----------|
| project_id | GCP Project ID | Yes |
| project_number | GCP Project Number | Yes |
| environment | Environment name | No (default: production) |
| service_accounts | Map of SAs with roles | No |

## Outputs

| Name | Description |
|------|-------------|
| pool_id | Workload Identity Pool ID |
| provider_id | Provider ID |
| service_account_emails | Map of SA emails |
| credential_config_command | gcloud command to generate credential config |
