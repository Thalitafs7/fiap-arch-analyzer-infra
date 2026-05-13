# Req 6.1–6.9, 17.5, 18.4 — outputs consumed by k8s-config (infra-outputs ConfigMap)

output "db_address" {
  description = "RDS instance hostname (no port). Mapped to DB_ADDRESS in infra-outputs ConfigMap."
  value       = aws_db_instance.main.address
}

output "db_endpoint" {
  description = "RDS instance endpoint in host:port format. Useful for direct connection strings."
  value       = aws_db_instance.main.endpoint
}

output "db_port" {
  description = "RDS instance port (5432). Mapped to DB_PORT in infra-outputs ConfigMap."
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Name of the initial database. Mapped to DB_NAME in infra-outputs ConfigMap."
  value       = aws_db_instance.main.db_name
}

output "db_instance_id" {
  description = "RDS instance identifier. Used for CloudWatch alarms and operational references."
  value       = aws_db_instance.main.id
}
