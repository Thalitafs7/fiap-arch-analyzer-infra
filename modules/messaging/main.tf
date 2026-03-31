# =============================================================================
# SQS - Dead Letter Queue
# =============================================================================

resource "aws_sqs_queue" "dlq" {
  name                       = "${var.project_name}-dlq-${var.environment}"
  message_retention_seconds  = 1209600 # 14 days (máximo para DLQ)
  sqs_managed_sse_enabled    = true
  receive_wait_time_seconds  = 20 # Long polling

  tags = {
    Name = "${var.project_name}-dlq-${var.environment}"
  }
}

# =============================================================================
# SQS - Processing Queue
# =============================================================================

resource "aws_sqs_queue" "processing" {
  name                       = "${var.project_name}-processing-${var.environment}"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  sqs_managed_sse_enabled    = true
  receive_wait_time_seconds  = 20 # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name = "${var.project_name}-processing-${var.environment}"
  }
}

# =============================================================================
# SQS Queue Policy - Processing (restritivo)
# =============================================================================

resource "aws_sqs_queue_policy" "processing" {
  queue_url = aws_sqs_queue.processing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.processing.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# =============================================================================
# SQS Queue Policy - DLQ (restritivo)
# =============================================================================

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
