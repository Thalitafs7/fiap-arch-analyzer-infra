# =============================================================================
# K8s Config Module - Main
# Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 22.1, 23.1, 23.2, 23.3, 23.4, 23.5, 23.7
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# Locals
# =============================================================================

locals {
  # Namespaces bootstrapped by infra (Req 9.1)
  all_namespaces = ["arch-analyzer-api", "arch-analyzer-ia", "auth", "data", "ingress-nginx"]

  # Application namespaces that receive the infra-outputs ConfigMap (Req 23.1)
  app_namespaces = ["arch-analyzer-api", "arch-analyzer-ia", "auth"]

  # Application namespaces that get default-deny NetworkPolicy (Req 9.2)
  # "data" is included so that only explicitly-allowed namespaces can reach MongoDB/Redis (Req 11.5)
  deny_namespaces = ["arch-analyzer-api", "arch-analyzer-ia", "auth", "data"]

  # infra-outputs ConfigMap data (Req 9.5, 23.2, 23.3)
  infra_outputs = {
    AWS_REGION                      = var.aws_region
    AWS_ACCOUNT_ID                  = data.aws_caller_identity.current.account_id
    CLUSTER_NAME                    = var.cluster_name
    ALB_DNS_NAME                    = var.alb_dns_name
    DB_ADDRESS                      = var.db_address
    DB_PORT                         = tostring(var.db_port)
    DB_NAME                         = var.db_name
    SQS_PROCESSING_QUEUE_URL        = var.sqs_processing_queue_url
    SQS_DLQ_URL                     = var.sqs_dlq_url
    S3_DIAGRAMS_BUCKET              = var.s3_diagrams_bucket
    ECR_REGISTRY                    = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    ECR_REPOSITORY_URL_GATEWAY      = var.ecr_repository_urls["gateway"]
    ECR_REPOSITORY_URL_AUTH         = var.ecr_repository_urls["auth"]
    ECR_REPOSITORY_URL_REGISTRATION = var.ecr_repository_urls["registration"]
    ECR_REPOSITORY_URL_PROCESSING   = var.ecr_repository_urls["processing"]
    ECR_REPOSITORY_URL_REPORT       = var.ecr_repository_urls["report"]
  }
}

# =============================================================================
# Namespaces (Req 9.1)
# =============================================================================

resource "kubernetes_namespace" "namespaces" {
  for_each = toset(local.all_namespaces)

  metadata {
    name = each.value

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "kubernetes.io/metadata.name"  = each.value
      "environment"                  = var.environment
    }
  }
}

# =============================================================================
# NGINX Ingress Controller (Req 9.4, 22.1)
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

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# NetworkPolicies - Default Deny Ingress (Req 9.2)
# =============================================================================

resource "kubernetes_network_policy" "default_deny_ingress" {
  for_each = toset(local.deny_namespaces)

  metadata {
    name      = "default-deny-ingress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# NetworkPolicies - Allow Ingress Controller → api-gateway (Req 9.3)
# =============================================================================

resource "kubernetes_network_policy" "allow_ingress_controller_to_api" {
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

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow Ingress Controller → arch-analyzer-ia (Req 9.3)
# =============================================================================

resource "kubernetes_network_policy" "allow_ingress_controller_to_ia" {
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

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow Ingress Controller → auth (Req 9.3)
# =============================================================================

resource "kubernetes_network_policy" "allow_ingress_controller_to_auth" {
  metadata {
    name      = "allow-ingress-controller"
    namespace = "auth"
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

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow api-gateway → auth (Req 9.3)
# =============================================================================

resource "kubernetes_network_policy" "allow_api_gateway_to_auth" {
  metadata {
    name      = "allow-api-gateway"
    namespace = "auth"
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

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow api-gateway → registration, processing, report (Req 9.3)
# api-gateway lives in arch-analyzer-api; registration also in arch-analyzer-api;
# processing and report live in arch-analyzer-ia.
# Allow arch-analyzer-api → arch-analyzer-ia for processing/report calls.
# =============================================================================

resource "kubernetes_network_policy" "allow_api_gateway_to_ia" {
  metadata {
    name      = "allow-api-gateway"
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

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow api-gateway → registration-service (same namespace, Req 9.3)
# Both api-gateway and registration-service live in arch-analyzer-api.
# Default-deny blocks intra-namespace traffic; explicit allow required.
# =============================================================================

resource "kubernetes_network_policy" "allow_api_gateway_to_registration" {
  metadata {
    name      = "allow-api-gateway-to-registration"
    namespace = "arch-analyzer-api"
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "registration-service"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "api-gateway"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow processing → celery-worker (same namespace, Req 9.3)
# Both processing-service and celery-worker live in arch-analyzer-ia.
# Intra-namespace traffic is allowed by labelling the pod selector.
# =============================================================================

resource "kubernetes_network_policy" "allow_processing_to_celery" {
  metadata {
    name      = "allow-processing-to-celery"
    namespace = "arch-analyzer-ia"
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "celery-worker"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "processing-service"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# NetworkPolicies - Allow {registration, processing, report} → data (Req 9.3, 11.5)
# Ports: 27017 (MongoDB), 6379 (Redis)
# data namespace has default-deny (above); only arch-analyzer-api, arch-analyzer-ia,
# and auth are explicitly allowed — all other namespaces are rejected (Req 11.5).
# =============================================================================

resource "kubernetes_network_policy" "allow_app_namespaces_to_data" {
  metadata {
    name      = "allow-app-namespaces"
    namespace = "data"
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

      ports {
        protocol = "TCP"
        port     = "27017"
      }

      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "arch-analyzer-ia"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "27017"
      }

      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "auth"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "27017"
      }

      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }
  }

  depends_on = [
    kubernetes_namespace.namespaces,
    kubernetes_network_policy.default_deny_ingress,
  ]
}

# =============================================================================
# infra-outputs ConfigMap (Req 9.5, 23.1–23.5, 23.7)
# Published in every application namespace via for_each.
# =============================================================================

resource "kubernetes_config_map" "infra_outputs" {
  for_each = toset(local.app_namespaces)

  metadata {
    name      = "infra-outputs"
    namespace = each.value

    # Req 23.4 — mandatory labels
    labels = {
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # Req 23.2 — exactly the 16 keys; Req 23.3 — numeric values cast via tostring()
  data = local.infra_outputs

  depends_on = [kubernetes_namespace.namespaces]
}
