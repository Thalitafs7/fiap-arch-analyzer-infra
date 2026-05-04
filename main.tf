# =============================================================================
# Arch Analyzer Infrastructure - Main Configuration
# =============================================================================
# Monorepo de infraestrutura para o projeto Arch Analyzer
# Compatível com AWS Academy (LabRole, EKS, sem NAT GW)
# =============================================================================

locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

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

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  allowed_ssh_cidrs  = var.allowed_ssh_cidrs
  alb_ingress_cidrs  = var.alb_ingress_cidrs
}

# =============================================================================
# Storage Module (S3)
# =============================================================================

module "storage" {
  source = "./modules/storage"

  project_name  = var.project_name
  environment   = var.environment
  force_destroy = var.s3_force_destroy
}

# =============================================================================
# ECR Module (Container Registry)
# =============================================================================

module "ecr" {
  source = "./modules/ecr"

  project_name     = var.project_name
  environment      = var.environment
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
# Database Module (RDS PostgreSQL)
# =============================================================================

module "database" {
  source = "./modules/database"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  rds_security_group_id = module.security.rds_security_group_id
  db_name               = var.db_name
  db_username           = var.db_username
  db_password           = var.db_password
  db_instance_class     = var.db_instance_class
}

# =============================================================================
# EKS Cluster Module
# =============================================================================

module "eks" {
  source = "./modules/eks"

  project_name               = var.project_name
  environment                = var.environment
  aws_region                 = var.aws_region
  cluster_version            = var.eks_cluster_version
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  private_subnet_ids         = module.network.private_subnet_ids
  eks_node_security_group_id = module.security.eks_nodes_security_group_id
  node_instance_types        = var.eks_node_instance_types
  node_desired_size          = var.eks_node_desired_size
  node_min_size              = var.eks_node_min_size
  node_max_size              = var.eks_node_max_size
  lab_role_arn               = var.lab_role_arn
  ssh_key_name               = var.ssh_key_name
  public_access_cidrs        = var.eks_public_access_cidrs
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
  db_address               = module.database.db_address
  db_name                  = var.db_name
  sqs_processing_queue_url = module.messaging.processing_queue_url
  sqs_dlq_url              = module.messaging.dlq_url
  s3_diagrams_bucket       = module.storage.diagrams_bucket_id

  depends_on = [module.eks]
}
