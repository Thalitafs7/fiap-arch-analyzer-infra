# =============================================================================
# Redis on EKS Module — Variables
# Requirements: 12.1, 12.2, 12.3, 12.4, 12.5
# =============================================================================

variable "namespace" {
  description = "Kubernetes namespace where Redis will be deployed. Should be 'data'."
  type        = string
  default     = "data"
}

variable "storage_class" {
  description = "StorageClass name for the Redis PersistentVolumeClaim. Use 'gp3' for EKS with EBS CSI driver."
  type        = string
  default     = "gp3"
}

variable "storage_size" {
  description = "Size of the PersistentVolumeClaim for Redis data. e.g. '2Gi'."
  type        = string
  default     = "2Gi"
}

variable "password_secret_name" {
  description = "AWS Secrets Manager secret path for the Redis AUTH password. e.g. 'arch-analyzer/redis/password'."
  type        = string
  default     = "arch-analyzer/redis/password"
}

variable "aws_region" {
  description = "AWS region used by the init container to call Secrets Manager via IMDS."
  type        = string
  default     = "us-east-1"
}

variable "redis_image" {
  description = "Redis container image. Pinned to a stable version."
  type        = string
  default     = "redis:7.2-alpine"
}

variable "aws_cli_image" {
  description = "AWS CLI image used by the secret-sync init container."
  type        = string
  default     = "amazon/aws-cli:2.15.0"
}
