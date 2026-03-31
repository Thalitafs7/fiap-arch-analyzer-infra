# =============================================================================
# S3 Bucket - Access Logs
# =============================================================================

resource "aws_s3_bucket" "access_logs" {
  bucket_prefix = "${var.project_name}-access-logs-"
  force_destroy = var.force_destroy

  tags = {
    Name = "${var.project_name}-access-logs-${var.environment}"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

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

# =============================================================================
# S3 Bucket - Diagrams
# =============================================================================

resource "aws_s3_bucket" "diagrams" {
  bucket_prefix = "${var.project_name}-diagrams-"
  force_destroy = var.force_destroy

  tags = {
    Name = "${var.project_name}-diagrams-${var.environment}"
  }
}

resource "aws_s3_bucket_versioning" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "diagrams-logs/"
}

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
# S3 Bucket Policy - Diagrams (restritivo)
# =============================================================================

resource "aws_s3_bucket_policy" "diagrams" {
  bucket = aws_s3_bucket.diagrams.id

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
