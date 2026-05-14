# =============================================================================
# ECR Module - Variables
# =============================================================================

variable "project_name" {
  description = "Project name used as prefix for ECR repository names"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region where ECR repositories are created — used to build the registry URL"
  type        = string
}

variable "repository_names" {
  description = "List of repository names to create (will be prefixed with project_name)"
  type        = list(string)
}

variable "image_tag_mutability" {
  description = "Tag mutability setting for the repositories. MUTABLE or IMMUTABLE."
  type        = string
  default     = "MUTABLE"
}

variable "max_image_count" {
  description = "Maximum number of images to keep per repository (lifecycle policy)"
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "If true, will delete the repository even if it contains images"
  type        = bool
  default     = false
}
