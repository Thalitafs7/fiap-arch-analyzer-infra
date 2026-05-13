# Rollback Playbook

This playbook covers rollback procedures for the Arch Analyzer stack on AWS Academy EKS. It addresses three scenarios: per-service Kubernetes rollback, infrastructure Terraform rollback, and full stack teardown.

---

## 1. Per-Service Kubernetes Rollback

### 1.1 Roll back a single Deployment

Use `kubectl rollout undo` to revert to the previous ReplicaSet. The Deployment keeps `revisionHistoryLimit: 5` so up to 5 previous versions are available.

```bash
# Roll back to the previous revision
kubectl rollout undo deployment/<deployment-name> -n <namespace>

# Roll back to a specific revision
kubectl rollout undo deployment/<deployment-name> -n <namespace> --to-revision=<N>

# Check available revisions
kubectl rollout history deployment/<deployment-name> -n <namespace>

# Verify the rollback completed
kubectl rollout status deployment/<deployment-name> -n <namespace>
```

**Service-specific commands:**

```bash
# auth-service
kubectl rollout undo deployment/ms-auth-api -n auth

# api-gateway
kubectl rollout undo deployment/api-gateway -n arch-analyzer-api

# registration-service
kubectl rollout undo deployment/registration-service -n arch-analyzer-api

# processing-service
kubectl rollout undo deployment/processing-service -n arch-analyzer-ia

# celery-worker
kubectl rollout undo deployment/celery-worker -n arch-analyzer-ia

# report-service
kubectl rollout undo deployment/report-service -n arch-analyzer-ia
```

### 1.2 Roll back all services at once

```bash
# Roll back all services in reverse dependency order
kubectl rollout undo deployment/api-gateway -n arch-analyzer-api
kubectl rollout undo deployment/processing-service -n arch-analyzer-ia
kubectl rollout undo deployment/celery-worker -n arch-analyzer-ia
kubectl rollout undo deployment/report-service -n arch-analyzer-ia
kubectl rollout undo deployment/registration-service -n arch-analyzer-api
kubectl rollout undo deployment/ms-auth-api -n auth

# Wait for all rollbacks to complete
kubectl rollout status deployment/api-gateway -n arch-analyzer-api
kubectl rollout status deployment/processing-service -n arch-analyzer-ia
kubectl rollout status deployment/celery-worker -n arch-analyzer-ia
kubectl rollout status deployment/report-service -n arch-analyzer-ia
kubectl rollout status deployment/registration-service -n arch-analyzer-api
kubectl rollout status deployment/ms-auth-api -n auth
```

### 1.3 Validate after rollback

Run the Validator to confirm all services are healthy:

```bash
# Windows
.\scripts\validate.ps1

# Linux/macOS
bash scripts/validate.sh
```

The Validator probes `GET http://<alb_dns>/api/<service>/health` for each service and writes a JSON + Markdown report to `./artifacts/`.

---

## 2. Secret Rotation Rollback

If a secret rotation caused a service failure, revert the secret value and restart the affected pods.

### 2.1 Revert a secret in Secrets Manager

```bash
# List secret versions
aws secretsmanager list-secret-version-ids \
  --secret-id arch-analyzer/auth/mongo

# Restore a previous version (replace VERSION_ID with the previous AWSPREVIOUS stage)
aws secretsmanager update-secret-version-stage \
  --secret-id arch-analyzer/auth/mongo \
  --version-stage AWSCURRENT \
  --move-to-version-id <previous-version-id> \
  --remove-from-version-id <current-version-id>
```

### 2.2 Restart pods to pick up the reverted secret

```bash
# The init container re-fetches the secret on pod start
kubectl rollout restart deployment/ms-auth-api -n auth
kubectl rollout status deployment/ms-auth-api -n auth
```

---

## 3. ConfigMap Rollback

If the `infra-outputs` ConfigMap was updated with incorrect values (e.g. after a Terraform apply that changed the ALB DNS), restart all consuming Deployments after correcting the ConfigMap.

```bash
# Re-apply Terraform to restore the correct ConfigMap values
terraform apply

# Restart all service Deployments to pick up the updated ConfigMap
kubectl rollout restart deployment/ms-auth-api -n auth
kubectl rollout restart deployment/registration-service -n arch-analyzer-api
kubectl rollout restart deployment/processing-service -n arch-analyzer-ia
kubectl rollout restart deployment/celery-worker -n arch-analyzer-ia
kubectl rollout restart deployment/report-service -n arch-analyzer-ia
kubectl rollout restart deployment/api-gateway -n arch-analyzer-api
```

---

## 4. Terraform Infrastructure Rollback

### 4.1 Roll back a specific resource

Use `terraform destroy -target` to remove a specific resource and then re-apply the previous configuration.

