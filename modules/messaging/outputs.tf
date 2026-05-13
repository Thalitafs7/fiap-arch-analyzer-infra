# Req 5.6 — expose all four outputs consumed by k8s-config (infra-outputs ConfigMap)

output "processing_queue_url" {
  description = "URL of the Processing_Queue — mapped to SQS_PROCESSING_QUEUE_URL in infra-outputs ConfigMap"
  value       = aws_sqs_queue.processing.url
}

output "processing_queue_arn" {
  description = "ARN of the Processing_Queue — used by IAM policies granting EKS nodes send/receive access"
  value       = aws_sqs_queue.processing.arn
}

output "dlq_url" {
  description = "URL of the Processing_DLQ — mapped to SQS_DLQ_URL in infra-outputs ConfigMap"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "ARN of the Processing_DLQ — referenced by the observability module CloudWatch alarm"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Name of the Processing_DLQ — used as CloudWatch dimension in the observability module"
  value       = aws_sqs_queue.dlq.name
}
