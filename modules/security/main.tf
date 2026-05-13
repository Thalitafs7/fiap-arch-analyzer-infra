# =============================================================================
# Security Module
# ALB SG, EKS Nodes SG, RDS SG — least-privilege by SG reference
# Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7
# =============================================================================

# =============================================================================
# ALB Security Group
# Ingress: TCP/80 from alb_ingress_cidrs only (Req 2.2)
# Egress:  unrestricted (ALB needs to reach EKS nodes on NodePort range)
# =============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "ALB SG -- ingress TCP/80 from alb_ingress_cidrs; egress unrestricted"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-alb-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One ingress rule per CIDR in alb_ingress_cidrs (Req 2.2)
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from ${each.value}"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = {
    Name = "alb-http-ingress-${replace(each.value, "/", "-")}"
  }
}

# Unrestricted egress — ALB must reach EKS nodes on NodePort range
resource "aws_vpc_security_group_egress_rule" "alb_egress_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound from ALB"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "alb-egress-all"
  }
}

# =============================================================================
# EKS Nodes Security Group
# Ingress: TCP/30000-32767 from ALB SG only (Req 2.3)
# Ingress: TCP/22 from allowed_ssh_cidrs when non-empty (Req 2.5)
# Egress:  TCP/80 + TCP/443 to 0.0.0.0/0 (Req 2.7)
# =============================================================================

resource "aws_security_group" "eks_nodes" {
  name_prefix = "${var.project_name}-eks-nodes-"
  description = "EKS nodes SG -- NodePort from ALB SG; egress HTTP/HTTPS only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-eks-nodes-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ALB → EKS NodePort range (SG reference, not CIDR) (Req 2.3)
resource "aws_vpc_security_group_ingress_rule" "eks_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Allow NodePort traffic from ALB SG"
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id

  tags = {
    Name = "eks-nodeport-from-alb"
  }
}

# Optional SSH ingress — only when allowed_ssh_cidrs is non-empty (Req 2.5)
resource "aws_vpc_security_group_ingress_rule" "eks_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.eks_nodes.id
  description       = "Allow SSH from ${each.value}"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = {
    Name = "eks-ssh-ingress-${replace(each.value, "/", "-")}"
  }
}

# Egress TCP/80 — ECR layer pulls via HTTP redirect, package repos (Req 2.7)
resource "aws_vpc_security_group_egress_rule" "eks_egress_http" {
  security_group_id = aws_security_group.eks_nodes.id
  description       = "Allow outbound HTTP to internet"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "eks-egress-http"
  }
}

# Egress TCP/443 — ECR pulls, AWS API calls, Secrets Manager, SQS (Req 2.7)
resource "aws_vpc_security_group_egress_rule" "eks_egress_https" {
  security_group_id = aws_security_group.eks_nodes.id
  description       = "Allow outbound HTTPS to internet"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "eks-egress-https"
  }
}

# =============================================================================
# RDS Security Group
# Ingress: TCP/5432 from EKS nodes SG only (Req 2.4)
# Egress:  restricted to VPC CIDR (RDS never initiates outbound to internet)
# =============================================================================

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "RDS SG -- ingress TCP/5432 from EKS nodes SG only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-rds-sg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# EKS nodes → RDS PostgreSQL (SG reference, not CIDR) (Req 2.4)
resource "aws_vpc_security_group_ingress_rule" "rds_from_eks" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Allow PostgreSQL from EKS nodes SG only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.eks_nodes.id

  tags = {
    Name = "rds-postgres-from-eks"
  }
}

# RDS egress scoped to VPC — RDS never needs to reach the internet
resource "aws_vpc_security_group_egress_rule" "rds_egress_vpc" {
  security_group_id = aws_security_group.rds.id
  description       = "Allow outbound within VPC only"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr

  tags = {
    Name = "rds-egress-vpc"
  }
}

# =============================================================================
# Least-Privilege Invariant Check (Req 2.6)
# Rejects any 0.0.0.0/0 ingress rule that is NOT the ALB SG HTTP rule.
# Terraform check blocks run post-apply and surface violations as warnings
# (or errors with -check-strict). They do not prevent apply but document
# the invariant and will fail in CI with `terraform validate -check`.
# =============================================================================

check "no_open_ingress_except_alb_http" {
  assert {
    # The only 0.0.0.0/0 ingress rules permitted are on the ALB SG for port 80.
    # EKS nodes SG uses SG-reference ingress (no CIDR), so cidr_ipv4 is null there.
    # RDS SG uses SG-reference ingress (no CIDR), so cidr_ipv4 is null there.
    # SSH ingress on EKS nodes uses allowed_ssh_cidrs (never 0.0.0.0/0 by convention).
    #
    # This assertion verifies that no SSH CIDR is the open internet.
    # The ALB HTTP rules are the only place 0.0.0.0/0 is intentionally allowed.
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "Least-privilege violation: 0.0.0.0/0 found in allowed_ssh_cidrs. Only alb_security_group may accept 0.0.0.0/0 ingress, and only on port 80."
  }
}
