# Connection Strings & Infrastructure Reference

> **Generated from:** `variables.tf`, `main.tf`, `outputs.tf`, and module configurations  
> **Last Updated:** May 14, 2026  
> **Environment:** AWS Academy (LabRole, EKS, no NAT Gateway)

---

## 1. Database Connection Strings

### 1.1 PostgreSQL Instances (RDS)

Three per-service PostgreSQL 15 instances are provisioned in private subnets. Each service owns its own database for schema isolation and independent scaling.

#### Registration Service

**Format:** .NET Npgsql (keyword=value)

```
Host=<registration-endpoint>;Port=5432;Database=registration_db;Username=registration_user;Password=<master-password>;SSL Mode=Require;Trust Server Certificate=true
```

**Components:**
- **Host:** `module.database.instances["registration"].address` (RDS endpoint)
- **Port:** `5432` (fixed)
- **Database:** `registration_db`
- **Username:** `registration_user`
- **Password:** Auto-generated via `random_password.db_master["registration"]` (24 chars, special chars: `!#$%*-_+=`)
- **SSL Mode:** `Require` (RDS encryption enabled)
- **Trust Server Certificate:** `true` (AWS RDS root CA; for prod, set to `false` and mount CA bundle)

**Stored in AWS Secrets Manager:**
- **Path:** `arch-analyzer/db/registration`
- **Type:** Raw connection string (NOT JSON)
- **Access:** Via init container pattern in registration pod

**Terraform Output:**
```hcl
terraform output -json db_instances | jq '.registration'
```

---

#### Report Service

**Format:** .NET Npgsql (keyword=value)

```
Host=<report-endpoint>;Port=5432;Database=report_db;Username=report_user;Password=<master-password>;SSL Mode=Require;Trust Server Certificate=true
```

**Components:**
- **Host:** `module.database.instances["report"].address`
- **Port:** `5432`
- **Database:** `report_db`
- **Username:** `report_user`
- **Password:** Auto-generated via `random_password.db_master["report"]`
- **SSL Mode:** `Require`
- **Trust Server Certificate:** `true`

**Stored in AWS Secrets Manager:**
- **Path:** `arch-analyzer/db/report`
- **Type:** Raw connection string (NOT JSON)

---

#### Processing Service

**Format:** PostgreSQL URI (for Python/SQLAlchemy/psycopg)

```
postgresql://processing_user:<master-password>@<processing-endpoint>:5432/processing_db
```

**Components:**
- **Scheme:** `postgresql://`
- **Username:** `processing_user`
- **Password:** Auto-generated via `random_password.db_master["processing"]`
- **Host:** `module.database.instances["processing"].address`
- **Port:** `5432`
- **Database:** `processing_db`

**Stored in AWS Secrets Manager:**
- **Path:** `arch-analyzer/db/processing`
- **Type:** Raw connection string (NOT JSON)

---

### 1.2 RDS Instance Details

| Property | Value |
|----------|-------|
| **Engine** | PostgreSQL 15 |
| **Instance Class** | `db.t3.micro` (default, configurable) |
| **Storage** | 20 GB gp3 (default, autoscale to 50 GB) |
| **Multi-AZ** | No (single-AZ for Academy budget) |
| **Publicly Accessible** | No (private subnets only) |
| **Encryption at Rest** | Yes (AWS-managed key) |
| **IAM Database Auth** | Enabled |
| **Backup Retention** | 7 days |
| **Backup Window** | 03:00–04:00 UTC |
| **Maintenance Window** | Monday 04:00–05:00 UTC |
| **Parameter Group** | `arch-analyzer-pg15-*` (shared) |
| **Logging** | Connections, disconnections, DDL, queries > 1s |

**Terraform Outputs:**
```bash
# Get all RDS endpoints
terraform output -json db_instances

# Get registration endpoint only
terraform output -json db_instances | jq '.registration.address'

# Get backward-compat output
terraform output db_address
terraform output db_endpoint
```

---

## 2. SQS Queues

### 2.1 Processing Queue

