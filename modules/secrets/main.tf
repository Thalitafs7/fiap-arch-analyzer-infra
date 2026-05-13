# =============================================================================
# Secrets Module — AWS Secrets Manager
# =============================================================================
# Creates one secret per logical path and populates each version from the
# sensitive input variables declared in variables.tf.
#
# Academy constraints:
#   - No KMS CMK creation → secrets use the AWS-managed key (aws/secretsmanager)
#   - LabRole node credentials are used by the init-container pattern at runtime
#   - recovery_window_in_days defaults to 0 so `terraform destroy` is clean
# =============================================================================

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Secret definitions: logical key → { path, secret_string }
  # Each entry maps to one aws_secretsmanager_secret + aws_secretsmanager_secret_version.
  secrets = {
    "db_registration" = {
      path          = "arch-analyzer/db/registration"
      secret_string = jsonencode({ password = var.db_password })
    }
    "db_processing" = {
      path          = "arch-analyzer/db/processing"
      secret_string = jsonencode({ password = var.db_password })
    }
    "db_report" = {
      path          = "arch-analyzer/db/report"
      secret_string = jsonencode({ password = var.db_password })
    }
    "auth_mongo" = {
      path          = "arch-analyzer/auth/mongo"
      secret_string = jsonencode({ password = var.mongo_password })
    }
    "auth_jwt" = {
      path          = "arch-analyzer/auth/jwt"
      secret_string = jsonencode({ signing_key = var.jwt_signing_key })
    }
    "redis_password" = {
      path          = "arch-analyzer/redis/password"
      secret_string = jsonencode({ password = var.redis_password })
    }
    "llm_keys" = {
      path          = "arch-analyzer/llm/keys"
      secret_string = jsonencode(var.llm_api_keys)
    }
  }
}

# ---------------------------------------------------------------------------
# Secret containers
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name                    = each.value.path
  description             = "Arch Analyzer secret: ${each.value.path}"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.tags, {
    Name = each.value.path
  })
}

# ---------------------------------------------------------------------------
# Secret versions (initial values)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.secrets

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value.secret_string
}
