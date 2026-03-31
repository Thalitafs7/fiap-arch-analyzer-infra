variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of public subnets for ALB"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "node_group_asg_names" {
  description = "Auto Scaling Group names from EKS managed node group"
  type        = list(string)
}

variable "access_logs_bucket_id" {
  description = "S3 bucket ID for ALB access logs"
  type        = string
}
