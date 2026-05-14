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

  # ---------------------------------------------------------------------------
  # Static secret definitions — non-DB material wrapped as JSON.
  # Each entry maps to one aws_secretsmanager_secret + aws_secretsmanager_secret_version.
  # ---------------------------------------------------------------------------
  static_secrets = {
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

  # ---------------------------------------------------------------------------
  # Per-service DB connection strings — stored as RAW STRINGS (NOT JSON).
  #
  # CONTRACT CHANGE (vs. previous shape):
  #   Old: arch-analyzer/db/<svc> stored as {"password":"..."} JSON.
  #   New: arch-analyzer/db/<svc> stores the FULL connection string as a
  #        plain (non-JSON) SecretString.
  #
  # Why: the previous shape forced every init container to parse JSON to
  # extract a password, then re-assemble a connection string with the rest
  # of the params from a ConfigMap. That re-assembly is the source of the
  # Npgsql parse error reported by the registration service — a stray
  # newline from `tr -d '\n'` over `kubectl get secret -o jsonpath=`{.data.password}``
  # produced an unparseable Host=...;...;Password=<json-noise> string.
  #
  # New shape: the secret IS the connection string. The init container
  # writes it verbatim to disk, and EF Core / SQLAlchemy can parse it
  # without any string juggling.
  #
  # Future maintainers: do NOT wrap these values in jsonencode(). The
  # registration / report / processing init containers depend on the raw
  # form.
  # ---------------------------------------------------------------------------
  db_secrets = {
    for svc, conn in var.db_connection_strings :
    "db_${svc}" => {
      path          = "arch-analyzer/db/${svc}"
      secret_string = conn
    }
  }

  secrets = merge(local.static_secrets, local.db_secrets)
}

# ---------------------------------------------------------------------------
# Secret containers
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "this" {
  # Keys are static logical names (auth_mongo, db_registration, ...) and
  # are not sensitive. nonsensitive() unwraps the for_each argument so
  # the values flowing through local.secrets (which IS sensitive) do not
  # poison the resource keys. Path / description / Name tag are also
  # structurally non-secret (they encode the logical secret address) and
  # are unwrapped via nonsensitive() so plan output stays diff-stable.
  for_each = nonsensitive(toset(keys(local.secrets)))

  name                    = nonsensitive(local.secrets[each.key].path)
  description             = nonsensitive("Arch Analyzer secret: ${local.secrets[each.key].path}")
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(local.tags, {
    Name = nonsensitive(local.secrets[each.key].path)
  })
}

# ---------------------------------------------------------------------------
# Secret versions (initial values)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret_version" "this" {
  for_each = nonsensitive(toset(keys(local.secrets)))

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = local.secrets[each.key].secret_string
}
