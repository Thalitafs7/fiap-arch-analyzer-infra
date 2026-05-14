# Req 6.1–6.9, 17.5, 18.4 — outputs consumed by k8s-config (infra-outputs ConfigMap)
# and by the secrets module (per-service Postgres connection strings).

output "instances" {
  description = <<-EOT
    Map of service key -> { address, endpoint, port, db_name, instance_id, username }.
    Username is included so the secrets module can assemble connection
    strings without re-reading var.databases. Not sensitive: address/port
    /db_name/username are not credentials in isolation.
  EOT
  value = {
    for k, db in aws_db_instance.this : k => {
      address     = db.address
      endpoint    = db.endpoint
      port        = db.port
      db_name     = db.db_name
      instance_id = db.id
      username    = db.username
    }
  }
  sensitive = false
}

output "connection_strings" {
  description = <<-EOT
    Map of service key -> full Postgres connection string.

    Format selection per service:
      - processing  → URI form (postgresql://user:pass@host:port/db) for
                      Python/SQLAlchemy and psycopg.
      - registration / report → .NET Npgsql keyword=value (Host=...;
                      Port=...;Database=...;Username=...;Password=...;
                      SSL Mode=Require;Trust Server Certificate=true).

    SSL Mode=Require is set because RDS encryption is enabled. The cert
    chain is signed by the AWS RDS root CA; we set
    Trust Server Certificate=true to skip client-side root CA bundling
    in the lab context. For production this should flip to false and the
    pod should mount the AWS RDS root CA bundle instead.

    Marked sensitive so plan/apply output never echoes the master password.
  EOT
  value = {
    for k, db in aws_db_instance.this :
    k => k == "processing" ? format(
      "postgresql://%s:%s@%s:%d/%s",
      db.username,
      var.databases[k].password,
      db.address,
      db.port,
      db.db_name,
      ) : format(
      "Host=%s;Port=%d;Database=%s;Username=%s;Password=%s;SSL Mode=Require;Trust Server Certificate=true",
      db.address,
      db.port,
      db.db_name,
      db.username,
      var.databases[k].password,
    )
  }
  sensitive = true
}
