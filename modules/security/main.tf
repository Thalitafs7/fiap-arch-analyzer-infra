# =============================================================================
# Security Group - ALB
# =============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-alb-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from permitted CIDRs"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = var.alb_ingress_cidrs[0]

  tags = {
    Name = "alb-http-ingress"
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_eks_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow traffic to EKS nodes on NodePort range"
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = {
    Name = "alb-to-eks-nodes-egress"
  }
}

# =============================================================================
# Security Group - EKS Nodes (additional)
# =============================================================================
# EKS automatically creates a cluster security group for control plane ↔ node
# communication. This SG is for additional access rules (ALB, SSH, etc.)
# =============================================================================

resource "aws_security_group" "eks_nodes" {
  name_prefix = "${var.project_name}-eks-nodes-"
  description = "Additional security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-eks-nodes-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# SSH access (restrito)
resource "aws_vpc_security_group_ingress_rule" "eks_ssh" {
  count = length(var.allowed_ssh_cidrs) > 0 ? length(var.allowed_ssh_cidrs) : 0

  security_group_id = aws_security_group.eks_nodes.id
  description       = "Allow SSH from permitted CIDRs"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_ssh_cidrs[count.index]

  tags = {
    Name = "eks-ssh-ingress-${count.index}"
  }
}

# ALB → EKS NodePort
resource "aws_vpc_security_group_ingress_rule" "eks_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Allow traffic from ALB on NodePort range"
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id

  tags = {
    Name = "eks-from-alb-ingress"
  }
}

# Egress - allow all outbound (pull de imagens, comunicação com AWS APIs, etc.)
resource "aws_vpc_security_group_egress_rule" "eks_all_outbound" {
  security_group_id = aws_security_group.eks_nodes.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "eks-all-outbound"
  }
}

# =============================================================================
# Security Group - RDS
# =============================================================================

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-rds-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Only EKS nodes can access RDS
resource "aws_vpc_security_group_ingress_rule" "rds_from_eks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Allow PostgreSQL from EKS nodes only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = {
    Name = "rds-from-eks-ingress"
  }
}

resource "aws_vpc_security_group_egress_rule" "rds_egress" {
  security_group_id = aws_security_group.rds.id
  description       = "Allow outbound to VPC only"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr

  tags = {
    Name = "rds-vpc-egress"
  }
}
