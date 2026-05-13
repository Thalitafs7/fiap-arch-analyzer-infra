variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region — must be us-east-1 for Academy labs"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets — index 0 → us-east-1a, index 1 → us-east-1b"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets — index 0 → us-east-1a, index 1 → us-east-1b"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "lab_role_arn" {
  description = "ARN of the LabRole used as VPC Flow Logs delivery role (Academy constraint: no IAM role creation)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to tag private subnets with kubernetes.io/cluster/<name>=shared"
  type        = string
  default     = ""
}
