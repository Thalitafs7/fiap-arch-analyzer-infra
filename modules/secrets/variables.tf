# =============================================================================
# Secrets Module — Variables
# =============================================================================

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
}

# ---------------------------------------------------------------------------
# Sensitive credentials — never logged, never shown in plan output
# ---------------------------------------------------------------------------

variable "db_connection_strings" {
  description = <<-EOT
    Map of service key -> full Postgres connection string. Comes from
    modules/database outputs. Each value is written verbatim into the
    corresponding arch-analyzer/db/<service> Secrets Manager entry as
    the SecretString (NOT JSON-wrapped). Service init containers can
    therefore consume it directly with a `tr -d '\n'` and feed it to
    EF Core / SQLAlchemy without JSON parsing.
  EOT
  type        = map(string)
  sensitive   = true
}

variable "jwt_signing_key" {
  description = "HMAC signing key for JWT token generation and validation."
  type        = string
  sensitive   = true
}

variable "mongo_password" {
  description = "Root password for the MongoDB StatefulSet."
  type        = string
  sensitive   = true
}

variable "redis_password" {
  description = "AUTH password for the Redis StatefulSet."
  type        = string
  sensitive   = true
}

variable "llm_api_keys" {
  description = "Map of LLM provider API keys. Expected keys: OPENAI_API_KEY, ANTHROPIC_API_KEY, and optionally HF_API_TOKEN."
  type        = map(string)
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Optional — recovery window
# ---------------------------------------------------------------------------

variable "recovery_window_in_days" {
  description = "Number of days Secrets Manager waits before permanently deleting a secret. Set to 0 to disable the recovery window (useful for lab teardown)."
  type        = number
  default     = 0
}
