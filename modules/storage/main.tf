# =============================================================================
# Random suffixes — ensures globally unique bucket names
# =============================================================================

resource "random_id" "diagrams_suffix" {
  byte_length = 4
}

resource "random_id" "access_logs_suffix" {
  byte_length = 4
}

# =============================================================================
# Local: SSE algorithm selection
#
# Priority:
#   1. kms_key_arn supplied → aws:kms with CMK
#   2. use_aws_managed_kms = false → aws:kms with AWS-managed key (alias/aws/s3)
#   3. use_aws_managed_kms = true  → AES256 (SSE-S3) — Academy fallback
# =============================================================================

locals {
  use_cmk       = var.kms_key_arn != null
  use_kms       = local.use_cmk || !var.use_aws_managed_kms
  sse_algorithm = local.use_kms ? "aws:kms" : "AES256"

  # ALB log-delivery service principal varies by region; us-east-1 uses account 127311923021
  # For all other regions the principal is elasticloadbalancing.amazonaws.com
  # Reference: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
  alb_log_delivery_accounts = {
    "us-east-1"      = "127311923021"
    "us-east-2"      = "033677994240"
    "us-west-1"      = "027434742980"
    "us-west-2"      = "797873946194"
    "af-south-1"     = "098369216593"
    "ap-east-1"      = "754344448648"
    "ap-southeast-3" = "589379963580"
    "ap-south-1"     = "718504428378"
    "ap-northeast-3" = "383597477331"
    "ap-northeast-2" = "600734575887"
    "ap-southeast-1" = "114774131450"
    "ap-southeast-2" = "783225319266"
    "ap-northeast-1" = "582318560864"
    "ca-central-1"   = "985666609251"
    "eu-central-1"   = "054676820928"
    "eu-west-1"      = "156460612806"
    "eu-west-2"      = "652711504416"
    "eu-south-1"     = "635631232610"
    "eu-west-3"      = "009996457667"
    "eu-north-1"     = "897822967062"
    "me-south-1"     = "076674570225"
    "sa-east-1"      = "507241528517"
  }

  alb_delivery_account = lookup(local.alb_log_delivery_accounts, var.aws_region, null)
}

# =============================================================================
# S3 Bucket — Diagrams  (arch-analyzer-diagrams-<env>-<suffix>)
# Req 3.1, 3.3, 3.4, 3.5, 3.7
# =============================================================================

resource "aws_s3_bucket" "diagrams" {
  bucket        = "${var.project_name}-diagrams-${var.environment}-${random_id.diagrams_suffix.hex}"
  force_destroy = var.force_destroy

  tags = {
    Name        = "${var.project_name}-diagrams-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Block all public access — Req 3.1
resource "aws_s3_bucket_public_access_block" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE — aws:kms (CMK or AWS-managed) or AES256 fallback — Req 3.3
resource "aws_s3_bucket_server_side_encryption_configuration" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = local.use_cmk ? var.kms_key_arn : null
    }
    # bucket_key_enabled reduces KMS API calls and cost when using aws:kms
    bucket_key_enabled = local.use_kms
  }
}

# Versioning — Req 3.4
resource "aws_s3_bucket_versioning" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket policy: deny insecure transport — Req 3.5
resource "aws_s3_bucket_policy" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  # Ensure public-access block is applied before the policy to avoid conflicts
  depends_on = [aws_s3_bucket_public_access_block.diagrams]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.diagrams.arn,
          "${aws_s3_bucket.diagrams.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Server-access logging: diagrams → access_logs bucket
resource "aws_s3_bucket_logging" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access-logs/diagrams/"
}

# Lifecycle: transition old objects to STANDARD_IA, expire noncurrent versions
resource "aws_s3_bucket_lifecycle_configuration" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 60
    }
  }
}

# =============================================================================
# S3 Bucket — Access Logs  (randomised suffix)
# Req 3.2, 3.6, 3.7
# =============================================================================

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.project_name}-access-logs-${var.environment}-${random_id.access_logs_suffix.hex}"
  force_destroy = var.force_destroy

  tags = {
    Name        = "${var.project_name}-access-logs-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Block all public access — Req 3.2
resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE — same algorithm selection as diagrams bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = local.use_cmk ? var.kms_key_arn : null
    }
    bucket_key_enabled = local.use_kms
  }
}

# Lifecycle: expire old logs
resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ALB log-delivery bucket policy — Req 3.6
# Grants the regional ALB log-delivery account (or the ELB service principal for
# newer regions) permission to write access logs scoped to this bucket's ARN only.
resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  depends_on = [aws_s3_bucket_public_access_block.access_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # Classic regions: ALB uses a dedicated AWS-owned account to deliver logs
      local.alb_delivery_account != null ? [
        {
          Sid    = "ALBLogDeliveryClassic"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${local.alb_delivery_account}:root"
          }
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.access_logs.arn}/alb/*"
        }
      ] : [],
      # Newer regions: ALB uses the ELB service principal
      local.alb_delivery_account == null ? [
        {
          Sid    = "ALBLogDeliveryServicePrincipal"
          Effect = "Allow"
          Principal = {
            Service = "logdelivery.elasticloadbalancing.amazonaws.com"
          }
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.access_logs.arn}/alb/*"
          Condition = {
            StringEquals = {
              "s3:x-amz-acl"      = "bucket-owner-full-control"
              "aws:SourceAccount" = var.aws_account_id
            }
          }
        }
      ] : [],
      # Deny insecure transport for all other requests
      [
        {
          Sid       = "DenyInsecureTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource = [
            aws_s3_bucket.access_logs.arn,
            "${aws_s3_bucket.access_logs.arn}/*"
          ]
          Condition = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        }
      ]
    )
  })
}
