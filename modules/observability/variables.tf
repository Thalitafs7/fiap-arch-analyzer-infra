# =============================================================================
# Observability Module — Variables
# Req 13.1, 13.4, 13.5, 13.6, 13.7, 13.8
# =============================================================================

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are deployed."
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# EKS inputs — needed for Container Insights metric namespace and Helm releases
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the EKS cluster. Used as dimension in CloudWatch metric alarms and as Helm value."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API server endpoint. Passed to Helm releases that need cluster context."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the EKS cluster. Used by Helm releases."
  type        = string
}

# ---------------------------------------------------------------------------
# ALB inputs — needed for 5xx alarm
# ---------------------------------------------------------------------------

variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB (the portion after 'loadbalancer/'). Used as CloudWatch dimension for HTTPCode_Target_5XX_Count alarm."
  type        = string
}

# ---------------------------------------------------------------------------
# SQS DLQ inputs — needed for DLQ depth alarm
# ---------------------------------------------------------------------------

variable "dlq_name" {
  description = "Name of the Processing_DLQ SQS queue. Used as CloudWatch dimension for ApproximateNumberOfMessagesVisible alarm."
  type        = string
}

# ---------------------------------------------------------------------------
# Alarm notification — optional SNS topic ARN
# ---------------------------------------------------------------------------

variable "alarm_actions" {
  description = "List of ARNs to notify when any alarm transitions to ALARM state (e.g. SNS topic). Leave empty in Academy environments where SNS is not configured."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Log retention
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log group retention in days. Req 13.1 mandates 7 days."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Alarm thresholds — exposed as variables so they can be overridden per env
# ---------------------------------------------------------------------------

variable "pod_cpu_threshold_percent" {
  description = "Pod CPU utilisation threshold (%) above which the alarm fires. Req 13.4 mandates 80."
  type        = number
  default     = 80
}

variable "node_memory_threshold_percent" {
  description = "Node memory utilisation threshold (%) above which the alarm fires. Req 13.5 mandates 85."
  type        = number
  default     = 85
}

variable "alb_5xx_threshold" {
  description = "Number of ALB HTTPCode_Target_5XX_Count errors per evaluation period that triggers the alarm. Req 13.6."
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Fluent Bit Helm chart version — Req 13.2
# ---------------------------------------------------------------------------

variable "fluent_bit_chart_version" {
  description = "Version of the aws-for-fluent-bit Helm chart (eks/aws-for-fluent-bit). Pin to a specific version for reproducibility."
  type        = string
  default     = "0.1.34"
}

# ---------------------------------------------------------------------------
# Helm chart versions — pinned for reproducibility
# ---------------------------------------------------------------------------

variable "cloudwatch_helm_chart_version" {
  description = "Version of the aws-cloudwatch-metrics Helm chart (eks/aws-cloudwatch-metrics). Pin to a specific version for reproducibility."
  type        = string
  default     = "0.0.10"
}
