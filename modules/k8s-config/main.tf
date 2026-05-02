# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "app_namespaces" {
  for_each = toset(["arch-analyzer-api", "arch-analyzer-ia", "ingress-nginx"])

  metadata {
    name = each.value

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

# =============================================================================
# NGINX Ingress Controller (Helm)
# =============================================================================

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version != "" ? var.ingress_nginx_chart_version : null
  namespace  = "ingress-nginx"
  timeout    = 300

  set {
    name  = "controller.service.type"
    value = "NodePort"
  }

  set {
    name  = "controller.service.nodePorts.http"
    value = "30080"
  }

  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

# =============================================================================
# NetworkPolicies - Default Deny Ingress
# =============================================================================

resource "kubernetes_network_policy" "deny_ingress_api" {
  metadata {
    name      = "default-deny-ingress"
    namespace = "arch-analyzer-api"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

resource "kubernetes_network_policy" "deny_ingress_ia" {
  metadata {
    name      = "default-deny-ingress"
    namespace = "arch-analyzer-ia"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

# =============================================================================
# NetworkPolicies - Allow Ingress Controller
# =============================================================================

resource "kubernetes_network_policy" "allow_ingress_to_api" {
  metadata {
    name      = "allow-ingress-controller"
    namespace = "arch-analyzer-api"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress-nginx"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

resource "kubernetes_network_policy" "allow_ingress_to_ia" {
  metadata {
    name      = "allow-ingress-controller"
    namespace = "arch-analyzer-ia"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress-nginx"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

# =============================================================================
# NetworkPolicies - Inter-service Communication
# =============================================================================

resource "kubernetes_network_policy" "allow_ia_webhook_to_api" {
  metadata {
    name      = "allow-ia-webhook"
    namespace = "arch-analyzer-api"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "arch-analyzer-ia"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

resource "kubernetes_network_policy" "allow_api_to_ia" {
  metadata {
    name      = "allow-api-access"
    namespace = "arch-analyzer-ia"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "arch-analyzer-api"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

# =============================================================================
# ConfigMaps - Infrastructure Endpoints
# =============================================================================

resource "kubernetes_config_map" "infra_config_api" {
  metadata {
    name      = "infra-config"
    namespace = "arch-analyzer-api"
  }

  data = {
    AWS_REGION     = var.aws_region
    DB_HOST        = var.db_address
    DB_NAME        = var.db_name
    DB_PORT        = "5432"
    SQS_QUEUE_URL  = var.sqs_processing_queue_url
    SQS_DLQ_URL    = var.sqs_dlq_url
    S3_BUCKET_NAME = var.s3_diagrams_bucket
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}

resource "kubernetes_config_map" "infra_config_ia" {
  metadata {
    name      = "infra-config"
    namespace = "arch-analyzer-ia"
  }

  data = {
    AWS_REGION     = var.aws_region
    SQS_QUEUE_URL  = var.sqs_processing_queue_url
    SQS_DLQ_URL    = var.sqs_dlq_url
    S3_BUCKET_NAME = var.s3_diagrams_bucket
  }

  depends_on = [kubernetes_namespace.app_namespaces]
}
