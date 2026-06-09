output "envoy_proxy_env_secret_name" {
  description = "The name of the Kubernetes secret containing Envoy proxy env vars"
  value       = local.enable_envoy_resources ? kubernetes_secret_v1.envoy_https_proxy_env[0].metadata[0].name : null
}

output "envoy_proxy_service_name" {
  description = "The name of the Envoy proxy service"
  value       = local.enable_envoy_resources ? kubernetes_service_v1.envoy_https_proxy[0].metadata[0].name : null
}
