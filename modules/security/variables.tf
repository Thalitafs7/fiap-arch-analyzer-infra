variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where security groups are created"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC — used to scope RDS egress"
  type        = string
}

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the ALB on TCP/80. Use [\"0.0.0.0/0\"] for lab environments; restrict to known IPs in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs must contain at least one CIDR block."
  }
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into EKS nodes on TCP/22. Empty list disables SSH ingress entirely (recommended for production)."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "allowed_ssh_cidrs must not contain 0.0.0.0/0 — open SSH access violates least-privilege policy."
  }
}
