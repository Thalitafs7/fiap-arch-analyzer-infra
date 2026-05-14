# =============================================================================
# mongodb-on-eks Module — Variables
# =============================================================================

variable "namespace" {
  description = "Kubernetes namespace where MongoDB will be deployed. Should be 'data'."
  type        = string
  default     = "data"
}

variable "storage_class" {
  description = "StorageClass name for the PersistentVolumeClaim. Use 'gp3' for EKS with EBS CSI driver."
  type        = string
  default     = "gp3"
}

variable "storage_size" {
  description = "Size of the PersistentVolumeClaim for MongoDB data. e.g. '10Gi'."
  type        = string
  default     = "10Gi"
}

variable "root_password_secret_name" {
  description = "AWS Secrets Manager secret ID (path) containing the MongoDB root password JSON. e.g. 'arch-analyzer/auth/mongo'."
  type        = string
  default     = "arch-analyzer/auth/mongo"
}

variable "aws_region" {
  description = "AWS region used by the init container to call Secrets Manager."
  type        = string
  default     = "us-east-1"
}

variable "mongodb_image" {
  description = "MongoDB container image. Pinned to MongoDB 7."
  type        = string
  default     = "mongo:7.0"
}

variable "aws_cli_image" {
  description = "AWS CLI image used by the secret-sync init container."
  type        = string
  default     = "amazon/aws-cli:2.15.0"
}
