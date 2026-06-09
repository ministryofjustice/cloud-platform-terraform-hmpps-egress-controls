output "envoy_proxy_env_secret_name" {
  value = module.hmpps_egress_controls.envoy_proxy_env_secret_name
}

output "envoy_proxy_service_name" {
  value = module.hmpps_egress_controls.envoy_proxy_service_name
}
