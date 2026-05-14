# =============================================================================
# Network Module
# VPC, subnets, IGW, route tables, S3 Gateway Endpoint, VPC Flow Logs
# No NAT Gateway (AWS Academy budget constraint)
# =============================================================================

locals {
  # Pin to us-east-1a / us-east-1b as required by the spec
  azs = ["${var.aws_region}a", "${var.aws_region}b"]
}

# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc-${var.environment}"
  }
}

# =============================================================================
# VPC Flow Logs → CloudWatch (LabRole as delivery role)
# Req 1.6 / 18.6
# =============================================================================

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flow-logs/${var.project_name}-${var.environment}"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-vpc-flow-logs-${var.environment}"
  }
}

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn         = var.lab_role_arn

  tags = {
    Name = "${var.project_name}-vpc-flow-logs-${var.environment}"
  }
}

# =============================================================================
# Internet Gateway
# Req 1.3
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw-${var.environment}"
  }
}

# =============================================================================
# Public Subnets — us-east-1a (10.0.1.0/24) and us-east-1b (10.0.2.0/24)
# Tagged: kubernetes.io/role/elb=1 (for ALB controller)
# Req 1.2, 1.7
# =============================================================================

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-public-${count.index + 1}-${var.environment}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

# =============================================================================
# Public Route Table — 0.0.0.0/0 → IGW
# Req 1.3
# =============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt-${var.environment}"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# Private Subnets — us-east-1a (10.0.3.0/24) and us-east-1b (10.0.4.0/24)
# Tagged: kubernetes.io/role/internal-elb=1 + kubernetes.io/cluster/<name>=shared
# Req 1.2, 1.7
# =============================================================================

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    {
      Name                              = "${var.project_name}-private-${count.index + 1}-${var.environment}"
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.cluster_name != "" ? {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    } : {}
  )
}

# =============================================================================
# Private Route Table (no NAT — Academy budget constraint)
# Req 1.5
# =============================================================================

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidrs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# S3 Gateway VPC Endpoint — free, keeps S3 traffic off public internet
# Associated with both public and private route tables
# Req 1.4
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  # Allow all S3 access through the endpoint (ECR layers, diagrams bucket, ALB logs)
  # Bucket-level policies enforce fine-grained access control
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAll"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-s3-endpoint-${var.environment}"
  }
}
