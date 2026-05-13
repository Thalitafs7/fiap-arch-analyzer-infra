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

resource "kubernetes_stateful_set_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "redis"
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/component"  = "cache"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    service_name = "redis"
    replicas     = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "redis"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "redis"
          "app.kubernetes.io/part-of"   = "arch-analyzer"
          "app.kubernetes.io/component" = "cache"
        }
      }

      spec {
        automount_service_account_token = false

        # Init container: secret-sync (Req 10.3, 10.4)
        init_container {
          name  = "secrets-sync"
          image = var.aws_cli_image

          command = ["/bin/sh", "-c"]
          args = [
            "set -e; SECRET=$(aws secretsmanager get-secret-value --secret-id \"${var.password_secret_name}\" --region \"${var.aws_region}\" --query SecretString --output text); printf '%s' \"$SECRET\" > /secrets/redis-password"
          ]

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }

          volume_mount {
            name       = "secrets"
            mount_path = "/secrets"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
          }
        }

        # Main container: Redis (Req 12.1, 12.2)
        container {
          name  = "redis"
          image = var.redis_image

          command = ["/bin/sh", "-c"]
          args = [
            "REDIS_PASSWORD=$(cat /secrets/redis-password); exec redis-server --requirepass \"$REDIS_PASSWORD\" --appendonly yes --dir /data"
          ]

          port {
            name           = "redis"
            container_port = 6379
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            exec {
              command = [
                "/bin/sh", "-c",
                "redis-cli -a \"$(cat /secrets/redis-password)\" ping | grep -q PONG"
              ]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = [
                "/bin/sh", "-c",
                "redis-cli -a \"$(cat /secrets/redis-password)\" ping | grep -q PONG"
              ]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
          }

          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }

          volume_mount {
            name       = "secrets"
            mount_path = "/secrets"
            read_only  = true
          }
        }

        # Volumes
        volume {
          name = "secrets"
          empty_dir {
            medium = "Memory"
          }
        }
      }
    }

    # PVC template: gp3-backed, 2Gi (Req 12.3)
    volume_claim_template {
      metadata {
        name = "redis-data"
        labels = {
          "app.kubernetes.io/name"    = "redis"
          "app.kubernetes.io/part-of" = "arch-analyzer"
        }
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class
        resources {
          requests = {
            storage = var.storage_size
          }
        }
      }
    }
  }
}

# =============================================================================
# Redis ClusterIP Service (Req 12.4, 12.5)
# =============================================================================

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "redis"
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/component"  = "cache"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "redis"
    }

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_stateful_set_v1.redis]
}
