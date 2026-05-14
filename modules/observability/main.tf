# =============================================================================
# Observability Module — CloudWatch log groups, metric alarms, and dashboard
#
# NOTE: Fluent Bit (Req 13.2) and CloudWatch Container Insights (Req 13.3)
# Helm releases will be added in tasks 2.4 and 2.5. This file covers only
# the CloudWatch resources: log groups, alarms, and dashboard (Req 13.1,
# 13.4, 13.5, 13.6, 13.7, 13.8).
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "observability"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups — Req 13.1
# /aws/eks/arch-analyzer/app   → application pod stdout/stderr (Fluent Bit target)
# /aws/eks/arch-analyzer/system → EKS control-plane / system logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/eks/arch-analyzer/app"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name    = "/aws/eks/arch-analyzer/app"
    Purpose = "application-logs"
  })
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/aws/eks/arch-analyzer/system"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name    = "/aws/eks/arch-analyzer/system"
    Purpose = "system-logs"
  })
}

# ---------------------------------------------------------------------------
# Metric Alarm 1 — Pod CPU > 80% for 5 min — Req 13.4
#
# Namespace: ContainerInsights (populated by the Container Insights agent
# installed in task 2.5). Metric: pod_cpu_utilization.
# Dimensions: ClusterName + Namespace (all namespaces via missing_data=notBreaching).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "pod_cpu_high" {
  alarm_name          = "${local.name_prefix}-pod-cpu-high"
  alarm_description   = "Pod CPU utilisation exceeded ${var.pod_cpu_threshold_percent}% for 5 consecutive minutes. Req 13.4."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = var.pod_cpu_threshold_percent
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-pod-cpu-high"
    Concern = "pod-cpu"
  })
}

# ---------------------------------------------------------------------------
# Metric Alarm 2 — Node memory > 85% for 5 min — Req 13.5
#
# Metric: node_memory_utilization from ContainerInsights.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "node_memory_high" {
  alarm_name          = "${local.name_prefix}-node-memory-high"
  alarm_description   = "Node memory utilisation exceeded ${var.node_memory_threshold_percent}% for 5 consecutive minutes. Req 13.5."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = var.node_memory_threshold_percent
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-node-memory-high"
    Concern = "node-memory"
  })
}

# ---------------------------------------------------------------------------
# Metric Alarm 3 — ALB HTTPCode_Target_5XX_Count — Req 13.6
#
# Namespace: AWS/ApplicationELB. Dimension: LoadBalancer (ARN suffix).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx-high"
  alarm_description   = "ALB HTTPCode_Target_5XX_Count exceeded ${var.alb_5xx_threshold} in a 5-minute window. Req 13.6."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-alb-5xx-high"
    Concern = "alb-errors"
  })
}

# ---------------------------------------------------------------------------
# Metric Alarm 4 — Processing_DLQ depth > 0 — Req 13.6
#
# Any message landing in the DLQ means a processing failure after 3 retries.
# Threshold=0 with GreaterThanThreshold fires on the first message.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-dlq-messages-visible"
  alarm_description   = "Processing_DLQ has messages visible (ApproximateNumberOfMessagesVisible > 0). Indicates processing failures. Req 13.6."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-dlq-messages-visible"
    Concern = "dlq-depth"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard — Req 13.7
