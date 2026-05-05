# =============================================================================
# Data Sources
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
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
# VPC Flow Logs (auditoria)
# =============================================================================

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

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flow-logs/${var.project_name}-${var.environment}"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-vpc-flow-logs-${var.environment}"
  }
}

# =============================================================================
# Internet Gateway
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw-${var.environment}"
  }
}

# =============================================================================
# Public Subnets
# =============================================================================

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    {
      Name                     = "${var.project_name}-public-${count.index + 1}-${var.environment}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
    var.cluster_name != "" ? {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    } : {}
  )
}

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
# Private Subnets
# =============================================================================

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
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
# VPC Endpoint - S3 Gateway (gratuito)
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.public.id,
    aws_route_table.private.id,
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowProjectS3Access"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*"
        ]
      },
      {
        Sid       = "AllowECRAndEKS"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-s3-endpoint-${var.environment}"
  }
}
