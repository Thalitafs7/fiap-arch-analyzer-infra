output "processing_queue_url" {
  description = "URL of the processing SQS queue"
  value       = aws_sqs_queue.processing.url
}

output "processing_queue_arn" {
  description = "ARN of the processing SQS queue"
  value       = aws_sqs_queue.processing.arn
}

output "processing_queue_name" {
  description = "Name of the processing SQS queue"
  value       = aws_sqs_queue.processing.name
}

output "dlq_url" {
  description = "URL of the dead letter queue"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "ARN of the dead letter queue"
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Name of the dead letter queue"
  value       = aws_sqs_queue.dlq.name
}
