# Enterprise Security Hardening for WIF

Based on [GCP Official Best Practices](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation) and industry standards (CIS, SOC2, ISO 27001).

## 1. Dedicated Project for WIF Management

> **GCP Recommendation:** Use a dedicated project to manage workload identity pools and providers.

```bash
# Create dedicated project
gcloud projects create wif-management --organization=<ORG_ID>

# Apply org policy to prevent pool creation elsewhere
gcloud org-policies set-policy --organization=<ORG_ID> << 'EOF'
constraint: constraints/iam.workloadIdentityPoolProviders
listPolicy:
  deniedValues:
    - "*"
EOF

# Exception for the dedicated project
gcloud org-policies set-policy --project=wif-management << 'EOF'
constraint: constraints/iam.workloadIdentityPoolProviders
listPolicy:
  allowedValues:
    - "aws"
EOF
```

## 2. One Provider per Pool (Avoid Subject Collisions)

> **GCP Recommendation:** Use a single provider per workload identity pool to avoid subject collisions.

```
# CORRECT: One provider per pool
Pool: aws-production    → Provider: hub-provider (AWS)
Pool: aws-staging       → Provider: hub-provider (AWS)
Pool: azure-production  → Provider: azure-hub (OIDC)

# WRONG: Multiple providers in one pool (risk of subject collision)
Pool: multi-cloud → Provider: aws-provider + azure-provider
```

## 3. Attribute Conditions (Mandatory in Production)

> **GCP Recommendation:** Never leave attribute conditions empty in production.

### AWS Provider

```bash
# Restrict to assumed-role ARNs only (block IAM users, root)
--attribute-condition="assertion.arn.startsWith('arn:aws:sts::${HUB_ACCOUNT_ID}:assumed-role/')"

# Production: further restrict to roles containing '-prod-'
--attribute-condition="assertion.arn.startsWith('arn:aws:sts::${HUB_ACCOUNT_ID}:assumed-role/') && assertion.arn.contains('-prod-')"
```

### Azure Provider

```bash
# Restrict to specific tenant
--attribute-condition="assertion.tid == '${TENANT_ID}'"

# Further restrict to specific managed identities
--attribute-condition="assertion.tid == '${TENANT_ID}' && assertion.sub in ['${MI_OID_1}', '${MI_OID_2}']"
```

## 4. Immutable & Non-Reusable Attributes

> **GCP Recommendation:** Use immutable, non-reusable attributes in attribute mappings.

| Cloud | ✅ Use (immutable) | ❌ Avoid (mutable) |
|-------|-------------------|-------------------|
| AWS | `assertion.arn` | Email, tags |
| Azure | `assertion.sub` (Object ID) | `assertion.email`, `assertion.name` |
| OIDC | `assertion.sub` | `assertion.preferred_username` |

```bash
# AWS: Map ARN (immutable)
--attribute-mapping="google.subject=assertion.arn"

# Azure: Map Object ID (immutable, non-reusable)
--attribute-mapping="google.subject=assertion.sub"
```

## 5. Service Account Isolation

> **GCP Recommendation:** Use a dedicated service account for each application. Avoid granting access to all members of a pool.

```bash
# CORRECT: Grant to specific principal
gcloud iam service-accounts add-iam-policy-binding SA@PROJECT.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principal://iam.googleapis.com/projects/NUM/locations/global/workloadIdentityPools/POOL/subject/SPECIFIC_ARN"

# WRONG: Grant to all pool members
--member="principalSet://iam.googleapis.com/projects/NUM/locations/global/workloadIdentityPools/POOL/*"
```

## 6. Organization Policy Constraints

```bash
# Disable SA key creation (force WIF usage)
gcloud org-policies set-policy --organization=<ORG_ID> << 'EOF'
constraint: iam.disableServiceAccountKeyCreation
booleanPolicy:
  enforced: true
EOF

# Disable SA key upload
gcloud org-policies set-policy --organization=<ORG_ID> << 'EOF'
constraint: iam.disableServiceAccountKeyUpload
booleanPolicy:
  enforced: true
EOF

# Restrict WIF providers to known types
gcloud org-policies set-policy --project=wif-management << 'EOF'
constraint: iam.workloadIdentityPoolProviders
listPolicy:
  allowedValues:
    - "aws"
    - "oidc"
EOF
```

## 7. VPC Service Controls

> **GCP Recommendation:** Use VPC Service Controls to restrict STS access.

```bash
# Create access policy
gcloud access-context-manager policies create --organization=<ORG_ID> --title="WIF Controls"

# Create perimeter protecting STS and IAM Credentials
gcloud access-context-manager perimeters create wif-perimeter \
  --policy=<POLICY_ID> \
  --resources="projects/<PROJECT_NUMBER>" \
  --restricted-services="sts.googleapis.com,iamcredentials.googleapis.com" \
  --title="WIF Perimeter"
```

### Regional STS Endpoints (Data Residency)

```bash
# Use regional endpoints for compliance
gcloud iam workload-identity-pools create-cred-config \
  projects/<NUM>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER> \
  --service-account=<SA>@<PROJECT>.iam.gserviceaccount.com \
  --aws --enable-imdsv2 \
  --output-file=gcp-credentials.json
```