**Queue Name:** `arch-analyzer-processing-<environment>`

**Queue URL:** `module.messaging.processing_queue_url`

**Terraform Output:**
```bash
terraform output sqs_processing_queue_url
```

**Configuration:**
- **Type:** Standard Queue
- **Visibility Timeout:** 600 seconds (covers LLM processing latency)
- **Message Retention:** 14 days (default, configurable)
- **Long Polling:** 20 seconds (reduces empty-receive API calls)
- **Encryption:** SSE-SQS (AWS-managed key, Academy-compatible)
- **Redrive Policy:** Sends to DLQ after 3 failed receives
- **Transport Security:** Denies plain HTTP (requires HTTPS)

**Example Usage (Python):**
```python
import boto3

sqs = boto3.client('sqs', region_name='us-east-1')
queue_url = os.getenv('SQS_PROCESSING_QUEUE_URL')

# Send message
response = sqs.send_message(
    QueueUrl=queue_url,
    MessageBody=json.dumps({'task': 'analyze_architecture'})
)

# Receive message
messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
```

---

### 2.2 Dead Letter Queue (DLQ)

**Queue Name:** `arch-analyzer-processing-dlq-<environment>`

**Queue URL:** `module.messaging.dlq_url`

**Terraform Output:**
```bash
terraform output sqs_dlq_url
```

**Configuration:**
- **Type:** Standard Queue
- **Message Retention:** 14 days (maximizes recovery window)
- **Long Polling:** 20 seconds
- **Encryption:** SSE-SQS (AWS-managed key)
- **Transport Security:** Denies plain HTTP

**Purpose:** Captures messages that fail processing 3 times. Monitored via CloudWatch alarms for operational visibility.

---

## 3. Environment Variables Injected into Pods

### 3.1 ConfigMap: `infra-outputs`

**Namespace:** `arch-analyzer-api`, `arch-analyzer-ia`, `auth`

**Contents:**

| Key | Value | Source |
|-----|-------|--------|
| `AWS_REGION` | `us-east-1` | `var.aws_region` |
| `AWS_ACCOUNT_ID` | `<account-id>` | `data.aws_caller_identity.current.account_id` |
| `CLUSTER_NAME` | `arch-analyzer-<env>` | `module.eks.cluster_name` |
| `ALB_DNS_NAME` | `<alb-dns>` | `module.alb.alb_dns_name` |
| `DB_ADDRESS` | `<registration-endpoint>` | `module.database.instances["registration"].address` |
| `DB_PORT` | `5432` | `module.database.instances["registration"].port` |
| `DB_NAME` | `registration_db` | `module.database.instances["registration"].db_name` |
| `SQS_PROCESSING_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/...` | `module.messaging.processing_queue_url` |
| `SQS_DLQ_URL` | `https://sqs.us-east-1.amazonaws.com/...` | `module.messaging.dlq_url` |
| `S3_DIAGRAMS_BUCKET` | `arch-analyzer-diagrams-<env>` | `module.storage.diagrams_bucket_id` |
| `ECR_REGISTRY` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com` | Computed |
| `ECR_REPOSITORY_URL_GATEWAY` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-gateway` | `module.ecr.repository_urls["gateway"]` |
| `ECR_REPOSITORY_URL_AUTH` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-auth` | `module.ecr.repository_urls["auth"]` |
| `ECR_REPOSITORY_URL_REGISTRATION` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-registration` | `module.ecr.repository_urls["registration"]` |
| `ECR_REPOSITORY_URL_PROCESSING` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-processing` | `module.ecr.repository_urls["processing"]` |
| `ECR_REPOSITORY_URL_REPORT` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-report` | `module.ecr.repository_urls["report"]` |

**Terraform Output:**
```bash
kubectl get configmap infra-outputs -n arch-analyzer-api -o yaml
```

---

### 3.2 Secrets: Database Connection Strings

**Namespace:** `arch-analyzer-api`, `arch-analyzer-ia`, `auth`

**Secrets:**

