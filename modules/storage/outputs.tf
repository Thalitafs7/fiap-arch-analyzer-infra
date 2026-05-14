output "diagrams_bucket_id" {
  description = "ID (name) of the Diagrams_Bucket — consumed by k8s-config as S3_DIAGRAMS_BUCKET"
  value       = aws_s3_bucket.diagrams.id
}

output "diagrams_bucket_arn" {
  description = "ARN of the Diagrams_Bucket"
  value       = aws_s3_bucket.diagrams.arn
}

output "diagrams_bucket_domain" {
  description = "Regional domain name of the Diagrams_Bucket"
  value       = aws_s3_bucket.diagrams.bucket_regional_domain_name
}

output "access_logs_bucket_id" {
  description = "ID (name) of the Access_Logs_Bucket — passed to the alb module for access-log configuration"
  value       = aws_s3_bucket.access_logs.id
}

output "access_logs_bucket_arn" {
  description = "ARN of the Access_Logs_Bucket"
  value       = aws_s3_bucket.access_logs.arn
}
