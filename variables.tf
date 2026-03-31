# =============================================================================
# General
# =============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used as prefix for resource naming"
  type        = string
  default     = "arch-analyzer"
}

# =============================================================================
# Network
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

# =============================================================================
# AWS Academy
# =============================================================================

variable "lab_role_arn" {
  description = "ARN of the LabRole (AWS Academy) used for EKS cluster, node group and VPC Flow Logs"
  type        = string
}

# =============================================================================
# EKS Cluster
# =============================================================================

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.small"]
}

variable "eks_node_desired_size" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.eks_node_max_size <= 5
    error_message = "Max node count should be <= 5 for AWS Academy cost constraints."
  }
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair for EKS node access (optional)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into EKS nodes"
  type        = list(string)
  default     = []
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS API server endpoint. Restrict to your IP for security."
  type        = list(string)
}

# =============================================================================
# Database
# =============================================================================

variable "db_name" {
  description = "Name of the PostgreSQL database"
  type        = string
  default     = "archanalyzer"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_password" {
  description = "Master password for the RDS instance"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

# =============================================================================
# ECR (Container Registry)
# =============================================================================

variable "ecr_repository_names" {
  description = "List of ECR repository names to create (prefixed with project_name)"
  type        = list(string)
  default     = ["api", "ia"]
}

variable "ecr_force_delete" {
  description = "Allow ECR repositories to be destroyed even with images (dev only)"
  type        = bool
  default     = false
}

# =============================================================================
# Storage
# =============================================================================

variable "s3_force_destroy" {
  description = "Allow S3 bucket to be destroyed even with objects (dev only)"
  type        = bool
  default     = false
}

# =============================================================================
# ALB
# =============================================================================

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to access the ALB (HTTP)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