| Secret Path | Service | Format | Mounted Via |
|-------------|---------|--------|-------------|
| `arch-analyzer/db/registration` | Registration | Npgsql keyword=value | Init container → `/etc/secrets/db-connection-string` |
| `arch-analyzer/db/report` | Report | Npgsql keyword=value | Init container → `/etc/secrets/db-connection-string` |
| `arch-analyzer/db/processing` | Processing | PostgreSQL URI | Init container → `/etc/secrets/db-connection-string` |

**Init Container Pattern:**
```yaml
initContainers:
  - name: fetch-db-secret
    image: amazon/aws-cli:latest
    command:
      - /bin/sh
      - -c
      - |
        aws secretsmanager get-secret-value \
          --secret-id arch-analyzer/db/registration \
          --region us-east-1 \
          --query SecretString \
          --output text > /etc/secrets/db-connection-string
    volumeMounts:
      - name: secrets
        mountPath: /etc/secrets
    env:
      - name: AWS_ROLE_ARN
        value: arn:aws:iam::<account-id>:role/LabRole
      - name: AWS_WEB_IDENTITY_TOKEN_FILE
        value: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

---

### 3.3 Secrets: Auth & LLM Keys

| Secret Path | Contents | Format |
|-------------|----------|--------|
| `arch-analyzer/auth/mongo` | MongoDB root password | JSON: `{"password":"..."}` |
| `arch-analyzer/auth/jwt` | JWT signing key | JSON: `{"signing_key":"..."}` |
| `arch-analyzer/redis/password` | Redis AUTH password | JSON: `{"password":"..."}` |
| `arch-analyzer/llm/keys` | LLM provider API keys | JSON: `{"OPENAI_API_KEY":"...","ANTHROPIC_API_KEY":"...","HF_API_TOKEN":"..."}` |

---

## 4. MongoDB & Redis (On-Cluster StatefulSets)

### 4.1 MongoDB

**Namespace:** `data`

**StatefulSet:** `mongodb`

**Storage:** 10 Gi (gp2)

**Root Password Secret:** `arch-analyzer/auth/mongo`

**Connection String (from within cluster):**
```
mongodb://root:<password>@mongodb.data.svc.cluster.local:27017/admin
```

**Terraform Output:**
```bash
kubectl get statefulset mongodb -n data
kubectl get svc mongodb -n data
```

---

### 4.2 Redis

**Namespace:** `data`

**StatefulSet:** `redis`

**Storage:** 2 Gi (gp2)

**Password Secret:** `arch-analyzer/redis/password`

**Connection String (from within cluster):**
```
redis://:password@redis.data.svc.cluster.local:6379
```

**Terraform Output:**
```bash
kubectl get statefulset redis -n data
kubectl get svc redis -n data
```

---

## 5. S3 Buckets

### 5.1 Diagrams Bucket

**Bucket Name:** `arch-analyzer-diagrams-<environment>`

**Purpose:** Store generated architecture diagrams

**Terraform Output:**
```bash
terraform output s3_diagrams_bucket
```

**Access:** Via `S3_DIAGRAMS_BUCKET` environment variable in pods

---

### 5.2 ALB Access Logs Bucket

**Bucket Name:** `arch-analyzer-alb-logs-<environment>`

**Purpose:** Store ALB access logs for auditing

**Terraform Output:**
```bash
terraform output -json | grep -i "alb.*log"
```

---

## 6. ECR Repositories

**Registry URL:** `<account-id>.dkr.ecr.us-east-1.amazonaws.com`

**Repositories:**

| Repository | Full URL |
|------------|----------|
| `arch-analyzer-gateway` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-gateway` |
| `arch-analyzer-auth` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-auth` |
| `arch-analyzer-registration` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-registration` |
| `arch-analyzer-processing` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-processing` |
| `arch-analyzer-report` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-report` |

**Terraform Output:**
```bash
terraform output -json ecr_repository_urls
terraform output ecr_registry_url
```

**Docker Login:**
```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
```

---

## 7. EKS Cluster

**Cluster Name:** `arch-analyzer-<environment>`

