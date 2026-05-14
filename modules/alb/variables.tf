variable "project_name" {
  description = "Project name used for resource naming (e.g. arch-analyzer)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC — required by the target group"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of both public subnets; ALB requires at least two AZs (Req 8.1)"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "ALB requires at least two public subnets across different AZs."
  }
}

variable "alb_security_group_id" {
  description = "Security group ID to attach to the ALB (produced by the security module)"
  type        = string
}

variable "node_group_asg_names" {
  description = "Auto Scaling Group names from the EKS managed node group (produced by the eks module). All ASGs are attached to the target group."
  type        = list(string)
}

variable "expected_asg_count" {
  description = "Number of ASGs to attach to the target group. Must be known at plan time (avoids for_each unknown-value issue)."
  type        = number
  default     = 1
}

variable "access_logs_bucket_id" {
  description = "S3 bucket ID (name) of the Access_Logs_Bucket for ALB access log delivery (Req 8.6)"
  type        = string
}
