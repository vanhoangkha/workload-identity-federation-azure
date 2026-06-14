# Enterprise Hub-and-Spoke Pattern for Azure to GCP WIF

## Overview

In multi-subscription Azure environments, the **Hub-and-Spoke** pattern consolidates federation through a single dedicated **Entra ID Application** and centralized tenant, reducing the number of GCP WIF providers to one per environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 Azure Spoke Subscriptions                        │
│                                                                 │
│  Subscription A (AKS clusters)     Subscription B (VMs)         │
│  ┌──────────────────────────┐     ┌──────────────────────────┐  │
│  │ AKS Pod                   │     │ Azure VM                  │  │
│  │ Workload Identity: MI-A   │     │ Managed Identity: MI-B    │  │
│  └────────────┬─────────────┘     └────────────┬─────────────┘  │
│               │ Get token for                   │ Get token for  │
│               │ Hub App ID URI                  │ Hub App ID URI │
└───────────────┼─────────────────────────────────┼────────────────┘
                ▼                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│           Microsoft Entra ID (Single Tenant)                    │
│                                                                 │
│  Hub App Registration: "gcp-wif-hub"                            │
│  App ID URI: api://<CLIENT_ID>                                  │
│                                                                 │
│  Issues JWT with:                                               │
│    sub = Managed Identity Object ID                             │
│    aud = api://<CLIENT_ID>                                      │
│    iss = https://sts.windows.net/<TENANT_ID>/                   │
└────────────────────────┬────────────────────────────────────────┘
                         │ OIDC JWT
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              GCP Workload Identity Federation                    │
│                                                                 │
│  Pool: azure-production                                         │
│  Provider: azure-hub (OIDC)                                     │
│    issuer: https://sts.windows.net/<TENANT_ID>/                 │
│    audience: api://<CLIENT_ID>                                  │
│                                                                 │
│  Attribute Mapping:                                             │
│    google.subject = assertion.sub (= MI Object ID)              │
│                                                                 │
│  SA Binding: principal matched by assertion.sub                 │
└────────────────────────┬────────────────────────────────────────┘
                         │ Short-lived access token
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              GCP Resources                                       │
│  BigQuery, Cloud Storage, Pub/Sub, Cloud Logging, ...           │
└─────────────────────────────────────────────────────────────────┘
```

## Why Hub-and-Spoke for Azure?

| Aspect | Direct (1 App per workload) | Hub-and-Spoke (1 App) |
|--------|---------------------------|----------------------|
| Entra ID Apps needed | N (one per workload) | 1 per environment |
| WIF Providers | N | 1 |
| Subject tracking | App-specific | MI Object ID (stable) |
| Onboarding | Create App + update WIF | Add MI + SA binding |
| Audit | Scattered | Centralized |

## Implementation

### Step 1: Register Hub App in Entra ID

```bash
# Create a single app for all workloads to request tokens from
az ad app create \
  --display-name "gcp-wif-hub-production" \
  --sign-in-audience "AzureADMyOrg"

# Set App ID URI
az ad app update --id <APP_ID> --identifier-uris "api://<APP_ID>"
```

### Step 2: Grant Managed Identities Access to Hub App

Each Managed Identity that needs GCP access must be able to get tokens for the Hub App:

```bash
# Get the Enterprise App (Service Principal) object ID
SP_ID=$(az ad sp show --id <APP_ID> --query id -o tsv)

# Grant MI-A permission (no explicit grant needed for client_credentials
# with Managed Identity — Entra ID issues tokens automatically)
```

> **Note:** Managed Identities can request tokens for any App ID URI in the same tenant without explicit permission grants (unlike service principals which need app role assignments).

### Step 3: Configure GCP WIF Provider

```bash
gcloud iam workload-identity-pools providers create-oidc azure-hub \
  --location=global \
  --workload-identity-pool=azure-production \
  --issuer-uri="https://sts.windows.net/<TENANT_ID>/" \
  --allowed-audiences="api://<APP_ID>" \
  --attribute-mapping="google.subject=assertion.sub,attribute.tenant=assertion.tid"
```

### Step 4: Bind GCP SA per Managed Identity

```bash
# Each MI's Object ID becomes the subject
MI_OBJECT_ID="<MANAGED_IDENTITY_OBJECT_ID>"

PRINCIPAL="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-production/subject/${MI_OBJECT_ID}"

gcloud iam service-accounts add-iam-policy-binding \
  my-service-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="$PRINCIPAL"

gcloud iam service-accounts add-iam-policy-binding \
  my-service-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="$PRINCIPAL"
```

### Step 5: Application Code (Python)

```python
import requests
from google.auth import identity_pool
from google.auth.transport.requests import Request
from google.cloud import storage

APP_ID_URI = "api://<APP_ID>"
WIF_AUDIENCE = "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-production/providers/azure-hub"
GCP_SA_EMAIL = "my-service-sa@<PROJECT_ID>.iam.gserviceaccount.com"

def get_azure_token():
    """Get token from Azure IMDS (Managed Identity)."""
    resp = requests.get(
        "http://169.254.169.254/metadata/identity/oauth2/token",
        params={"api-version": "2018-02-01", "resource": APP_ID_URI},
        headers={"Metadata": "true"},
        timeout=5,
    )
    return resp.json()["access_token"]

# Use credential config file approach (recommended)
# gcloud iam workload-identity-pools create-cred-config ... --azure --app-id-uri=<URI>
```

## Onboarding a New Workload

1. Create Managed Identity (system or user-assigned) in the spoke subscription
2. Note the MI's **Object ID**
3. Create GCP Service Account
4. Bind SA to the MI's Object ID as principal
5. Grant GCP roles to the SA
6. Configure credential file on the workload

**No changes needed** to Entra ID App or WIF Provider.

## Security Controls

### Attribute Conditions

```bash
# Only allow specific tenant (defense-in-depth)
--attribute-condition="assertion.tid == '<TENANT_ID>'"

# Only allow specific MIs (allowlist)
--attribute-condition="assertion.sub in ['<MI_OBJECT_ID_1>', '<MI_OBJECT_ID_2>']"
```

### Separate Pools per Environment

```
Organization
  +-- Pool: azure-production
  |     +-- Provider: azure-hub (tenant + prod app)
  +-- Pool: azure-staging
  |     +-- Provider: azure-hub-stag (tenant + staging app)
  +-- Pool: azure-development
        +-- Provider: azure-hub-dev (tenant + dev app)
```

## Terraform Module

See [`terraform/hub-and-spoke/`](../terraform/hub-and-spoke/) for a complete module.

## References

- [GCP: WIF with OIDC](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Azure: Managed Identity Token Request](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token)
- [Azure: App Registration](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
