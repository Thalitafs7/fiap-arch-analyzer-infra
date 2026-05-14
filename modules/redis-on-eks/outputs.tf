# =============================================================================
# Redis on EKS Module — Outputs
# Requirements: 12.5
# =============================================================================

output "service_host" {
  description = "In-cluster DNS hostname for the Redis ClusterIP Service."
  value       = "redis.${var.namespace}.svc.cluster.local"
}

output "service_port" {
  description = "Port on which the Redis Service listens."
  value       = 6379
}
