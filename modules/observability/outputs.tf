# =============================================================================
# Observability Module — Outputs
# Req 13.8: expose log_group_names (map) and alarm_arns (list)
# =============================================================================

# ---------------------------------------------------------------------------
# log_group_names — map keyed by logical name → CloudWatch log group name
# Consumed by the Fluent Bit Helm values (task 2.4) and Container Insights
# agent config (task 2.5) to know which log group to target.
# ---------------------------------------------------------------------------

output "log_group_names" {
  description = "Map of logical name to CloudWatch log group name. Keys: 'app', 'system'."
  value = {
    app    = aws_cloudwatch_log_group.app.name
    system = aws_cloudwatch_log_group.system.name
  }
}

# ---------------------------------------------------------------------------
# alarm_arns — list of all CloudWatch metric alarm ARNs created by this module
# Consumed by root outputs.tf and optionally by SNS / EventBridge rules.
# ---------------------------------------------------------------------------

output "alarm_arns" {
  description = "List of ARNs for all CloudWatch metric alarms created by this module."
  value = [
    aws_cloudwatch_metric_alarm.pod_cpu_high.arn,
    aws_cloudwatch_metric_alarm.node_memory_high.arn,
    aws_cloudwatch_metric_alarm.alb_5xx.arn,
    aws_cloudwatch_metric_alarm.dlq_depth.arn,
  ]
}

# ---------------------------------------------------------------------------
# dashboard_name — convenience output for the orchestrator / README
# ---------------------------------------------------------------------------

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
