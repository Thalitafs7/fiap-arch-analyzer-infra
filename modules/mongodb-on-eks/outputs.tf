# =============================================================================
# mongodb-on-eks Module — Outputs
# =============================================================================

output "service_host" {
  description = "Kubernetes DNS name for the MongoDB ClusterIP Service. Format: <service>.<namespace>.svc.cluster.local"
  value       = "mongodb.${var.namespace}.svc.cluster.local"
}

output "service_port" {
  description = "Port on which the MongoDB ClusterIP Service listens."
  value       = 27017
}