#
# Widgets:
#   Row 1: Pod CPU (all services) | Node Memory
#   Row 2: ALB 5xx rate           | Processing DLQ depth
#
# Each widget uses a metric query so the dashboard works even before
# Container Insights emits data (widgets show "No data" gracefully).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # ---- Pod CPU utilisation (per service namespace) ----
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Pod CPU Utilisation (%) — all services"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            for ns in ["arch-analyzer-api", "arch-analyzer-ia", "auth"] : [
              "ContainerInsights",
              "pod_cpu_utilization",
              "ClusterName", var.cluster_name,
              "Namespace", ns,
              { label = ns, stat = "Average", period = 60 }
            ]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = var.pod_cpu_threshold_percent, label = "Alarm threshold", color = "#ff6961" }]
          }
        }
      },

      # ---- Node memory utilisation ----
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Node Memory Utilisation (%)"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            [
              "ContainerInsights",
              "node_memory_utilization",
              "ClusterName", var.cluster_name,
              { label = "All nodes", stat = "Average", period = 60 }
            ]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = var.node_memory_threshold_percent, label = "Alarm threshold", color = "#ff6961" }]
          }
        }
      },

      # ---- ALB 5xx rate ----
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB HTTPCode_Target_5XX_Count"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            [
              "AWS/ApplicationELB",
              "HTTPCode_Target_5XX_Count",
              "LoadBalancer", var.alb_arn_suffix,
              { label = "5xx errors", stat = "Sum", period = 60, color = "#d62728" }
            ]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ---- Processing DLQ depth ----
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Processing DLQ — ApproximateNumberOfMessagesVisible"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            [
              "AWS/SQS",
              "ApproximateNumberOfMessagesVisible",
              "QueueName", var.dlq_name,
              { label = "DLQ depth", stat = "Sum", period = 60, color = "#ff7f0e" }
            ]
          ]
          yAxis = { left = { min = 0 } }
          annotations = {
            horizontal = [{ value = 1, label = "Alarm threshold", color = "#ff6961" }]
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Fluent Bit DaemonSet — Req 13.2
#
# Helm chart: eks/aws-for-fluent-bit
# Streams pod stdout/stderr from every node to the CloudWatch log group
# /aws/eks/arch-analyzer/app (created above).
#
# The chart ships a pre-configured OUTPUT plugin for CloudWatch Logs.
# We override only the values that must match our environment:
#   - cloudWatch.region        → AWS region
#   - cloudWatch.logGroupName  → the log group created by this module
#   - cloudWatch.logStreamPrefix → "from-fluent-bit-" (default; kept explicit)
#   - cloudWatch.autoCreateGroup → false (group already exists above)
#
# Academy note: Fluent Bit pods use the node LabRole credentials via IMDS
# (no IRSA). The LabRole has CloudWatch Logs PutLogEvents permission.
# ---------------------------------------------------------------------------

resource "helm_release" "fluent_bit" {
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  version          = var.fluent_bit_chart_version

  # Ensure the log group exists before Fluent Bit starts writing to it
  depends_on = [aws_cloudwatch_log_group.app]

  # ---- CloudWatch Logs output plugin ----
  set {
    name  = "cloudWatch.enabled"
    value = "true"
  }

  set {
    name  = "cloudWatch.region"
    value = var.aws_region
  }

  set {
    name  = "cloudWatch.logGroupName"
    value = aws_cloudwatch_log_group.app.name
  }

  set {
    name  = "cloudWatch.logStreamPrefix"
    value = "from-fluent-bit-"
  }

  # Group already created by Terraform — do not let Fluent Bit attempt creation
  # (would fail under Academy's restricted IAM)
  set {
    name  = "cloudWatch.autoCreateGroup"
    value = "false"
  }

  # ---- Disable other outputs (Kinesis, Firehose) not used in this stack ----
  set {
    name  = "kinesis.enabled"
    value = "false"
  }

  set {
    name  = "firehose.enabled"
    value = "false"
  }

  set {
    name  = "elasticsearch.enabled"
    value = "false"
  }

  # ---- DaemonSet tolerations — run on every node including system nodes ----
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  # ---- Resource limits — keep footprint small on t3.small nodes ----
  set {
    name  = "resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }

  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Container Insights — Req 13.3
#
# Installs the amazon-cloudwatch-observability add-on via Helm.
# Chart: amazon-cloudwatch/cloudwatch-agent (aws-observability/amazon-cloudwatch-observability)
# Namespace: amazon-cloudwatch (created inline by the Helm release)
#
# The agent runs as a DaemonSet on every node and publishes Container Insights
# metrics (pod_cpu_utilization, node_memory_utilization, etc.) to the
# ContainerInsights CloudWatch namespace — the same namespace referenced by
# the metric alarms above (Req 13.4, 13.5).
#
# Academy note: LabRole already has CloudWatch:PutMetricData + logs:* permissions
# so no additional IAM is required. IRSA is intentionally NOT used (Academy blocks
# iam:CreateRole); the DaemonSet inherits node-level LabRole credentials via IMDS.
# ---------------------------------------------------------------------------

resource "helm_release" "cloudwatch_container_insights" {
  name             = "amazon-cloudwatch-observability"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-cloudwatch-metrics"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  version          = var.cloudwatch_helm_chart_version

  # Pass cluster name so the agent tags all metrics with the correct ClusterName
  # dimension — required for the alarms defined above to resolve correctly.
  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  # Disable IRSA-based service account annotation; rely on node-level LabRole
  # credentials via IMDS (Academy constraint: no iam:CreateRole / OIDC provider).
  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = ""
  }

  # Ensure the log group for system metrics already exists before the agent starts
  depends_on = [
    aws_cloudwatch_log_group.app,
    aws_cloudwatch_log_group.system,
  ]

  lifecycle {
    ignore_changes = [
      # Allow manual chart upgrades without Terraform drift
      version,
    ]
  }
}
