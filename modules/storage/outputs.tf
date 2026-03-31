output "diagrams_bucket_id" {
  description = "ID of the diagrams S3 bucket"
  value       = aws_s3_bucket.diagrams.id
}

output "diagrams_bucket_arn" {
  description = "ARN of the diagrams S3 bucket"
  value       = aws_s3_bucket.diagrams.arn
}

output "diagrams_bucket_domain" {
  description = "Regional domain name of the diagrams bucket"
  value       = aws_s3_bucket.diagrams.bucket_regional_domain_name
}

output "access_logs_bucket_id" {
  description = "ID of the access logs S3 bucket"
  value       = aws_s3_bucket.access_logs.id
}

output "access_logs_bucket_arn" {
  description = "ARN of the access logs S3 bucket"
  value       = aws_s3_bucket.access_logs.arn
}
