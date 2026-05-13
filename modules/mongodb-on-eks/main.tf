# =============================================================================
# mongodb-on-eks Module — MongoDB 7 StatefulSet + ClusterIP Service
# =============================================================================
# Deploys a single-replica MongoDB 7 StatefulSet into the `data` namespace.
#
# Secret strategy (Academy constraint — no IRSA):
#   An init container (amazon/aws-cli:2.15.0) fetches the root password from
#   AWS Secrets Manager using the node-level LabRole credentials available via
#   IMDS. The JSON payload is written to an emptyDir{medium: Memory} volume
#   shared with the main container, which reads MONGO_INITDB_ROOT_PASSWORD
#   from a file via the MONGO_INITDB_ROOT_PASSWORD_FILE env var.
#
# Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 10.3, 10.4
# =============================================================================

# ---------------------------------------------------------------------------
# StatefulSet — single-replica MongoDB 7
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "mongodb_statefulset" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"

    metadata = {
      name      = "mongodb"
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/name"       = "mongodb"
        "app.kubernetes.io/part-of"    = "arch-analyzer"
        "app.kubernetes.io/component"  = "database"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = {
      serviceName = "mongodb"
      replicas    = 1

      selector = {
        matchLabels = {
          app = "mongodb"
        }
      }

      template = {
        metadata = {
          labels = {
            app                           = "mongodb"
            "app.kubernetes.io/name"      = "mongodb"
            "app.kubernetes.io/part-of"   = "arch-analyzer"
            "app.kubernetes.io/component" = "database"
          }
        }

        spec = {
          # Requirement 10.4 — no service account token auto-mount
          automountServiceAccountToken = false

          securityContext = {
            runAsNonRoot = false # MongoDB 7 official image runs as root by default; fsGroup set for volume ownership
            fsGroup      = 999   # mongodb group inside the official image
          }

          # ----------------------------------------------------------------
          # Init container — secret-sync (Requirement 10.3, 11.3)
          # Fetches arch-analyzer/auth/mongo from Secrets Manager via IMDS
          # and writes the password to /secrets/mongo-password (plain text)
          # ----------------------------------------------------------------
          initContainers = [
            {
              name  = "secrets-sync"
              image = var.aws_cli_image

              command = ["/bin/sh", "-c"]
              args = [
                <<-EOT
                  set -e
                  echo "Fetching MongoDB root password from Secrets Manager..."
                  SECRET_JSON=$(aws secretsmanager get-secret-value \
                    --secret-id "${var.root_password_secret_name}" \
                    --region "${var.aws_region}" \
                    --query SecretString \
                    --output text)
                  # Extract the 'password' field from the JSON payload
                  echo "$SECRET_JSON" | grep -o '"password":"[^"]*"' | cut -d'"' -f4 > /secrets/mongo-password
                  echo "Secret written to /secrets/mongo-password"
                EOT
              ]

              volumeMounts = [
                {
                  name      = "secrets"
                  mountPath = "/secrets"
                }
              ]

              resources = {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
              }
            }
          ]

          # ----------------------------------------------------------------
          # Main container — MongoDB 7
          # ----------------------------------------------------------------
          containers = [
            {
              name  = "mongodb"
              image = var.mongodb_image

              ports = [
                {
                  containerPort = 27017
                  name          = "mongodb"
                  protocol      = "TCP"
                }
              ]

              env = [
                {
                  name  = "MONGO_INITDB_ROOT_USERNAME"
                  value = "root"
                },
                # Password is read from the file written by the init container
                {
                  name  = "MONGO_INITDB_ROOT_PASSWORD_FILE"
                  value = "/secrets/mongo-password"
                }
              ]

              resources = {
                requests = {
                  cpu    = "200m"
                  memory = "256Mi"
                }
                limits = {
                  cpu    = "500m"
                  memory = "512Mi"
                }
              }

              livenessProbe = {
                exec = {
                  command = ["mongosh", "--eval", "db.adminCommand('ping')"]
                }
                initialDelaySeconds = 30
                periodSeconds       = 10
                timeoutSeconds      = 5
                failureThreshold    = 3
              }

              readinessProbe = {
                exec = {
                  command = ["mongosh", "--eval", "db.adminCommand('ping')"]
                }
                initialDelaySeconds = 5
                periodSeconds       = 5
                timeoutSeconds      = 3
                failureThreshold    = 3
              }

              securityContext = {
                allowPrivilegeEscalation = false
                capabilities = {
                  drop = ["NET_RAW"]
                }
              }

              volumeMounts = [
                {
                  name      = "mongodb-data"
                  mountPath = "/data/db"
                },
                {
                  name      = "secrets"
                  mountPath = "/secrets"
                  readOnly  = true
                }
              ]
            }
          ]

          # ----------------------------------------------------------------
          # Volumes
          # ----------------------------------------------------------------
          volumes = [
            {
              # emptyDir with Memory medium — secret never touches disk (Req 10.3)
              name = "secrets"
              emptyDir = {
                medium = "Memory"
              }
            }
          ]
        }
      }

      # ----------------------------------------------------------------
      # VolumeClaimTemplates — gp3-backed PVC sized 10Gi (Req 11.2)
      # ----------------------------------------------------------------
      volumeClaimTemplates = [
        {
          metadata = {
            name = "mongodb-data"
            labels = {
              "app.kubernetes.io/name"    = "mongodb"
              "app.kubernetes.io/part-of" = "arch-analyzer"
            }
          }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = var.storage_class
            resources = {
              requests = {
                storage = var.storage_size
              }
            }
          }
        }
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# ClusterIP Service — mongodb on port 27017 (Requirement 11.4)
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "mongodb_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"

    metadata = {
      name      = "mongodb"
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/name"       = "mongodb"
        "app.kubernetes.io/part-of"    = "arch-analyzer"
        "app.kubernetes.io/component"  = "database"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = {
      type = "ClusterIP"

      selector = {
        app = "mongodb"
      }

      ports = [
        {
          name       = "mongodb"
          port       = 27017
          targetPort = 27017
          protocol   = "TCP"
        }
      ]
    }
  }
}
