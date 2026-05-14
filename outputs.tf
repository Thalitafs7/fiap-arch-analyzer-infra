# =============================================================================
# Network Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.network.private_subnet_ids
}

# =============================================================================
# EKS Cluster Outputs
# =============================================================================

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint URL of the EKS API server"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = module.eks.cluster_version
}

# =============================================================================
# ALB Outputs
# =============================================================================

output "alb_dns_name" {
  description = "DNS name of the ALB (application entry point)"
  value       = module.alb.alb_dns_name
}

# =============================================================================
# Database Outputs
# =============================================================================

output "db_instances" {
  description = "Map of service key -> { address, endpoint, port, db_name, instance_id, username }. Use this to inspect per-service RDS endpoints."
  value       = module.database.instances
  # Marked sensitive because the underlying object carries the master
  # username and instance attributes derived from var.databases (which is
  # sensitive). Address / port / db_name are still inspectable via
  # `terraform output -json db_instances`.
  sensitive = true
}

output "db_address" {
  description = "Backward-compat: address of the registration RDS instance. Prefer `db_instances` for new consumers."
  value       = module.database.instances["registration"].address
}

output "db_endpoint" {
  description = "Backward-compat: endpoint of the registration RDS instance."
  value       = module.database.instances["registration"].endpoint
}

# =============================================================================
# Storage Outputs
# =============================================================================

output "s3_diagrams_bucket" {
  description = "S3 bucket name for diagrams"
  value       = module.storage.diagrams_bucket_id
}

# =============================================================================
# ECR Outputs
# =============================================================================

output "ecr_repository_urls" {
  description = "Map of ECR repository names to their URLs"
  value       = module.ecr.repository_urls
}

output "ecr_registry_url" {
  description = "Base ECR registry URL for docker login (account.dkr.ecr.region.amazonaws.com)"
  value       = module.ecr.registry_url
}

# =============================================================================
# Messaging Outputs
# =============================================================================

output "sqs_processing_queue_url" {
  description = "URL of the SQS processing queue"
  value       = module.messaging.processing_queue_url
}

output "sqs_dlq_url" {
  description = "URL of the SQS dead letter queue"
  value       = module.messaging.dlq_url
}

# =============================================================================
# Access Information
# =============================================================================

output "kubeconfig_command" {
  description = "AWS CLI command to configure kubectl"
  value       = module.eks.kubeconfig_command
}


