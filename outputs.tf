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

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.database.db_endpoint
}

output "db_address" {
  description = "RDS PostgreSQL address (hostname)"
  value       = module.database.db_address
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


