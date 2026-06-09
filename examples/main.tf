module "hmpps_egress_controls" {
  source = "../"

  enable_envoy_setup     = true
  enable_egress_controls = true
  resource_name_prefix   = var.resource_name_prefix
  namespace              = var.namespace
  vpc_name               = var.vpc_name
}
