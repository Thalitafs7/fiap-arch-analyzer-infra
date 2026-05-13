variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of public subnets for EKS node group"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "IDs of private subnets for EKS control plane ENIs"
  type        = list(string)
}

variable "eks_nodes_security_group_id" {
  description = "Security group ID for EKS nodes (from security module)"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "node_disk_size" {
  description = "Disk size in GB for worker nodes"
  type        = number
  default     = 30
}

variable "lab_role_arn" {
  description = "ARN of the LabRole (AWS Academy) used for EKS cluster and node group"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the SSH key pair for node access (optional)"
  type        = string
  default     = ""
}

variable "endpoint_private_access" {
  description = "Whether the EKS API server endpoint is private"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server endpoint is public"
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Restrict to your workstation IP."
  type        = list(string)
}

variable "use_aws_managed_kms" {
  description = "When true, skip CMK creation and use the AWS-managed EKS KMS key (alias/aws/eks). Required when the Learner_Lab denies kms:CreateKey."
  type        = bool
  default     = false
}
