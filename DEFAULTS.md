# Default Allowed Hosts

This module includes default allowlists for common HMPPS service dependencies. These are automatically included when you use the module.

## Default Exact Hostnames

These specific hostnames are allowed by default:

- `sqs.eu-west-2.amazonaws.com` - AWS SQS service endpoint
- `sts.eu-west-2.amazonaws.com` - AWS STS service endpoint
- `agent.azureserviceprofiler.net` - Azure Application Insights profiler

## Default Hostname Suffixes

These domain suffixes are allowed by default (any subdomain under these will be permitted):

- `.in.applicationinsights.azure.com` - Azure Application Insights telemetry
- `.livediagnostics.monitor.azure.com` - Azure monitoring and diagnostics
- `.service.justice.gov.uk` - HMPPS internal services

## Adding Additional Hosts

If your service needs to connect to additional external services, add them using the module's extra allowlist variables:

```hcl
module "hmpps_egress_controls" {
  source = "github.com/ministryofjustice/cloud-platform-terraform-hmpps-egress-controls?ref=1.0.0"

  # ... required variables ...

  # Additional exact hostnames
  envoy_extra_allowed_hosts_exact = [
    "api.example.com",
    "partner-service.example.org",
  ]

  # Additional domain suffixes
  envoy_extra_allowed_hosts_suffixes = [
    ".example.com",
    ".third-party-service.io",
  ]
}
```

## Rules for Hostnames and Suffixes

- **Exact hostnames** must be complete DNS names without schemes, paths, wildcards, or ports
  - ✅ `api.example.com`
  - ❌ `https://api.example.com` (no scheme)
  - ❌ `*.example.com` (no wildcards)
  - ❌ `api.example.com:443` (no port)

- **Suffixes** must start with `.` and be valid DNS suffixes
  - ✅ `.example.com`
  - ❌ `example.com` (must start with `.`)
  - ❌ `.*.example.com` (no wildcards)

## Definitive Source

The definitive and up-to-date list of defaults is maintained in [variables.tf](./variables.tf). See:
- `envoy_default_allowed_hosts_exact` (line ~63)
- `envoy_default_allowed_hosts_suffixes` (line ~75)
