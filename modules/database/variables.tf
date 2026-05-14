variable "project_name" {
  description = "Project name prefix for resource naming (e.g. arch-analyzer). DB identifier = <project_name>-db-<service>-<env>."
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

variable "databases" {
  description = <<-EOT
    Map of per-service Postgres databases. Each key produces an
    aws_db_instance with its own DB name, master username, master
    password, and optional instance class. Default class db.t3.micro
    (Academy-whitelisted, ~$13/mo). Req 6.2, 6.3, 6.4.

    The map key is the logical service identifier (registration, report,
    processing) and is used as part of the RDS identifier and the
    Service tag on the resulting instance.
  EOT
  type = map(object({
    db_name               = string
    username              = string
    password              = string
    instance_class        = optional(string, "db.t3.micro")
    allocated_storage     = optional(number, 20)
    max_allocated_storage = optional(number, 50)
  }))
  sensitive = true
  validation {
    condition     = length(var.databases) >= 1
    error_message = "At least one database must be declared."
  }
}
