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

resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "mongodb"
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/component"  = "database"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    service_name = "mongodb"
    replicas     = 1

    selector {
      match_labels = {
        app = "mongodb"
      }
    }

    template {
      metadata {
        labels = {
          app                           = "mongodb"
          "app.kubernetes.io/name"      = "mongodb"
          "app.kubernetes.io/part-of"   = "arch-analyzer"
          "app.kubernetes.io/component" = "database"
        }
      }

      spec {
        automount_service_account_token = false

        security_context {
          run_as_non_root = false
          fs_group        = 999
        }

        # Init container — secret-sync (Requirement 10.3, 11.3)
        init_container {
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
            echo "$SECRET_JSON" | grep -o '"password":"[^"]*"' | cut -d'"' -f4 > /secrets/mongo-password
            echo "Secret written to /secrets/mongo-password"
            EOT
          ]

          volume_mount {
            name       = "secrets"
            mount_path = "/secrets"
          }

          resources {
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

        # Main container — MongoDB 7
        container {
          name  = "mongodb"
          image = var.mongodb_image

          port {
            container_port = 27017
            name           = "mongodb"
            protocol       = "TCP"
          }

          env {
            name  = "MONGO_INITDB_ROOT_USERNAME"
            value = "root"
          }

          env {
            name  = "MONGO_INITDB_ROOT_PASSWORD_FILE"
            value = "/secrets/mongo-password"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["mongosh", "--eval", "db.adminCommand('ping')"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = ["mongosh", "--eval", "db.adminCommand('ping')"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
          }

          volume_mount {
            name       = "mongodb-data"
            mount_path = "/data/db"
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

    # VolumeClaimTemplates — gp3-backed PVC (Req 11.2)
    volume_claim_template {
      metadata {
        name = "mongodb-data"
        labels = {
          "app.kubernetes.io/name"    = "mongodb"
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

# ---------------------------------------------------------------------------
# ClusterIP Service — mongodb on port 27017 (Requirement 11.4)
# ---------------------------------------------------------------------------

resource "kubernetes_service_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "mongodb"
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/component"  = "database"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "mongodb"
    }

    port {
      name        = "mongodb"
      port        = 27017
      target_port = 27017
      protocol    = "TCP"
    }
  }
}
