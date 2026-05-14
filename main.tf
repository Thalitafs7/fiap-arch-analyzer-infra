# =============================================================================
# Arch Analyzer Infrastructure - Main Configuration
# =============================================================================
# Monorepo de infraestrutura para o projeto Arch Analyzer
# Compatível com AWS Academy (LabRole, EKS, sem NAT GW)
# =============================================================================

locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

# Resolve current AWS account ID — used by storage module for ALB log-delivery policy
data "aws_caller_identity" "current" {}

# =============================================================================
# Network Module
# =============================================================================

module "network" {
  source = "./modules/network"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  lab_role_arn         = var.lab_role_arn
  cluster_name         = local.cluster_name
}

# =============================================================================
# Security Module
# =============================================================================

module "security" {
  source = "./modules/security"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  alb_ingress_cidrs = var.alb_ingress_cidrs
}

# =============================================================================
# Storage Module (S3)
# =============================================================================

module "storage" {
  source = "./modules/storage"

  project_name        = var.project_name
  environment         = var.environment
  force_destroy       = var.s3_force_destroy
  kms_key_arn         = var.kms_key_arn
  use_aws_managed_kms = var.use_aws_managed_kms
  aws_account_id      = data.aws_caller_identity.current.account_id
  aws_region          = var.aws_region
}

# =============================================================================
# ECR Module (Container Registry)
# =============================================================================

module "ecr" {
  source = "./modules/ecr"

  project_name     = var.project_name
  environment      = var.environment
  aws_region       = var.aws_region
  repository_names = var.ecr_repository_names
  force_delete     = var.ecr_force_delete
}

# =============================================================================
# Messaging Module (SQS)
# =============================================================================

module "messaging" {
  source = "./modules/messaging"

  project_name = var.project_name
  environment  = var.environment
}

# =============================================================================
# Database Module (RDS PostgreSQL — per-service instances)
# =============================================================================
# Per-service master passwords are auto-generated. Keeping them out of
# var.databases means they never need to live in terraform.tfvars and the
# plan output never echoes them in plaintext beyond the standard
# random_password sensitive treatment.
#
# override_special restricts the special-char alphabet to characters
# that are accepted both by RDS master-password validation and by .NET
# Npgsql / Python psycopg URI parsing. Excluded (by virtue of NOT being
# in the list): / @ ' " ; — these either break the AWS RDS API or
# upset connection-string parsers.

resource "random_password" "db_master" {
  for_each = var.databases

  length           = 24
  special          = true
  override_special = "!#$%*-_+=" # exclude / @ ' " ; (RDS-friendly)
}

module "database" {
  source = "./modules/database"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  rds_security_group_id = module.security.rds_security_group_id

  databases = {
    for k, v in var.databases : k => merge(v, {
      password = random_password.db_master[k].result
    })
  }
}

# =============================================================================
# EKS Cluster Module
# =============================================================================

module "eks" {
  source = "./modules/eks"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  cluster_version             = var.eks_cluster_version
  vpc_id                      = module.network.vpc_id
  public_subnet_ids           = module.network.public_subnet_ids
  private_subnet_ids          = module.network.private_subnet_ids
  eks_nodes_security_group_id = module.security.eks_nodes_security_group_id
  node_instance_types         = var.eks_node_instance_types
  node_desired_size           = var.eks_node_desired_size
  node_min_size               = var.eks_node_min_size
  node_max_size               = var.eks_node_max_size
  lab_role_arn                = var.lab_role_arn
  ssh_key_name                = var.ssh_key_name
  eks_public_access_cidrs     = var.eks_public_access_cidrs
  use_aws_managed_kms         = var.use_aws_managed_kms
}

# =============================================================================
# ALB → EKS Nodes (NodePort ingress on cluster SG)
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "alb_to_eks_cluster_sg" {
  security_group_id            = module.eks.cluster_security_group_id
  description                  = "Allow ALB traffic on NodePort range to EKS nodes"
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.security.alb_security_group_id

  tags = {
    Name = "alb-to-eks-nodeport"
  }
}

# =============================================================================
# ALB Module
# =============================================================================

module "alb" {
  source = "./modules/alb"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security.alb_security_group_id
  node_group_asg_names  = module.eks.node_group_asg_names
  access_logs_bucket_id = module.storage.access_logs_bucket_id
}

# =============================================================================
# Kubernetes Configuration Module
# =============================================================================
# Namespaces, NetworkPolicies, ConfigMaps, NGINX Ingress
# Tudo gerenciado via Terraform - sem scripts externos
# =============================================================================

module "k8s_config" {
  source = "./modules/k8s-config"

  project_name             = var.project_name
  environment              = var.environment
  aws_region               = var.aws_region
  cluster_name             = module.eks.cluster_name
  alb_dns_name             = module.alb.alb_dns_name
  db_address               = module.database.instances["registration"].address
  db_port                  = module.database.instances["registration"].port
  db_name                  = module.database.instances["registration"].db_name
  sqs_processing_queue_url = module.messaging.processing_queue_url
  sqs_dlq_url              = module.messaging.dlq_url
  s3_diagrams_bucket       = module.storage.diagrams_bucket_id
  ecr_repository_urls      = module.ecr.repository_urls

  depends_on = [module.eks, module.alb]
}

# =============================================================================
# Secrets Module (AWS Secrets Manager)
# Must run before mongodb and redis (they reference secret paths)
# =============================================================================

module "secrets" {
  source = "./modules/secrets"

  project_name = var.project_name
  environment  = var.environment

  db_connection_strings = module.database.connection_strings

  jwt_signing_key = var.jwt_signing_key
  mongo_password  = var.mongo_password
  redis_password  = var.redis_password
  llm_api_keys    = var.llm_api_keys
}

# =============================================================================
# Observability Module (CloudWatch Logs, Alarms, Dashboard, Fluent Bit, CW Insights)
# Depends on EKS (cluster must exist before Helm releases)
# =============================================================================

module "observability" {
  source = "./modules/observability"

  project_name           = var.project_name
  environment            = var.environment
  aws_region             = var.aws_region
  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority
  alb_arn_suffix         = split("loadbalancer/", module.alb.alb_arn)[1]
  dlq_name               = module.messaging.dlq_name

  depends_on = [module.eks]
}

# =============================================================================
# MongoDB on EKS
# Depends on secrets (secret path must exist) and k8s_config (namespace + NetworkPolicies)
# =============================================================================

module "mongodb" {
  source = "./modules/mongodb-on-eks"

  namespace                 = "data"
  storage_class             = "gp2"
  storage_size              = "10Gi"
  root_password_secret_name = "arch-analyzer/auth/mongo"
  aws_region                = var.aws_region

  depends_on = [module.secrets, module.k8s_config]
}

# =============================================================================
# Redis on EKS
# Depends on secrets (secret path must exist) and k8s_config (namespace + NetworkPolicies)
# =============================================================================

module "redis" {
  source = "./modules/redis-on-eks"

  namespace            = "data"
  storage_class        = "gp2"
  storage_size         = "2Gi"
  password_secret_name = "arch-analyzer/redis/password"
  aws_region           = var.aws_region

  depends_on = [module.secrets, module.k8s_config]
}
