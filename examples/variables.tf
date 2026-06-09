variable "application" {
  description = "Application name"
  type        = string
  default     = "hmpps-egress-controls-example"
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
