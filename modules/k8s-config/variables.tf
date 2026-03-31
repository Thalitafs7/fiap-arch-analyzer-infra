# =============================================================================
# K8s Config Module - Variables
# =============================================================================

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# Infrastructure endpoints (from other modules)
variable "db_address" {
  description = "RDS database address"
  type        = string
}

variable "db_name" {
  description = "Database name"
  type        = string
}

variable "sqs_processing_queue_url" {
  description = "SQS processing queue URL"
  type        = string
}

variable "sqs_dlq_url" {
  description = "SQS dead letter queue URL"
  type        = string
}

variable "s3_diagrams_bucket" {
  description = "S3 diagrams bucket name"
  type        = string
}

# Helm chart versions (optional overrides)
variable "ingress_nginx_chart_version" {
  description = "Helm chart version for ingress-nginx"
  type        = string
  default     = ""
}

variable "argocd_chart_version" {
  description = "Helm chart version for argo-cd"
  type        = string
  default     = ""
}
