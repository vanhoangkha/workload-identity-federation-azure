# AKS Workload Identity to GCP via WIF

## Overview

**AKS Workload Identity** (successor to AAD Pod Identity) enables pods to authenticate as a Managed Identity using federated OIDC tokens — no secrets needed. Combined with GCP WIF, this gives you keyless Kubernetes-to-GCP access.

## Authentication Flow

```
┌─────────────────────────────────────────────────────────────┐
│  AKS Cluster (OIDC Issuer enabled)                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Pod                                                   │  │
│  │  ServiceAccount: my-app                                │  │
│  │  Label: azure.workload.identity/use: "true"            │  │
│  │                                                        │  │
│  │  Injected by AKS Workload Identity:                    │  │
│  │  - AZURE_CLIENT_ID                                     │  │
│  │  - AZURE_TENANT_ID                                     │  │
│  │  - AZURE_FEDERATED_TOKEN_FILE (/var/run/secrets/...)   │  │
│  └────────────────────┬──────────────────────────────────┘  │
└───────────────────────┼──────────────────────────────────────┘
                        │ ① Exchange federated token for
                        │    Entra ID access token (audience = Hub App)
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  Microsoft Entra ID                                         │
│  Issues JWT: sub=MI Object ID, aud=api://<APP_ID>           │
└────────────────────────┬────────────────────────────────────┘
                         │ ② OIDC JWT sent to GCP STS
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Security Token Service                                 │
│  Validates JWT signature via Entra ID OIDC discovery        │
│  Issues federated token                                     │
└────────────────────────┬────────────────────────────────────┘
                         │ ③ Impersonate GCP SA
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Service Account → Access Token (1h TTL)                │
└────────────────────────┬────────────────────────────────────┘
                         │ ④ Access GCP resources
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GCP Resources: BigQuery, GCS, Pub/Sub, etc.                │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AKS cluster with **OIDC Issuer** and **Workload Identity** enabled
- User-assigned Managed Identity with federated credential for the K8s SA
- GCP WIF pool with OIDC provider for your Entra ID tenant

## Setup

### 1. Enable AKS Workload Identity

```bash
# Create or update cluster with OIDC + Workload Identity
az aks create \
  --name my-cluster \
  --resource-group my-rg \
  --enable-oidc-issuer \
  --enable-workload-identity

# Get OIDC issuer URL
OIDC_ISSUER=$(az aks show --name my-cluster --resource-group my-rg --query "oidcIssuerProfile.issuerUrl" -o tsv)
```

### 2. Create Managed Identity + Federated Credential

```bash
# Create MI
az identity create --name my-app-identity --resource-group my-rg
MI_CLIENT_ID=$(az identity show --name my-app-identity --resource-group my-rg --query clientId -o tsv)
MI_OBJECT_ID=$(az identity show --name my-app-identity --resource-group my-rg --query principalId -o tsv)

# Create federated credential (links K8s SA to MI)
az identity federated-credential create \
  --name my-app-fedcred \
  --identity-name my-app-identity \
  --resource-group my-rg \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:default:my-app" \
  --audience "api://AzureADTokenExchange"
```

### 3. Create Kubernetes ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  namespace: default
  annotations:
    azure.workload.identity/client-id: "<MI_CLIENT_ID>"
  labels:
    azure.workload.identity/use: "true"
```

### 4. Configure GCP WIF

```bash
# Create pool + OIDC provider
gcloud iam workload-identity-pools create azure-pool --location=global
gcloud iam workload-identity-pools providers create-oidc azure-provider \
  --location=global \
  --workload-identity-pool=azure-pool \
  --issuer-uri="https://sts.windows.net/<TENANT_ID>/" \
  --allowed-audiences="api://<HUB_APP_ID>" \
  --attribute-mapping="google.subject=assertion.sub"

# Bind SA
PRINCIPAL="principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-pool/subject/${MI_OBJECT_ID}"

gcloud iam service-accounts add-iam-policy-binding \
  my-gcp-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser --member="$PRINCIPAL"
gcloud iam service-accounts add-iam-policy-binding \
  my-gcp-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --role=roles/iam.serviceAccountTokenCreator --member="$PRINCIPAL"
```

### 5. Generate Credential Config

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-pool/providers/azure-provider \
  --service-account=my-gcp-sa@<PROJECT_ID>.iam.gserviceaccount.com \
  --azure \
  --app-id-uri="api://<HUB_APP_ID>" \
  --output-file=gcp-credentials.json
```

### 6. Application Code

```python
"""AKS Workload Identity → Entra ID → GCP WIF → GCS"""
import os
from google.cloud import storage

# Just set the credential config — google-auth handles the rest:
# 1. Gets Azure token via AZURE_FEDERATED_TOKEN_FILE
# 2. Exchanges for GCP STS token
# 3. Impersonates GCP SA
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = "/app/gcp-credentials.json"

client = storage.Client(project="<PROJECT_ID>")
blobs = list(client.list_blobs("<BUCKET>", max_results=5))
for b in blobs:
    print(b.name)
```

### 7. Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      labels:
        app: my-app
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: my-app
      containers:
        - name: app
          image: my-app:latest
          env:
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: "/app/gcp-credentials.json"
          volumeMounts:
            - name: gcp-creds
              mountPath: /app/gcp-credentials.json
              subPath: gcp-credentials.json
      volumes:
        - name: gcp-creds
          configMap:
            name: gcp-wif-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gcp-wif-config
data:
  gcp-credentials.json: |
    {
      "type": "external_account",
      "audience": "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/azure-pool/providers/azure-provider",
      "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
      "token_url": "https://sts.googleapis.com/v1/token",
      "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/my-gcp-sa@<PROJECT_ID>.iam.gserviceaccount.com:generateAccessToken",
      "credential_source": {
        "url": "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://<HUB_APP_ID>",
        "headers": {"Metadata": "true"},
        "format": {"type": "json", "subject_token_field_name": "access_token"}
      }
    }
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `AADSTS70021: No matching federated identity record found` | Federated credential subject mismatch | Verify namespace:sa-name matches exactly |
| `Invalid audience` | App ID URI mismatch between Entra and WIF | Check `--allowed-audiences` |
| `Token validation failed` | Issuer mismatch (missing trailing slash) | Use `https://sts.windows.net/<TENANT>/` |
| Pod not getting Azure tokens | Missing label `azure.workload.identity/use: "true"` | Add label to pod template |
| `iam.serviceAccounts.getAccessToken denied` | Missing `serviceAccountTokenCreator` | Grant both WIF roles |

## References

- [Azure: AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure: Federated Credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GCP: WIF with OIDC](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
