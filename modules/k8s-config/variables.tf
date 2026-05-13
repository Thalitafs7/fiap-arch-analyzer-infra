# =============================================================================
# K8s Config Module - Variables
# =============================================================================

variable "project_name" {
  description = "Project name prefix used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region — written to infra-outputs ConfigMap as AWS_REGION"
  type        = string
}

# ---------------------------------------------------------------------------
# EKS cluster identity
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name — written to infra-outputs ConfigMap as CLUSTER_NAME"
  type        = string
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

variable "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — written to infra-outputs ConfigMap as ALB_DNS_NAME"
  type        = string
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

variable "db_address" {
  description = "RDS instance hostname — written to infra-outputs ConfigMap as DB_ADDRESS"
  type        = string
}

variable "db_port" {
  description = "RDS instance port (numeric) — cast to string and written as DB_PORT"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Initial database name — written to infra-outputs ConfigMap as DB_NAME"
  type        = string
}

# ---------------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------------

variable "sqs_processing_queue_url" {
  description = "URL of the Processing_Queue — written to infra-outputs ConfigMap as SQS_PROCESSING_QUEUE_URL"
  type        = string
}

variable "sqs_dlq_url" {
  description = "URL of the Processing_DLQ — written to infra-outputs ConfigMap as SQS_DLQ_URL"
  type        = string
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------

variable "s3_diagrams_bucket" {
  description = "Name of the Diagrams_Bucket — written to infra-outputs ConfigMap as S3_DIAGRAMS_BUCKET"
  type        = string
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_repository_urls" {
  description = <<-EOT
    Map of ECR repository names to their full URLs.
    Required keys: arch-analyzer-gateway, arch-analyzer-auth,
    arch-analyzer-registration, arch-analyzer-processing, arch-analyzer-report.
  EOT
  type        = map(string)
}

# ---------------------------------------------------------------------------
# Helm chart versions (optional overrides)
# ---------------------------------------------------------------------------

variable "ingress_nginx_chart_version" {
  description = "Helm chart version for ingress-nginx. Leave empty to use the latest."
  type        = string
  default     = ""
}
