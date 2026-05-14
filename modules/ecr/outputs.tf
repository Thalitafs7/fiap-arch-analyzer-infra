# =============================================================================
# ECR Module - Outputs
# =============================================================================

output "repository_urls" {
  description = "Map of repository names to their URLs"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of repository names to their ARNs"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}

output "registry_url" {
  description = "Base ECR registry URL (account.dkr.ecr.region.amazonaws.com) — use for docker login"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}