```bash
# Example: roll back the ALB
terraform destroy -target=module.alb.aws_lb.main

# Re-apply to recreate with the previous configuration
terraform apply -target=module.alb
```

> **Warning:** `terraform destroy -target` is destructive and irreversible for stateful resources (RDS, S3). Always confirm the target before running.

### 4.2 Roll back to a previous Terraform state

If you have a previous state file backed up (e.g. from S3 state backend), restore it:

```bash
# Pull the previous state version (if using S3 backend with versioning)
aws s3 cp s3://<state-bucket>/terraform.tfstate.backup terraform.tfstate.backup

# Inspect the backup state
terraform show terraform.tfstate.backup

# Apply the backup state (use with extreme caution)
terraform state push terraform.tfstate.backup
terraform plan   # verify the diff
terraform apply
```

### 4.3 Terraform plan before any rollback

Always run `terraform plan` before `terraform apply` to understand the exact changes:

```bash
terraform plan -out=rollback.tfplan
terraform show rollback.tfplan   # review changes
terraform apply rollback.tfplan
```

---

## 5. MongoDB and Redis Rollback

MongoDB and Redis run as StatefulSets with persistent EBS volumes. Rolling back the StatefulSet image does not affect the data volume.

### 5.1 Roll back MongoDB

```bash
kubectl rollout undo statefulset/mongodb -n data
kubectl rollout status statefulset/mongodb -n data
```

### 5.2 Roll back Redis

```bash
kubectl rollout undo statefulset/redis -n data
kubectl rollout status statefulset/redis -n data
```

### 5.3 Verify data integrity after rollback

```bash
# Connect to MongoDB and verify
kubectl exec -it mongodb-0 -n data -- mongosh \
  --username root \
  --password "$(cat /secrets/mongo-password)" \
  --eval "db.adminCommand('ping')"

# Connect to Redis and verify
kubectl exec -it redis-0 -n data -- redis-cli \
  -a "$(cat /secrets/redis-password)" ping
```

---

## 6. Full Stack Teardown

Use `terraform destroy` to remove all AWS resources. This is irreversible.

```bash
# Destroy all resources (prompts for confirmation)
terraform destroy

# Force destroy without confirmation (use with extreme caution)
terraform destroy -auto-approve
```

> **Note:** `force_destroy = true` must be set in `terraform.tfvars` for S3 buckets and ECR repositories to be deleted when non-empty. The default is `false`.

---

## 7. AWS Academy Session Expiry

AWS Academy Learner Lab sessions expire after ~4 hours. If credentials expire mid-deployment:

1. The Deployment_Orchestrator will detect `ExpiredToken` and stop with a clear error message.
2. Open the Learner Lab console and click **Start Lab** to get new credentials.
3. Copy the new credentials into `~/.aws/credentials` (or set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` env vars).
4. Re-run the orchestrator — it is idempotent and will resume from where it left off.

```bash
# Verify new credentials are working
aws sts get-caller-identity

# Re-run the orchestrator
.\scripts\deploy-all.ps1   # Windows
bash scripts/deploy-all.sh  # Linux/macOS
```

---

## 8. Rollback Decision Matrix

| Symptom | Likely cause | Rollback action |
|---|---|---|
| Service returns 5xx after deploy | Bad image or config | `kubectl rollout undo deployment/<name>` |
| Service returns 5xx after secret rotation | Wrong secret value | Revert secret in Secrets Manager + restart pods |
| ALB health checks failing | NGINX Ingress misconfigured | Roll back k8s manifests + check ingress annotations |
| All services unreachable | ALB or EKS node issue | Check ALB target group health; check node status |
| Database connection errors | RDS SG or credentials | Verify SG rules; check `infra-outputs` ConfigMap values |
| MongoDB connection errors | MongoDB pod crashed | `kubectl rollout undo statefulset/mongodb -n data` |
| Redis connection errors | Redis pod crashed | `kubectl rollout undo statefulset/redis -n data` |
| Terraform apply failed mid-way | Partial state | `terraform plan` to assess; `terraform apply` to converge |
| `ExpiredToken` error | Academy session expired | Refresh credentials; re-run orchestrator |

---

## 9. Useful Diagnostic Commands

```bash
# Check pod status across all namespaces
kubectl get pods -A

# Check events for a failing pod
kubectl describe pod <pod-name> -n <namespace>

# Stream logs from a pod
kubectl logs -f deployment/<deployment-name> -n <namespace>

# Check init container logs (secret-sync)
kubectl logs <pod-name> -n <namespace> -c secrets-sync

# Check ALB target group health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn)

# Check Terraform state for a specific resource
terraform state show module.alb.aws_lb.main

# Force a pod restart without changing the Deployment spec
kubectl delete pod <pod-name> -n <namespace>
```
