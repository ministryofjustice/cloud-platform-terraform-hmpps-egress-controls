#################
# Configuration #
#################

variable "enable_egress_controls" {
  description = "Whether to create Calico egress policies and an Envoy HTTPS proxy deployment"
  type        = bool
  default     = false
}

variable "enable_envoy_setup" {
  description = "Whether to install Envoy proxy resources and publish proxy secrets without enforcing egress controls"
  type        = bool
  default     = false
}

variable "vpc_name" {
  description = "VPC Name tag used to look up private and EKS-private subnet CIDRs for VPC egress policies"
  type        = string
}

variable "envoy_proxy_name" {
  description = "Base name used for the Envoy proxy resource suffix and app.kubernetes.io/name label"
  type        = string
  default     = "envoy-https-proxy"
}

variable "envoy_proxy_replicas" {
  description = "Number of Envoy proxy replicas"
  type        = number
  default     = 2
}

variable "envoy_image" {
  description = "Container image for the Envoy proxy"
  type        = string
  default     = "envoyproxy/envoy:v1.38-latest"
}

variable "envoy_log_level" {
  description = "Envoy runtime log level"
  type        = string
  default     = "info"
}

variable "envoy_proxy_port" {
  description = "Envoy forward proxy listening port"
  type        = number
  default     = 3128
}

variable "envoy_dns_host_ttl" {
  description = "TTL used for cached DNS hosts in Envoy"
  type        = string
  default     = "60s"
}

variable "envoy_connect_timeout" {
  description = "Upstream connect timeout for the dynamic forward proxy cluster"
  type        = string
  default     = "10s"
}

variable "envoy_default_allowed_hosts_exact" {
  description = "Approved exact hostnames to allow through the Envoy proxy"
  type        = list(string)
  default = [
    "sqs.eu-west-2.amazonaws.com",
    "sts.eu-west-2.amazonaws.com",
    "sqs.eu-west-1.amazonaws.com",
    "sts.eu-west-1.amazonaws.com",
    "agent.azureserviceprofiler.net",
  ]
  validation {
    condition = alltrue([
      for host in var.envoy_default_allowed_hosts_exact : can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$", host))
    ])
    error_message = "envoy_default_allowed_hosts_exact values must be DNS hostnames only (no scheme, path, wildcard, or port)."
  }
}

variable "envoy_default_allowed_hosts_suffixes" {
  description = "Approved hostname suffixes to allow through the Envoy proxy"
  type        = list(string)
  default = [
    ".in.applicationinsights.azure.com",
    ".livediagnostics.monitor.azure.com",
    ".service.justice.gov.uk",
  ]
  validation {
    condition = alltrue([
      for suffix in var.envoy_default_allowed_hosts_suffixes : can(regex("^\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$", suffix))
    ])
    error_message = "envoy_default_allowed_hosts_suffixes values must start with '.' and contain a valid DNS suffix (for example '.example.com')."
  }
}

variable "envoy_extra_allowed_hosts_exact" {
  description = "Additional exact hostnames to allow through the Envoy proxy, merged with the default list in envoy_default_allowed_hosts_exact"
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for host in var.envoy_extra_allowed_hosts_exact : can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$", host))
    ])
    error_message = "envoy_extra_allowed_hosts_exact values must be DNS hostnames only (no scheme, path, wildcard, or port)."
  }
}

variable "envoy_extra_allowed_hosts_suffixes" {
  description = "Additional hostname suffixes to allow through the Envoy proxy, merged with the default list in envoy_default_allowed_hosts_suffixes"
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for suffix in var.envoy_extra_allowed_hosts_suffixes : can(regex("^\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$", suffix))
    ])
    error_message = "envoy_extra_allowed_hosts_suffixes values must start with '.' and contain a valid DNS suffix (for example '.example.com')."
  }
}

variable "resource_name_prefix" {
  description = "Optional naming prefix for resources; defaults to 'hmpps' when unset"
  type        = string
  default     = "hmpps"
  nullable    = false

  validation {
    condition     = length(trimspace(var.resource_name_prefix)) > 0
    error_message = "resource_name_prefix must be a non-empty string."
  }
}

variable "namespace" {
  description = "Namespace name"
  type        = string
}
