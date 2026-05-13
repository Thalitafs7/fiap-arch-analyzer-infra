# =============================================================================
# RDS Subnet Group
# Spans both private subnets (us-east-1a + us-east-1b) — Req 6.1
# RDS stays in private subnets; no public route, no NAT needed for DB traffic.
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-${var.environment}"
  description = "Database subnet group for ${var.project_name} -- private subnets only"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name        = "${var.project_name}-db-subnet-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# RDS PostgreSQL Instance
# Engine: postgres 15 (major version pin) — Req 6.2
# Instance: db.t3.micro — Academy-whitelisted, cost-efficient — Req 6.3
# Storage: 20 GB gp3 — Req 6.4; autoscale cap 50 GB
# Single-AZ — Multi-AZ skipped for Academy budget (~$50-100/mo cap) — Req 6.5
# Security: not publicly accessible, encrypted at rest, IAM auth — Req 6.6, 6.7, 6.8
# Backup: 7-day retention — Req 6.9
# skip_final_snapshot=true for non-prod (Academy teardown workflow) — Req 17.5
# monitoring_interval=0 — Enhanced Monitoring requires custom IAM role (Academy blocks) — Req 18.4
# =============================================================================

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db-${var.environment}"

  engine         = "postgres"
  engine_version = "15"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Storage — Req 6.4
  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true # Req 6.7

  # Network — Req 6.6
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_security_group_id] # from security module — Req 6.8
  publicly_accessible    = false
  port                   = 5432

  # Single-AZ — Req 6.5
  multi_az = false

  # Security — Req 6.7, 6.8
  iam_database_authentication_enabled = true
  deletion_protection                 = var.environment == "prod" ? true : false

  # Backup — Req 6.9
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Monitoring — Req 18.4
  # Enhanced Monitoring (interval > 0) requires iam:CreateRole which Academy blocks.
  # Set to 0 to disable; CloudWatch basic metrics still available.
  monitoring_interval = 0

  # Parameters
  parameter_group_name = aws_db_parameter_group.main.name

  # Lifecycle — Req 17.5
  # Non-prod: skip final snapshot for fast teardown (Academy session expiry).
  # Prod: create final snapshot before destroy.
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-final-snapshot" : null
  copy_tags_to_snapshot     = true

  # Performance Insights disabled — Academy may not support; avoids extra cost
  performance_insights_enabled = false

  tags = {
    Name        = "${var.project_name}-db-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# RDS Parameter Group — postgres15
# Enables connection/query logging for auditability.
# create_before_destroy prevents downtime on parameter group updates.
# =============================================================================

resource "aws_db_parameter_group" "main" {
  name_prefix = "${var.project_name}-pg15-"
  family      = "postgres15"
  description = "Custom parameter group for ${var.project_name} postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # Log queries > 1 s
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-pg15-params-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