**Kubernetes Version:** `1.30` (default, configurable)

**Node Group:**
- **Instance Types:** `t3.small` (default, configurable)
- **Desired Size:** 2 nodes
- **Min Size:** 1 node
- **Max Size:** 3 nodes (capped for Academy budget)

**Terraform Outputs:**
```bash
terraform output eks_cluster_name
terraform output eks_cluster_endpoint
terraform output eks_cluster_version
terraform output kubeconfig_command
```

**Configure kubectl:**
```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name arch-analyzer-dev
```

---

## 8. ALB (Application Load Balancer)

**DNS Name:** `<alb-dns-name>.us-east-1.elb.amazonaws.com`

**Terraform Output:**
```bash
terraform output alb_dns_name
```

**Ingress:** NGINX Ingress Controller (NodePort 30080)

**Access:** Via ALB DNS name → NGINX → Kubernetes services

---

## 9. Network

### 9.1 VPC

**CIDR:** `10.0.0.0/16` (default, configurable)

**Terraform Output:**
```bash
terraform output vpc_id
```

---

### 9.2 Public Subnets

**CIDRs:** `10.0.1.0/24`, `10.0.2.0/24` (default, configurable)

**Terraform Output:**
```bash
terraform output public_subnet_ids
```

---

### 9.3 Private Subnets

**CIDRs:** `10.0.3.0/24`, `10.0.4.0/24` (default, configurable)

**Terraform Output:**
```bash
terraform output private_subnet_ids
```

**Note:** RDS instances and MongoDB/Redis StatefulSets run in private subnets. No NAT Gateway (Academy cost constraint).

---

## 10. Retrieving Connection Strings at Runtime

### 10.1 From Terraform

```bash
# All database connection strings
terraform output -json db_instances

# Specific service
terraform output -json db_instances | jq '.registration'

# SQS URLs
terraform output sqs_processing_queue_url
terraform output sqs_dlq_url

# ECR repositories
terraform output -json ecr_repository_urls
```

---

### 10.2 From AWS CLI

```bash
# Get registration DB connection string from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id arch-analyzer/db/registration \
  --region us-east-1 \
  --query SecretString \
  --output text

# Get SQS queue URL
aws sqs get-queue-url \
  --queue-name arch-analyzer-processing-dev \
  --region us-east-1

# Get ECR repository URLs
aws ecr describe-repositories \
  --repository-names arch-analyzer-gateway \
  --region us-east-1 \
  --query 'repositories[0].repositoryUri'
```

---

### 10.3 From Kubernetes

```bash
# Get infra-outputs ConfigMap
kubectl get configmap infra-outputs -n arch-analyzer-api -o yaml

# Get database connection string from secret
kubectl get secret arch-analyzer-db-registration -n arch-analyzer-api -o jsonpath='{.data.connection-string}' | base64 -d

# Get pod environment variables
kubectl exec -it <pod-name> -n arch-analyzer-api -- env | grep -E "DB_|SQS_|ECR_"
```

---

## 11. Important Notes

### 11.1 Password Generation

- **Algorithm:** `random_password` resource with 24 characters
- **Special Characters:** `!#$%*-_+=` (excludes `/`, `@`, `'`, `"`, `;` for RDS/parser compatibility)
- **Sensitivity:** Marked as sensitive in Terraform; never echoed in plan output beyond standard treatment
- **Storage:** Injected into RDS at plan time; never stored in `terraform.tfvars`

### 11.2 SSL/TLS

- **RDS:** Encryption at rest enabled; SSL Mode=Require in connection strings
- **Trust Server Certificate:** Set to `true` for Academy labs (AWS RDS root CA); flip to `false` for production and mount CA bundle
- **SQS:** Denies plain HTTP; requires HTTPS

### 11.3 AWS Academy Constraints

