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
  application            = "my-service"
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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.2.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 4.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 4.0.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [kubernetes_config_map.envoy_https_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map) | resource |
| [kubernetes_deployment.envoy_https_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment) | resource |
| [kubernetes_manifest.calico_egress_policies](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_pod_disruption_budget_v1.envoy_https_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1) | resource |
| [kubernetes_secret.envoy_https_proxy_env](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service.envoy_https_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service) | resource |
| [aws_subnet.eks_private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnets.eks_private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_subnets.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_application"></a> [application](#input\_application) | Application name | `string` | n/a | yes |
| <a name="input_enable_egress_controls"></a> [enable\_egress\_controls](#input\_enable\_egress\_controls) | Whether to create Calico egress policies and an Envoy HTTPS proxy deployment | `bool` | `false` | no |
| <a name="input_enable_envoy_setup"></a> [enable\_envoy\_setup](#input\_enable\_envoy\_setup) | Whether to install Envoy proxy resources and publish proxy secrets without enforcing egress controls | `bool` | `false` | no |
| <a name="input_envoy_connect_timeout"></a> [envoy\_connect\_timeout](#input\_envoy\_connect\_timeout) | Upstream connect timeout for the dynamic forward proxy cluster | `string` | `"10s"` | no |
| <a name="input_envoy_default_allowed_hosts_exact"></a> [envoy\_default\_allowed\_hosts\_exact](#input\_envoy\_default\_allowed\_hosts\_exact) | Approved exact hostnames to allow through the Envoy proxy | `list(string)` | <pre>[<br/>  "sqs.eu-west-2.amazonaws.com",<br/>  "sts.eu-west-2.amazonaws.com",<br/>  "agent.azureserviceprofiler.net"<br/>]</pre> | no |
| <a name="input_envoy_default_allowed_hosts_suffixes"></a> [envoy\_default\_allowed\_hosts\_suffixes](#input\_envoy\_default\_allowed\_hosts\_suffixes) | Approved hostname suffixes to allow through the Envoy proxy | `list(string)` | <pre>[<br/>  ".in.applicationinsights.azure.com",<br/>  ".livediagnostics.monitor.azure.com",<br/>  ".service.justice.gov.uk"<br/>]</pre> | no |
| <a name="input_envoy_dns_host_ttl"></a> [envoy\_dns\_host\_ttl](#input\_envoy\_dns\_host\_ttl) | TTL used for cached DNS hosts in Envoy | `string` | `"60s"` | no |
| <a name="input_envoy_extra_allowed_hosts_exact"></a> [envoy\_extra\_allowed\_hosts\_exact](#input\_envoy\_extra\_allowed\_hosts\_exact) | Additional exact hostnames to allow through the Envoy proxy, merged with the default list in envoy\_default\_allowed\_hosts\_exact | `list(string)` | `[]` | no |
| <a name="input_envoy_extra_allowed_hosts_suffixes"></a> [envoy\_extra\_allowed\_hosts\_suffixes](#input\_envoy\_extra\_allowed\_hosts\_suffixes) | Additional hostname suffixes to allow through the Envoy proxy, merged with the default list in envoy\_default\_allowed\_hosts\_suffixes | `list(string)` | `[]` | no |
| <a name="input_envoy_image"></a> [envoy\_image](#input\_envoy\_image) | Container image for the Envoy proxy | `string` | `"envoyproxy/envoy:v1.38-latest"` | no |
| <a name="input_envoy_log_level"></a> [envoy\_log\_level](#input\_envoy\_log\_level) | Envoy runtime log level | `string` | `"info"` | no |
| <a name="input_envoy_proxy_name"></a> [envoy\_proxy\_name](#input\_envoy\_proxy\_name) | Base name used for the Envoy proxy resource suffix and app.kubernetes.io/name label | `string` | `"envoy-https-proxy"` | no |
| <a name="input_envoy_proxy_port"></a> [envoy\_proxy\_port](#input\_envoy\_proxy\_port) | Envoy forward proxy listening port | `number` | `3128` | no |
| <a name="input_envoy_proxy_replicas"></a> [envoy\_proxy\_replicas](#input\_envoy\_proxy\_replicas) | Number of Envoy proxy replicas | `number` | `2` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace name | `string` | n/a | yes |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | VPC Name tag used to look up private and EKS-private subnet CIDRs for VPC egress policies | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_envoy_proxy_env_secret_name"></a> [envoy\_proxy\_env\_secret\_name](#output\_envoy\_proxy\_env\_secret\_name) | The name of the Kubernetes secret containing Envoy proxy env vars |
| <a name="output_envoy_proxy_service_name"></a> [envoy\_proxy\_service\_name](#output\_envoy\_proxy\_service\_name) | The name of the Envoy proxy service |
<!-- END_TF_DOCS -->