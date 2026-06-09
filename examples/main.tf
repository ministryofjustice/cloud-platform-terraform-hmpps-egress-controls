module "hmpps_egress_controls" {
  source = "../"

  enable_envoy_setup     = true
  enable_egress_controls = true
  application            = var.application
  namespace              = var.namespace
  vpc_name               = var.vpc_name
}