- **LabRole:** Only usable role; no custom IAM roles can be created
- **KMS:** No customer-managed keys; uses AWS-managed keys (aws/secretsmanager, aws/sqs, aws/s3)
- **NAT Gateway:** Not provisioned (cost constraint); private subnets use VPC endpoints for AWS service access
- **Multi-AZ:** RDS single-AZ only (cost constraint)
- **Enhanced Monitoring:** Disabled on RDS (requires custom IAM role; Academy blocks `iam:CreateRole`)

### 11.4 Secrets Manager Contract

**BREAKING CHANGE (v2):**
- **Old:** `arch-analyzer/db/<svc>` stored as JSON `{"password":"..."}`
- **New:** `arch-analyzer/db/<svc>` stores the FULL connection string as raw text

**Why:** Eliminates string re-assembly in init containers; prevents Npgsql parse errors from stray newlines.

**Migration:** Update init containers to write the secret verbatim to disk (no JSON parsing).

---

## 12. Terraform Commands Reference

```bash
# Plan infrastructure
terraform plan -var-file=dev.tfvars

# Apply infrastructure
terraform apply -var-file=dev.tfvars

# Destroy infrastructure
terraform destroy -var-file=dev.tfvars

# Get all outputs
terraform output -json

# Get specific output
terraform output eks_cluster_name

# Refresh state
terraform refresh

# Validate configuration
terraform validate

# Format code
terraform fmt -recursive
```

---

## 13. Troubleshooting

### 13.1 Cannot Connect to RDS

**Symptom:** `psql: could not translate host name "..." to address: Name or service not known`

**Cause:** Pod is not in the same VPC or security group rules are blocking traffic.

**Fix:**
1. Verify pod is in private subnet (check node IP)
2. Verify RDS security group allows ingress from pod security group on port 5432
3. Verify pod has IAM permissions to read Secrets Manager

### 13.2 SQS Message Not Received

**Symptom:** `ReceiveMessage` returns empty list

**Cause:** Long polling timeout (20s) or queue is empty.

**Fix:**
1. Verify message was sent: `aws sqs get-queue-attributes --queue-url <url> --attribute-names ApproximateNumberOfMessages`
2. Check DLQ for failed messages: `aws sqs receive-message --queue-url <dlq-url>`
3. Verify pod has IAM permissions to read SQS

### 13.3 ECR Image Pull Fails

**Symptom:** `ImagePullBackOff` in pod events

**Cause:** Pod cannot authenticate to ECR or image does not exist.

**Fix:**
1. Verify image exists: `aws ecr describe-images --repository-name arch-analyzer-gateway`
2. Verify pod has IAM permissions to read ECR
3. Verify image tag is correct

---

## 14. Quick Reference Table

| Component | Endpoint | Port | Protocol | Namespace |
|-----------|----------|------|----------|-----------|
| **RDS (Registration)** | `<endpoint>` | 5432 | PostgreSQL + SSL | N/A (private subnet) |
| **RDS (Report)** | `<endpoint>` | 5432 | PostgreSQL + SSL | N/A (private subnet) |
| **RDS (Processing)** | `<endpoint>` | 5432 | PostgreSQL + SSL | N/A (private subnet) |
| **MongoDB** | `mongodb.data.svc.cluster.local` | 27017 | MongoDB | `data` |
| **Redis** | `redis.data.svc.cluster.local` | 6379 | Redis | `data` |
| **SQS (Processing)** | `https://sqs.us-east-1.amazonaws.com/...` | 443 | HTTPS | N/A (AWS service) |
| **SQS (DLQ)** | `https://sqs.us-east-1.amazonaws.com/...` | 443 | HTTPS | N/A (AWS service) |
| **ALB** | `<alb-dns>.us-east-1.elb.amazonaws.com` | 80/443 | HTTP/HTTPS | N/A (AWS service) |
| **NGINX Ingress** | `<alb-dns>` | 30080 | HTTP (NodePort) | `ingress-nginx` |
| **EKS API** | `<cluster-endpoint>` | 443 | HTTPS | N/A (AWS service) |
| **ECR** | `<account-id>.dkr.ecr.us-east-1.amazonaws.com` | 443 | HTTPS | N/A (AWS service) |

---

**End of Document**
