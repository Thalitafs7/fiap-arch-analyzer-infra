# =============================================================================
# K8s Config Module - Outputs
# =============================================================================

output "ingress_nginx_namespace" {
  description = "Namespace where the NGINX Ingress Controller is installed"
  value       = "ingress-nginx"
}

output "app_namespaces" {
  description = "Application namespaces bootstrapped by this module (receive infra-outputs ConfigMap)"
  value       = ["arch-analyzer-api", "arch-analyzer-ia", "auth"]
}

output "all_namespaces" {
  description = "All namespaces created by this module"
  value       = ["arch-analyzer-api", "arch-analyzer-ia", "auth", "data", "ingress-nginx"]
}

output "infra_outputs_configmap_name" {
  description = "Name of the shared infra-outputs ConfigMap published in every application namespace"
  value       = "infra-outputs"
}