Regional endpoints:
- `https://sts.us-central1.rep.googleapis.com/v1/token`
- `https://sts.europe-west1.rep.googleapis.com/v1/token`
- `https://sts.asia-southeast1.rep.googleapis.com/v1/token`

## 8. Audit Logging (Data Access Logs)

> **GCP Recommendation:** Enable data access logs for Security Token Service API and IAM API.

```yaml
# Enable via project IAM policy audit config
auditConfigs:
  - service: sts.googleapis.com
    auditLogConfigs:
      - logType: DATA_READ
      - logType: DATA_WRITE
  - service: iamcredentials.googleapis.com
    auditLogConfigs:
      - logType: DATA_READ
      - logType: DATA_WRITE
  - service: iam.googleapis.com
    auditLogConfigs:
      - logType: DATA_READ
```

### Monitoring Queries

```bash
# Token exchange events
gcloud logging read '
  resource.type="audited_resource"
  AND protoPayload.serviceName="sts.googleapis.com"
  AND protoPayload.methodName="google.identity.sts.v1.SecurityTokenService.ExchangeToken"
' --project=<PROJECT> --limit=50

# Failed token exchanges (unauthorized attempts)
gcloud logging read '
  resource.type="audited_resource"
  AND protoPayload.serviceName="sts.googleapis.com"
  AND severity="ERROR"
' --project=<PROJECT> --limit=20

# SA impersonation events
gcloud logging read '
  resource.type="service_account"
  AND protoPayload.methodName="GenerateAccessToken"
' --project=<PROJECT> --limit=50
```

### Alert Policies (Cloud Monitoring)

| Alert | Condition | Severity |
|-------|-----------|----------|
| Unknown identity exchanging token | `subject` not in approved list | Critical |
| Token exchange failure spike | > 10 failures / 5 min | High |
| New principal impersonating SA | First occurrence | Medium |
| Off-hours token exchange | Outside business hours | Low |

## 9. IAM Deny Policies

Prevent accidental deletion of WIF resources:

```bash
gcloud iam policies create deny-wif-deletion \
  --attachment-point="cloudresourcemanager.googleapis.com/projects/<PROJECT_ID>" \
  --kind=denypolicies \
  --policy-file=- << 'EOF'
{
  "displayName": "Deny WIF resource deletion",
  "rules": [{
    "denyRule": {
      "deniedPermissions": [
        "iam.googleapis.com/workloadIdentityPools.delete",
        "iam.googleapis.com/workloadIdentityPoolProviders.delete",
        "iam.googleapis.com/serviceAccounts.delete"
      ],
      "deniedPrincipals": ["principalSet://goog/public:all"],
      "exceptionPrincipals": [
        "principal://goog/subject/wif-admin@example.com"
      ]
    }
  }]
}
EOF
```

## 10. Credential Configuration Security

> **GCP Recommendation:** Credential config files contain no secrets but validate them from external sources.

| Property | Recommendation |
|----------|---------------|
| Storage | Safe in VCS (no secrets) |
| Validation | Verify `token_url` points to `sts.googleapis.com` |
| Audience | Must match your provider URL exactly |
| Per-workload | Separate config per SA (isolation) |
| Env var | `GOOGLE_APPLICATION_CREDENTIALS` (never hardcode) |

### Validation Checklist

Before deploying a credential config:
- [ ] `token_url` starts with `https://sts.googleapis.com` or `https://sts.REGION.rep.googleapis.com`
- [ ] `service_account_impersonation_url` starts with `https://iamcredentials.googleapis.com`
- [ ] `audience` matches your WIF pool/provider URL
- [ ] No unexpected URLs in `credential_source`

## 11. Token Lifetime Management

| Setting | Recommended | Max |
|---------|-------------|-----|
| SA access token TTL | 1 hour (default) | 12 hours (org policy override) |
| AWS STS session | 1 hour | 12 hours |
| Azure token | 1 hour | Configurable |

- Tokens are **not revocable** — keep lifetime short
- google-auth library handles auto-refresh
- For long-running jobs: implement graceful token refresh

## 12. Compliance Mapping

| Framework | WIF Control |
|-----------|-------------|
| CIS GCP 1.x | 1.15: Disable SA keys ✓ |
| SOC2 CC6.1 | Logical access: keyless auth ✓ |
| SOC2 CC6.2 | Authentication: short-lived tokens ✓ |
| ISO 27001 A.9.4 | System access control: federation ✓ |
| NIST 800-53 IA-2 | Identification: external IdP ✓ |
| NIST 800-53 IA-5 | Authenticator mgmt: auto-rotate ✓ |
| PCI-DSS 8.6 | Service account management ✓ |

## References

- [GCP: Best Practices for WIF](https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation)
- [GCP: Secure IAM with VPC SC](https://cloud.google.com/iam/docs/secure-iam-vpc-sc)
- [GCP: WIF Audit Logging Examples](https://cloud.google.com/iam/docs/audit-logging/examples-workload-identity)
- [GCP: Organization Policy Constraints](https://cloud.google.com/iam/docs/manage-workload-identity-pools-providers#restrict)
- [GCP: Troubleshoot WIF](https://cloud.google.com/iam/docs/troubleshooting-workload-identity-federation)
- [AWS: SCP Best Practices](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [Azure: Conditional Access for Workload Identities](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity)
- [ArXiv: Zero Trust CI/CD with WIF (2025)](https://arxiv.org/abs/2504.14760)
