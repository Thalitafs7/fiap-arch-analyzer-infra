variable "project_name" {
  description = "Project name prefix for resource naming (e.g. arch-analyzer). DB identifier = <project_name>-db-<env>."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod). Controls skip_final_snapshot and deletion_protection behaviour."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC. Passed for reference / future use (e.g. additional SG rules)."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs of the two private subnets (us-east-1a + us-east-1b) for the DB subnet group. RDS must never be in public subnets. Req 6.1."
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "Security group ID produced by the security module. Allows TCP/5432 from EKS nodes SG only. Req 6.8."
  type        = string
}

variable "db_name" {
  description = "Name of the initial database created on the RDS instance (e.g. archanalyzer)."
  type        = string
}

variable "db_username" {
  description = "Master username for the RDS instance. Sensitive — never log or output."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Master password for the RDS instance. Sensitive — never log or output. Use Secrets Manager for rotation."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is Academy-whitelisted and cost-efficient (~$13/mo). Req 6.3."
  type        = string
  default     = "db.t3.micro"
}
