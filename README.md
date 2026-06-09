# cloud-platform-terraform-hmpps-egress-controls

[![Releases](https://img.shields.io/github/v/release/ministryofjustice/cloud-platform-terraform-hmpps-egress-controls.svg)](https://github.com/ministryofjustice/cloud-platform-terraform-hmpps-egress-controls/releases)

Terraform module that supports staged rollout of namespace egress controls with Calico and an internal Envoy proxy, and exposes ready-to-use proxy environment secrets for workloads.

## Rollout Stages

1. Stage 1: Set `enable_envoy_setup = true` and keep `enable_egress_controls = false` to install Envoy and publish proxy secrets.
2. Stage 2: Set `enable_egress_controls = true` to apply egress-deny and allow policies that enforce proxy usage.

## Usage

```hcl
module "hmpps_egress_controls" {
  source = "github.com/ministryofjustice/cloud-platform-terraform-hmpps-egress-controls?ref=x.x.x"

  enable_envoy_setup     = true
  enable_egress_controls = true
  namespace              = "my-namespace"
  vpc_name               = "live-1"
}
```

## Features

When `enable_envoy_setup = true` (or `enable_egress_controls = true`), this module creates:
- Envoy proxy `ConfigMap`, `Deployment`, `Service`, and `PodDisruptionBudget`.
- Proxy env secret for workloads with `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, lowercase variants, and `JAVA_PROXY_TOOL_OPTIONS`.

When `enable_egress_controls = true`, this module also creates:
- Calico `NetworkPolicy` resources for DNS egress, in-namespace pod egress, Envoy routing, VPC egress for PostgreSQL/Redis ports, and default deny egress.

## Examples

See [examples/](examples/) for a complete example.
