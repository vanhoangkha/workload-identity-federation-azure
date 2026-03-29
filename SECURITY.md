# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. Do NOT open a public issue
2. Email: security@example.com
3. Include steps to reproduce

## Security Best Practices

- Never commit credentials, tokens, or account IDs
- Use `terraform.tfvars` (gitignored) for sensitive values
- Rotate Service Account keys if accidentally exposed
- Enable org policy `iam.disableServiceAccountKeyCreation`
