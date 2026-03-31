# =============================================================================
# K8s Config Module - Outputs
# =============================================================================

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = "argocd"
}

output "ingress_nginx_namespace" {
  description = "Namespace where NGINX Ingress is installed"
  value       = "ingress-nginx"
}

output "app_namespaces" {
  description = "List of application namespaces created"
  value       = ["arch-analyzer-api", "arch-analyzer-ia"]
}
