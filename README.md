![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Azure](https://img.shields.io/badge/Azure-Verified-blue)
![GCP](https://img.shields.io/badge/GCP-Verified-green)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-purple)

# Azure to Google Cloud: Workload Identity Federation Guide

## Contents

- [Overview](#why-workload-identity-federation)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Verified Test Results](#verified-test-results)
- [Examples](#examples)
- [Terraform Module](#terraform-module)
- [Enterprise Best Practices](#enterprise-best-practices)
- [Troubleshooting](#troubleshooting)
- [References](#references)

A comprehensive, step-by-step guide to configure **Google Cloud Workload Identity Federation** for Azure workloads — enabling secure, keyless authentication from Azure to Google Cloud services using **Managed Identities** and **Microsoft Entra ID** (formerly Azure AD).

## Why Workload Identity Federation?

| Criteria | Service Account Key | Workload Identity Federation |
|----------|--------------------|-----------------------------|
| Secret storage | JSON key file must be secured | No secrets to store |
| Key rotation | Manual, error-prone | Automatic — tokens expire in 1 hour |
| Leak risk | High — keys can leak via git, logs, backups | Nothing to leak |
| Audit trail | Only identifies the Service Account | Traces back to the original Azure identity |
| Compliance | Fails many security standards | Aligns with Zero Trust, SOC2, ISO 27001 |

## Architecture

![Architecture Overview](images/wif_azure_architecture.png)

## Authentication Flow

![Authentication Flow](images/wif_azure_auth_flow.png)

1. Azure workload uses its **Managed Identity** to request an access token from **Microsoft Entra ID**.
2. The Entra ID access token (OIDC JWT) is sent to **Google Security Token Service (STS)** for exchange.
3. Google STS validates the token against the Entra ID OIDC discovery endpoint and issues a **Federated Token**.
4. The Federated Token is used to **impersonate** a pre-configured Google Cloud Service Account.
5. A short-lived **Access Token** (1-hour TTL) is issued to call Google Cloud APIs.

## Cost

| Component | Cost |
|-----------|------|
| Workload Identity Pool & Provider | Free |
| Token exchange (STS API) | Free |
| Service Account impersonation | Free |
| Azure Managed Identity | Free |
| Microsoft Entra ID App Registration | Free |

The only costs come from the Google Cloud services you access (BigQuery, Cloud Storage, etc.).

## Supported Use Cases

![Use Cases](images/wif_azure_use_cases.png)

| # | Use Case | Azure Source | GCP Target | Required Role |
|---|----------|-------------|------------|---------------|
| 1 | Data analytics | Azure VM | BigQuery | bigquery.dataViewer + bigquery.jobUser |
| 2 | Data sync & backup | Azure VM | Cloud Storage | storage.objectAdmin |
| 3 | Cross-cloud inventory | Azure VM | Compute Engine | compute.viewer |
| 4 | Infrastructure as Code | Azure VM / DevOps | Terraform resources | Varies by resource |
| 5 | Centralized logging | Azure VM | Cloud Logging | logging.logWriter |
| 6 | Event processing | Azure Functions | BigQuery / GCS | bigquery.dataEditor |
| 7 | Microservices | AKS Pod | Any GCP service | Varies |
| 8 | CI/CD deployment | Azure DevOps Pipeline | Cloud Run / GKE | run.admin |

---

## Prerequisites

### Azure Side
- Azure subscription with Entra ID admin access
- A **Microsoft Entra ID Application** registered for Workload Identity Federation
- Azure workload with an assigned **Managed Identity** (system-assigned or user-assigned)

### Google Cloud Side
- Google Cloud Project with billing enabled
- IAM Admin + Service Account Admin permissions
- gcloud CLI v363.0.0+

---

## Step-by-Step Setup

### Step 1: Register Microsoft Entra ID Application

1. Go to **Azure Portal > Microsoft Entra ID > App registrations > New registration**
2. Name: `gcp-workload-identity`
3. Supported account types: **Accounts in this organizational directory only**
4. Click **Register**
5. Note the **Application (client) ID** and **Directory (tenant) ID**
6. Go to **Expose an API > Set Application ID URI** (use default `api://<CLIENT_ID>` or custom URI)

Note the **Application ID URI** — you will need it when configuring the provider.

[SCREENSHOT: Azure Portal - App Registration with Application ID URI]

### Step 2: Assign Managed Identity to Azure Workload

For Azure VM:

```bash
# Create user-assigned managed identity
az identity create \
  --name gcp-wif-identity \
  --resource-group <RESOURCE_GROUP>

# Assign to VM
az vm identity assign \
  --name <VM_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --identities gcp-wif-identity
```

Note the **Object ID** of the managed identity.

For Azure Functions: Enable system-assigned managed identity in the Function App settings.

[SCREENSHOT: Azure Portal - Managed Identity assigned to VM]

### Step 3: Enable Google Cloud APIs

```bash
gcloud services enable \
  iam.googleapis.com \
  sts.googleapis.com \
  iamcredentials.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  --project=<PROJECT_ID>
```

### Step 4: Create Workload Identity Pool

```bash
gcloud iam workload-identity-pools create azure-pool \
  --project=<PROJECT_ID> \
  --location=global \
  --display-name="Azure Pool"
```

[SCREENSHOT: Google Cloud Console - Workload Identity Pool created]

### Step 5: Create OIDC Provider for Azure

```bash
gcloud iam workload-identity-pools providers create-oidc azure-provider \
  --project=<PROJECT_ID> \
  --location=global \
  --workload-identity-pool=azure-pool \
  --issuer-uri="https://sts.windows.net/<TENANT_ID>/" \
  --allowed-audiences="<APPLICATION_ID_URI>" \
  --attribute-mapping="google.subject=assertion.sub"
```

Replace:
- `<TENANT_ID>`: Microsoft Entra ID tenant ID (GUID)
- `<APPLICATION_ID_URI>`: The Application ID URI from Step 1

Key difference from AWS: Azure uses **OIDC** provider type instead of AWS provider type.

[SCREENSHOT: Terminal - Provider created successfully]

### Step 6: Create Service Account

```bash
gcloud iam service-accounts create azure-workload-sa \
  --project=<PROJECT_ID> \
  --display-name="Azure Workload SA"
```

### Step 7: Grant Impersonation Permissions

```bash
# The subject is the Object ID of the Managed Identity
MEMBER="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-pool/subject/<MANAGED_IDENTITY_OBJECT_ID>"

gcloud iam service-accounts add-iam-policy-binding \
  azure-workload-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="${MEMBER}"

gcloud iam service-accounts add-iam-policy-binding \
  azure-workload-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="${MEMBER}"
```

Important:
- `<MANAGED_IDENTITY_OBJECT_ID>` is the **Object ID** of the managed identity (GUID), not the client ID
- Both roles are required
- Wait 30-60 seconds for IAM propagation

[SCREENSHOT: Terminal - Impersonation permissions granted]

### Step 8: Grant GCP Service Permissions

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --role=roles/bigquery.dataViewer \
  --member="serviceAccount:azure-workload-sa@<PROJECT_ID>.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --role=roles/bigquery.jobUser \
  --member="serviceAccount:azure-workload-sa@<PROJECT_ID>.iam.gserviceaccount.com"
```

### Step 9: Generate Credential Configuration

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-pool/providers/azure-provider \
  --service-account=azure-workload-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --azure \
  --app-id-uri=<APPLICATION_ID_URI> \
  --output-file=gcp-credentials.json
```

This file contains **no secrets** — safe to store in version control.

### Step 10: Configure Azure Workload

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credentials.json
```

---

## Examples

### BigQuery Query from Azure VM

```python
from google.cloud import bigquery

client = bigquery.Client(project="<PROJECT_ID>")

query = """
SELECT corpus, COUNT(*) as word_count
FROM `bigquery-public-data.samples.shakespeare`
GROUP BY corpus ORDER BY word_count DESC LIMIT 5
"""
for row in client.query(query).result():
    print(f"  {row.corpus}: {row.word_count}")
```

### Cloud Storage from Azure VM

```python
from google.cloud import storage

client = storage.Client(project="<PROJECT_ID>")
bucket = client.bucket("<BUCKET_NAME>")

# Upload
blob = bucket.blob("data/report.csv")
blob.upload_from_filename("/tmp/report.csv")

# Download
bucket.blob("config/settings.json").download_to_filename("/opt/app/settings.json")
```

### Cloud Logging from Azure VM

```python
from google.cloud import logging as cloud_logging
import socket

client = cloud_logging.Client(project="<PROJECT_ID>")
logger = client.logger("azure-application")

logger.log_struct({
    "severity": "INFO",
    "message": "Application started",
    "hostname": socket.gethostname(),
    "source": "azure-vm"
})
```

### Azure Functions calling BigQuery

```python
import os
import json
import azure.functions as func

def main(req: func.HttpRequest) -> func.HttpResponse:
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/home/site/wwwroot/gcp-credentials.json"

    from google.cloud import bigquery
    client = bigquery.Client(project="<PROJECT_ID>")

    query = "SELECT COUNT(*) as cnt FROM `<PROJECT_ID>.dataset.table`"
    result = list(client.query(query).result())
    return func.HttpResponse(json.dumps({"count": result[0].cnt}))
```

### Terraform from Azure

```hcl
provider "google" {
  project = "<PROJECT_ID>"
  region  = "us-central1"
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id = "azure_analytics"
  location   = "US"
}

resource "google_storage_bucket" "backups" {
  name     = "<PROJECT_ID>-azure-backups"
  location = "US"
  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
}
```

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credentials.json
terraform init && terraform apply
```

### Azure DevOps Pipeline deploying to GCP

```yaml
trigger:
  - main

pool:
  vmImage: 'ubuntu-latest'

steps:
  - task: AzureCLI@2
    inputs:
      azureSubscription: '<SERVICE_CONNECTION>'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        export GOOGLE_APPLICATION_CREDENTIALS=$(Build.SourcesDirectory)/gcp-credentials.json
        pip install google-cloud-run
        python deploy_to_cloud_run.py
```

---

## Key Differences: Azure vs AWS Setup

| Aspect | AWS | Azure |
|--------|-----|-------|
| Provider type | `create-aws` | `create-oidc` |
| Identity source | IAM Role + Instance Metadata | Managed Identity + Entra ID |
| Token type | AWS STS (SigV4) | OIDC JWT |
| Subject identifier | AWS ARN | Managed Identity Object ID |
| Issuer URI | N/A (built-in) | `https://sts.windows.net/<TENANT_ID>/` |
| Extra setup | None on AWS side | Register Entra ID App + set App ID URI |
| Credential config flag | `--aws --enable-imdsv2` | `--azure --app-id-uri=<URI>` |

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| Permission iam.serviceAccounts.getAccessToken denied | Missing serviceAccountTokenCreator role | Grant roles/iam.serviceAccountTokenCreator, wait 60s |
| Invalid audience | Application ID URI mismatch | Verify --allowed-audiences matches the App ID URI in Entra ID |
| Token validation failed | Wrong issuer URI or tenant ID | Verify issuer-uri format: `https://sts.windows.net/<TENANT_ID>/` (trailing slash required) |
| Subject mismatch | Wrong Object ID | Use Managed Identity **Object ID**, not Client ID |
| Azure Functions: credential error | gcp-credentials.json not found | Bundle file in deployment package, verify path |

---

## References

- [Workload Identity Federation with Azure](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Best Practices for Workload Identity Federation](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [Azure Managed Identities](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview)
- [Microsoft Entra ID App Registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)
- [Terraform Google Cloud Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Verified Test Results

The following end-to-end test was performed on 2026-03-29, authenticating from an Azure Service Principal to Google Cloud BigQuery via Workload Identity Federation.

### Test Environment

| Component | Detail |
|-----------|--------|
| Azure Identity | Service Principal (Entra ID App Registration) |
| GCP Project | Lab environment |
| WIF Pool | azure-pool |
| WIF Provider | azure-provider (OIDC) |
| GCP Service Account | azure-bigquery-sa |
| Target Service | BigQuery |

### Test Output

```
1. Azure token:     OK (1390 chars)
2. GCP STS token:   OK (1029 chars)
3. SA Access Token:  OK (1024 chars)
4. BigQuery query result:
   hamlet: 5318
   kinghenryv: 5104
   cymbeline: 4875
   troilusandcressida: 4795
   kinglear: 4784

=== Azure -> GCP Workload Identity Federation: SUCCESS! ===
```

### Authentication Flow Verified

```
Azure Entra ID (JWT token, 1390 chars)
    |
    v  Token Exchange
Google STS (federated token, 1029 chars)
    |
    v  Impersonate
GCP Service Account (access token, 1024 chars)
    |
    v  Query
BigQuery (5 rows returned)
```

### Test Script

```bash
TENANT_ID="<TENANT_ID>"
APP_ID="<APP_ID>"
APP_SECRET="<APP_SECRET>"
APP_ID_URI="api://<APP_ID>"
PROJECT_NUMBER="<PROJECT_NUMBER>"
PROJECT_ID="<PROJECT_ID>"

# 1. Get Azure token
AZURE_TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$APP_ID" \
  -d "client_secret=$APP_SECRET" \
  -d "scope=${APP_ID_URI}/.default" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

# 2. Exchange for GCP STS token
STS_TOKEN=$(curl -s -X POST "https://sts.googleapis.com/v1/token" \
  --data-urlencode "audience=//iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/azure-pool/providers/azure-provider" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "scope=https://www.googleapis.com/auth/cloud-platform" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "subject_token=$AZURE_TOKEN" | jq -r '.access_token')

# 3. Impersonate Service Account
SA_TOKEN=$(curl -s -X POST \
  "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/azure-bigquery-sa@${PROJECT_ID}.iam.gserviceaccount.com:generateAccessToken" \
  -H "Authorization: Bearer $STS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"scope": ["https://www.googleapis.com/auth/cloud-platform"]}' | jq -r '.accessToken')

# 4. Query BigQuery
curl -s -X POST \
  "https://bigquery.googleapis.com/bigquery/v2/projects/$PROJECT_ID/queries" \
  -H "Authorization: Bearer $SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "SELECT corpus, COUNT(*) as cnt FROM `bigquery-public-data.samples.shakespeare` GROUP BY corpus ORDER BY cnt DESC LIMIT 5", "useLegacySql": false}' \
  | jq -r '.rows[]? | "\(.f[0].v): \(.f[1].v)"'
```

---



---

## Enterprise Best Practices

### 1. Pool and Provider Design

Separate pools by environment to prevent cross-environment access:

```
Organization
  +-- Pool: aws-production     (or azure-production)
  |     +-- Provider: account-111111111111
  |     +-- Provider: account-222222222222
  +-- Pool: aws-staging
  |     +-- Provider: account-333333333333
  +-- Pool: aws-development
        +-- Provider: account-444444444444
```

Rules:
- One pool per environment per cloud provider
- One provider per AWS account or Azure tenant
- Never share pools across environments
- Use consistent naming: `{cloud}-{environment}`

### 2. Attribute Mapping and Conditions

Always restrict which identities can authenticate. Never leave attribute conditions empty in production.

**AWS:**
```bash
# Only allow assumed-role ARNs (block IAM users, root)
--attribute-condition="assertion.arn.startsWith('arn:aws:sts::<ACCOUNT_ID>:assumed-role/')"

# Only allow specific roles
--attribute-condition="assertion.arn.contains('assumed-role/production-app/')"

# Map additional attributes for fine-grained access
--attribute-mapping="google.subject=assertion.arn,attribute.aws_role=assertion.arn.extract('assumed-role/{role}/')"
```

**Azure:**
```bash
# Only allow specific managed identities
--attribute-condition="assertion.sub == '<OBJECT_ID>'"

# Only allow specific tenant
--attribute-condition="assertion.tid == '<TENANT_ID>'"
```

### 3. Service Account Strategy

| Pattern | Use Case | Risk Level |
|---------|----------|------------|
| One SA per workload | Production critical apps | Lowest |
| One SA per team | Staging, shared services | Medium |
| One SA per environment | Development only | Highest |

Rules:
- Grant roles at resource level, not project level
- Use custom roles when predefined roles are too broad
- Never use `roles/editor` or `roles/owner` in production
- Review SA permissions quarterly

```bash
# Good: resource-level, specific role
gcloud storage buckets add-iam-policy-binding gs://specific-bucket \
  --role=roles/storage.objectViewer \
  --member="serviceAccount:..."

# Bad: project-level, broad role
gcloud projects add-iam-policy-binding PROJECT \
  --role=roles/editor \
  --member="serviceAccount:..."
```

### 4. Credential Configuration Management

The credential config file contains no secrets, but manage it properly:

| Workload Type | Storage Method |
|---------------|---------------|
| EC2 / Azure VM | File on disk, path in env var |
| Lambda / Functions | Bundled in deployment package |
| EKS / AKS | Kubernetes Secret or ConfigMap |
| CI/CD Pipeline | Pipeline secrets manager |
| Terraform | Environment variable |

Rules:
- Safe to commit to git (no secrets inside)
- Use separate credential configs per SA (one per use case)
- Set `GOOGLE_APPLICATION_CREDENTIALS` env var, never hardcode paths

### 5. Organizational Policy Constraints

Enforce WIF usage across the organization:

```bash
# Disable SA key creation (force WIF)
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.disableServiceAccountKeyCreation
booleanPolicy:
  enforced: true
EOF

# Restrict allowed identity providers
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.workloadIdentityPoolProviders
listPolicy:
  allowedValues:
    - "aws"
    - "oidc"
EOF

# Disable SA key upload
gcloud org-policies set-policy --project=<PROJECT_ID> << EOF
constraint: iam.disableServiceAccountKeyUpload
booleanPolicy:
  enforced: true
EOF
```

### 6. Monitoring and Audit

Enable and monitor Cloud Audit Logs:

```bash
# Token exchange events (who authenticated)
gcloud logging read '
  resource.type="audited_resource"
  AND protoPayload.serviceName="sts.googleapis.com"
' --project=<PROJECT_ID> --limit=10 --format=json

# SA impersonation events (who got access tokens)
gcloud logging read '
  resource.type="service_account"
  AND protoPayload.methodName="GenerateAccessToken"
' --project=<PROJECT_ID> --limit=10 --format=json
```

Set up alerts:
- Alert on token exchange failures (potential unauthorized access attempts)
- Alert on new principal accessing a SA for the first time
- Alert on access from unexpected AWS accounts or Azure tenants
- Export logs to SIEM via Logpush for centralized monitoring

### 7. Network Security

Use VPC Service Controls to restrict STS access:

```bash
# Create service perimeter
gcloud access-context-manager perimeters create wif-perimeter \
  --resources="projects/<PROJECT_NUMBER>" \
  --restricted-services="sts.googleapis.com,iamcredentials.googleapis.com"
```

Use regional STS endpoints for data residency compliance:
```
https://sts.us-central1.rep.googleapis.com/v1/token
https://sts.europe-west1.rep.googleapis.com/v1/token
https://sts.asia-southeast1.rep.googleapis.com/v1/token
```

### 8. Token Lifetime and Session Management

- Default SA token lifetime: 1 hour (recommended)
- Maximum configurable: 12 hours (requires org policy override)
- Tokens are not revocable - keep lifetime short
- For long-running jobs, implement token refresh in application code

```python
# Python: auto-refresh is built into google-auth library
# Just set GOOGLE_APPLICATION_CREDENTIALS and the library handles refresh
from google.cloud import bigquery
client = bigquery.Client()  # auto-refreshes tokens
```

### 9. Disaster Recovery and High Availability

- Credential config files are stateless - no backup needed
- Pool/Provider config: manage via Terraform with remote state
- If GCP STS is unavailable: workloads cannot authenticate (design for this)
- Mitigation: use regional STS endpoints, implement circuit breaker pattern
- Keep Terraform state in GCS backend with versioning enabled

```hcl
terraform {
  backend "gcs" {
    bucket = "my-terraform-state"
    prefix = "wif"
  }
}
```

### 10. Multi-Cloud Governance

For organizations using both AWS and Azure with GCP:

| Aspect | Recommendation |
|--------|---------------|
| Pool naming | `{cloud}-{environment}` (aws-production, azure-staging) |
| SA naming | `{cloud}-{function}-{environment}` (aws-bigquery-production) |
| Role assignment | Same least-privilege rules regardless of source cloud |
| Monitoring | Unified dashboard for all WIF token exchanges |
| IaC | Separate Terraform modules per cloud, shared variables |
| Rotation | No rotation needed (keyless), but review access quarterly |



---

## Terraform Module

See [terraform/](terraform/) for a production-ready module. Verified with `terraform apply` + BigQuery test on 2026-03-29.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

## Examples

| File | Description |
|------|-------------|
| [examples/bigquery_query.py](examples/bigquery_query.py) | Query BigQuery |
| [examples/gcs_sync.py](examples/gcs_sync.py) | Sync files to Cloud Storage |
| [examples/cloud_logging.py](examples/cloud_logging.py) | Send logs to Cloud Logging |

## References

- [GCP: Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [GCP: WIF Best Practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [Terraform: Google Cloud Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)

## License

MIT License - see [LICENSE](LICENSE)

