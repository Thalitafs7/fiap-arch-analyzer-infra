# =============================================================================
# Secrets Module — Outputs
# =============================================================================

output "secret_arns" {
  description = "Map of secret ARNs keyed by logical path (e.g. 'arch-analyzer/db/registration')."
  value = {
    for k, v in aws_secretsmanager_secret.this : v.name => v.arn
  }
  sensitive = false # ARNs are not sensitive; values are never exposed here
}
