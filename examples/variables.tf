variable "resource_name_prefix" {
  description = "Optional naming prefix; defaults to 'hmpps' in the module"
  type        = string
  default     = "hmpps"
  nullable    = false
}

variable "namespace" {
  description = "Namespace name"
  type        = string
  default     = "hmpps-egress-controls-example"
}

variable "vpc_name" {
  description = "VPC Name tag"
  type        = string
  default     = "live-1"
}
