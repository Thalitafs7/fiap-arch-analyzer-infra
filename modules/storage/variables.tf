variable "project_name" {
  description = "Project name for resource naming (e.g. arch-analyzer)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}

variable "force_destroy" {
  description = "Allow non-empty buckets to be destroyed by terraform destroy"
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "ARN of a customer-managed KMS key for SSE-KMS. When null and use_aws_managed_kms=true, AES256 is used instead."
  type        = string
  default     = null
}

variable "use_aws_managed_kms" {
  description = "When true and kms_key_arn is null, fall back to AES256 (SSE-S3) instead of aws:kms. Set to true in AWS Academy environments where CMK creation is denied."
  type        = bool
  default     = true
}

variable "aws_account_id" {
  description = "AWS account ID used to scope the ALB log-delivery bucket policy"
  type        = string
}

variable "aws_region" {
  description = "AWS region (e.g. us-east-1) used to scope the ALB log-delivery bucket policy"
  type        = string
  default     = "us-east-1"
}
