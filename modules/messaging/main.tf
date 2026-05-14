# =============================================================================
# SQS — Dead Letter Queue
# Name: arch-analyzer-processing-dlq-<env>
# Req 5.1, 5.4
# =============================================================================

resource "aws_sqs_queue" "dlq" {
  name = "${var.project_name}-processing-dlq-${var.environment}"

  # 14-day retention maximises recovery window for failed messages
  message_retention_seconds = 1209600

  # SSE-SQS (AWS-managed key) — no CMK required; Academy-compatible — Req 5.4
  sqs_managed_sse_enabled = true

  # Long polling reduces empty-receive API calls and cost
  receive_wait_time_seconds = 20

  tags = {
    Name        = "${var.project_name}-processing-dlq-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# SQS — Processing Queue (Standard)
# Name: arch-analyzer-processing-<env>
# Req 5.1, 5.2, 5.3, 5.4
# =============================================================================

resource "aws_sqs_queue" "processing" {
  name = "${var.project_name}-processing-${var.environment}"

  # 600 s visibility timeout covers LLM processing latency — Req 5.2
  visibility_timeout_seconds = var.visibility_timeout_seconds

  message_retention_seconds = var.message_retention_seconds

  # SSE-SQS (AWS-managed key) — Req 5.4
  sqs_managed_sse_enabled = true

  # Long polling
  receive_wait_time_seconds = 20

  # Redrive to DLQ after maxReceiveCount=3 failures — Req 5.3
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name        = "${var.project_name}-processing-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# SQS Queue Policy — Processing Queue
# Denies any request over plain HTTP (aws:SecureTransport=false) — Req 5.5
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
