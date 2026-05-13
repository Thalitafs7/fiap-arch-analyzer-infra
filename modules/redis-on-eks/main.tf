# =============================================================================
# Redis on EKS Module — Main
# Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 10.3, 10.4
#
# Deploys a single-replica Redis StatefulSet in the `data` namespace with:
#   - AUTH required, password sourced from AWS Secrets Manager via init container
#   - gp3-backed PVC (2Gi default)
#   - Secret-sync init container using amazon/aws-cli:2.15.0 + IMDS node credentials
#   - automountServiceAccountToken=false
#   - ClusterIP Service named `redis` on port 6379
# =============================================================================

# =============================================================================
# Redis StatefulSet (Req 12.1, 12.2, 12.3, 12.4, 10.3, 10.4)
# =============================================================================

resource "kubernetes_manifest" "redis_statefulset" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "StatefulSet"

    metadata = {
      name      = "redis"
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/name"       = "redis"
        "app.kubernetes.io/part-of"    = "arch-analyzer"
        "app.kubernetes.io/component"  = "cache"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = {
      serviceName = "redis"
      replicas    = 1

      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "redis"
        }
      }

      template = {
        metadata = {
          labels = {
            "app.kubernetes.io/name"      = "redis"
            "app.kubernetes.io/part-of"   = "arch-analyzer"
            "app.kubernetes.io/component" = "cache"
          }
        }

        spec = {
          # Req 10.4 — no service account token mounted on pod
          automountServiceAccountToken = false

          # ---------------------------------------------------------------------------
          # Init container: secret-sync (Req 10.3, 10.4)
          # Fetches arch-analyzer/redis/password from Secrets Manager using node IMDS
          # credentials (LabRole) and writes the plaintext value to an in-memory volume.
          # ---------------------------------------------------------------------------
          initContainers = [
            {
              name  = "secrets-sync"
              image = var.aws_cli_image

              command = ["/bin/sh", "-c"]
              args = [
                "set -e; SECRET=$(aws secretsmanager get-secret-value --secret-id \"${var.password_secret_name}\" --region \"${var.aws_region}\" --query SecretString --output text); printf '%s' \"$SECRET\" > /secrets/redis-password"
              ]

              env = [
                {
                  name  = "AWS_REGION"
                  value = var.aws_region
                }
              ]

              volumeMounts = [
                {
                  name      = "secrets"
                  mountPath = "/secrets"
                }
              ]

              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = false # aws-cli writes temp files
                capabilities = {
                  drop = ["ALL"]
                }
              }
            }
          ]

          # ---------------------------------------------------------------------------
          # Main container: Redis (Req 12.1, 12.2)
          # Reads password from the shared in-memory volume and starts with --requirepass
          # ---------------------------------------------------------------------------
          containers = [
            {
              name  = "redis"
              image = var.redis_image

              command = ["/bin/sh", "-c"]
              args = [
                "REDIS_PASSWORD=$(cat /secrets/redis-password); exec redis-server --requirepass \"$REDIS_PASSWORD\" --appendonly yes --dir /data"
              ]

              ports = [
                {
                  name          = "redis"
                  containerPort = 6379
                  protocol      = "TCP"
                }
              ]

              resources = {
                requests = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
                limits = {
                  cpu    = "500m"
                  memory = "256Mi"
                }
              }

              livenessProbe = {
                exec = {
                  command = [
                    "/bin/sh", "-c",
                    "redis-cli -a \"$(cat /secrets/redis-password)\" ping | grep -q PONG"
                  ]
                }
                initialDelaySeconds = 30
                periodSeconds       = 10
                timeoutSeconds      = 5
                failureThreshold    = 3
              }

              readinessProbe = {
                exec = {
                  command = [
                    "/bin/sh", "-c",
                    "redis-cli -a \"$(cat /secrets/redis-password)\" ping | grep -q PONG"
                  ]
                }
                initialDelaySeconds = 5
                periodSeconds       = 5
                timeoutSeconds      = 3
                failureThreshold    = 3
              }

              securityContext = {
                allowPrivilegeEscalation = false
                readOnlyRootFilesystem   = false # Redis writes to /data
                capabilities = {
                  drop = ["ALL"]
                }
              }

              volumeMounts = [
                {
                  name      = "redis-data"
                  mountPath = "/data"
                },
                {
                  name      = "secrets"
                  mountPath = "/secrets"
                  readOnly  = true
                }
              ]
            }
          ]

          # ---------------------------------------------------------------------------
          # Volumes
          # secrets: emptyDir{medium: Memory} — never touches disk (Req 10.3)
          # redis-data: claimed via volumeClaimTemplates below
          # ---------------------------------------------------------------------------
          volumes = [
            {
              name = "secrets"
              emptyDir = {
                medium = "Memory"
              }
            }
          ]
        }
      }

      # ---------------------------------------------------------------------------
      # PVC template: gp3-backed, 2Gi (Req 12.3)
      # ---------------------------------------------------------------------------
      volumeClaimTemplates = [
        {
          metadata = {
            name = "redis-data"
            labels = {
              "app.kubernetes.io/name"    = "redis"
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

# =============================================================================
# Redis ClusterIP Service (Req 12.4, 12.5)
# Named `redis` in the `data` namespace on port 6379.
# =============================================================================

resource "kubernetes_manifest" "redis_service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"

    metadata = {
      name      = "redis"
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/name"       = "redis"
        "app.kubernetes.io/part-of"    = "arch-analyzer"
        "app.kubernetes.io/component"  = "cache"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }

    spec = {
      type = "ClusterIP"

      selector = {
        "app.kubernetes.io/name" = "redis"
      }

      ports = [
        {
          name       = "redis"
          port       = 6379
          targetPort = 6379
          protocol   = "TCP"
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.redis_statefulset]
}
