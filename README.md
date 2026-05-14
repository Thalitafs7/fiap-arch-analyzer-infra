# Arch Analyzer — Infrastructure as Code

Terraform monorepo for the **Arch Analyzer** solution. Provisions all AWS resources and the shared Kubernetes cluster bootstrap for the AWS Academy Learner Lab (`us-east-1`).

---

## Architecture Overview

```
Internet
    │ HTTP :80
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    VPC 10.0.0.0/16 (us-east-1)                      │
│                                                                      │
│  Public Subnet A (10.0.1.0/24)   Public Subnet B (10.0.2.0/24)     │
│  ┌──────────────────────────┐    ┌──────────────────────────┐       │
│  │  ALB (internet-facing)   │────│  ALB (internet-facing)   │       │
│  │  EKS Node (t3.small)     │    │  EKS Node (t3.small)     │       │
│  └──────────────────────────┘    └──────────────────────────┘       │
│                                                                      │
│  Private Subnet A (10.0.3.0/24)  Private Subnet B (10.0.4.0/24)    │
│  ┌──────────────────────────┐                                        │
│  │  RDS PostgreSQL 15       │  (db.t3.micro, single-AZ)             │
│  └──────────────────────────┘                                        │
│                                                                      │
│  S3 ←── VPC Gateway Endpoint (free, no NAT)                         │
│  SQS + DLQ  │  ECR  │  Secrets Manager  │  CloudWatch               │
└─────────────────────────────────────────────────────────────────────┘

EKS Workloads (inside nodes):
  namespace: ingress-nginx      → NGINX Ingress Controller (NodePort 30080)
  namespace: arch-analyzer-api  → api-gateway, registration-service
  namespace: arch-analyzer-ia   → processing-service, celery-worker, report-service
  namespace: auth               → auth-service
  namespace: data               → MongoDB 7 StatefulSet, Redis StatefulSet
```

**Key design decisions:**
- Nodes in **public subnets** — avoids NAT Gateway (~$32/mo per AZ)
- RDS in **private subnets** — no public accessibility
- **HTTP-only ALB** — ACM public cert DNS validation not available in Academy
- **LabRole reuse** — Academy blocks `iam:CreateRole`; no IRSA
- **MongoDB + Redis on EKS** — DocumentDB and ElastiCache restricted in Academy

---

## Repository Ownership

| Artifact | Owner |
|---|---|
| All AWS resources (VPC, EKS, RDS, SQS, S3, ECR, ALB, Secrets Manager, CloudWatch) | **This repo** |
| Shared k8s bootstrap (namespaces, NetworkPolicies, NGINX Ingress, MongoDB, Redis, Fluent Bit, CW Insights, `infra-outputs` ConfigMap) | **This repo** |
| Deployment_Orchestrator + Validator scripts | **This repo** |
| Per-service `k8s/` manifests | Each **Service_Repo** |

See [`docs/per-service-k8s-contract.md`](docs/per-service-k8s-contract.md) for the canonical contract every service repo must follow.

---

## Project Structure

```
fiap-arch-analyzer-infra/
├── main.tf                          # Root module wiring
├── variables.tf                     # Root variables
├── outputs.tf                       # Root outputs (eks_cluster_name, alb_dns_name, ecr_repository_urls)
├── provider.tf                      # AWS + Kubernetes + Helm providers (region locked to us-east-1)
├── terraform.tfvars.example         # Variable placeholders (NEVER commit terraform.tfvars)
├── .tflint.hcl                      # tflint configuration
│
├── modules/
│   ├── network/          # VPC, subnets, IGW, route tables, S3 Gateway Endpoint, VPC Flow Logs
│   ├── security/         # Security Groups (ALB, EKS nodes, RDS) — least-privilege by SG reference
│   ├── storage/          # S3 buckets (diagrams + access logs), SSE, versioning, bucket policies
│   ├── ecr/              # Private ECR repositories with scan-on-push
│   ├── messaging/        # SQS processing queue + DLQ, SSE-SQS, redrive policy
│   ├── database/         # RDS PostgreSQL 15, db.t3.micro, single-AZ, IAM auth
│   ├── eks/              # EKS cluster + managed node group (t3.small x2), CMK fallback
│   ├── alb/              # Internet-facing ALB, HTTP :80, NodePort 30080, access logs
│   ├── k8s-config/       # Namespaces, NetworkPolicies, NGINX Ingress Helm, infra-outputs ConfigMap
│   ├── secrets/          # AWS Secrets Manager secrets for all services
│   ├── observability/    # CloudWatch log groups, alarms, dashboard, Fluent Bit, CW Insights
│   ├── mongodb-on-eks/   # MongoDB 7 StatefulSet + ClusterIP Service in data namespace
│   └── redis-on-eks/     # Redis StatefulSet + ClusterIP Service in data namespace
│
├── scripts/
│   ├── deploy-all.config.yaml   # Declarative service list for the orchestrator
│   ├── deploy-all.ps1           # Deployment_Orchestrator (Windows PowerShell)
│   ├── deploy-all.sh            # Deployment_Orchestrator (Linux/macOS bash)
│   ├── validate.ps1             # Validator — health-checks all services via ALB (Windows)
│   ├── validate.sh              # Validator — health-checks all services via ALB (Linux/macOS)
│   ├── test-terraform.ps1       # Terraform static analysis: fmt + validate + tflint (Windows)
│   ├── test-terraform.sh        # Terraform static analysis: fmt + validate + tflint (Linux/macOS)
│   ├── test-kubeconform.ps1     # kubeconform manifest validation (Windows)
│   └── test-kubeconform.sh      # kubeconform manifest validation (Linux/macOS)
│
├── tests/
│   ├── properties/
│   │   ├── test_security_group_least_privilege.py  # Hypothesis PBT — Req 2.6
│   │   ├── test_terraform_idempotency.py           # Hypothesis PBT — Req 18.1
│   │   └── test_deployment_order.py                # Hypothesis PBT — Req 15.9
│   ├── smoke/
│   │   └── test_deploy_all_smoke.py                # Smoke tests — Req 15.1, 15.2
│   ├── e2e/
│   │   └── test_e2e_pipeline.py                    # E2E pipeline tests — Req 16.x
│   └── chaos/
│       └── test_pod_chaos.py                       # Chaos tests — Req 17.1, 17.2
│
└── docs/
    ├── per-service-k8s-contract.md   # Canonical k8s/ folder contract for service repos
    └── rollback-playbook.md          # Rollback procedures
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5.0 | Infrastructure provisioning |
| AWS CLI v2 | latest | Credential management, ECR login, kubeconfig |
| kubectl | >= 1.29 | Kubernetes manifest apply |
| helm | >= 3.14 | NGINX Ingress, Fluent Bit, CW Insights |
| Docker | latest | Image build + push |
| Python 3.11+ | latest | Orchestrator YAML parsing, tests |
| pyyaml | latest | YAML parsing in scripts |
| tflint | >= 0.50 | Terraform linting (CI) |
| kubeconform | >= 0.6 | Manifest validation (CI) |

---

## Quick Start — Full Stack Deployment

### 1. Configure credentials

```bash
# Copy and fill in your values (NEVER commit terraform.tfvars)
cp terraform.tfvars.example terraform.tfvars
```

Required values in `terraform.tfvars`:
- `lab_role_arn` — ARN of the LabRole from your Academy session
- `eks_public_access_cidrs` — your workstation IP (e.g. `["203.0.113.10/32"]`)
- `db_password`, `jwt_signing_key`, `mongo_password`, `redis_password`, `llm_api_keys`

### 2. Deploy everything (Windows)

```powershell
cd scripts
.\deploy-all.ps1
```

### 3. Deploy everything (Linux/macOS)

```bash
cd scripts
bash deploy-all.sh
```

The orchestrator will:
1. Validate all repo paths exist on disk
2. Verify AWS credentials (`aws sts get-caller-identity`)
3. Run `terraform init` + `terraform apply`
4. Update kubeconfig
5. Build and push all service images to ECR
6. Wait for MongoDB and Redis to be ready
7. Apply per-service manifests in dependency order
8. Run the Validator and write a report to `./artifacts/`

### 4. Manual Terraform-only deployment

```bash
terraform init
terraform plan
terraform apply

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name $(terraform output -raw eks_cluster_name)
```

---

## Shared `infra-outputs` ConfigMap

After `terraform apply`, the `k8s-config` module publishes a ConfigMap named **`infra-outputs`** into every application namespace (`arch-analyzer-api`, `arch-analyzer-ia`, `auth`). This is the **sole channel** through which service manifests learn AWS Terraform outputs.

| Key | Example value |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `AWS_ACCOUNT_ID` | `123456789012` |
| `CLUSTER_NAME` | `arch-analyzer-dev` |
| `ALB_DNS_NAME` | `arch-analyzer-dev-xxx.us-east-1.elb.amazonaws.com` |
| `DB_ADDRESS` | `arch-analyzer-dev.xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `archanalyzer` |
| `SQS_PROCESSING_QUEUE_URL` | `https://sqs.us-east-1.amazonaws.com/…` |
| `SQS_DLQ_URL` | `https://sqs.us-east-1.amazonaws.com/…` |
| `S3_DIAGRAMS_BUCKET` | `arch-analyzer-diagrams-dev-ab12cd` |
| `ECR_REGISTRY` | `123456789012.dkr.ecr.us-east-1.amazonaws.com` |
| `ECR_REPOSITORY_URL_GATEWAY` | `…/arch-analyzer-gateway` |
| `ECR_REPOSITORY_URL_AUTH` | `…/arch-analyzer-auth` |
| `ECR_REPOSITORY_URL_REGISTRATION` | `…/arch-analyzer-registration` |
| `ECR_REPOSITORY_URL_PROCESSING` | `…/arch-analyzer-processing` |
| `ECR_REPOSITORY_URL_REPORT` | `…/arch-analyzer-report` |

Service manifests consume it via:

```yaml
envFrom:
  - configMapRef:
      name: infra-outputs
```

**Service manifests MUST NOT embed literal AWS values.** The CI guardrail (`no-aws-literals` action) will fail any PR that does.

---

## Running Tests

```bash
# Install test dependencies
pip install pytest hypothesis pyyaml requests

# Property-based tests (no AWS required)
pytest tests/properties/ -v

# Smoke tests (no AWS required)
pytest tests/smoke/ -v

# E2E tests (requires ALB_DNS env var)
ALB_DNS=<alb-dns-name> pytest tests/e2e/ -v -m e2e

# Chaos tests (requires KUBECONFIG + kubectl)
pytest tests/chaos/ -v -m chaos

# Terraform static analysis
bash scripts/test-terraform.sh

# Kubernetes manifest validation
bash scripts/test-kubeconform.sh
```

---

## Terraform Outputs

| Output | Description |
|---|---|
| `eks_cluster_name` | EKS cluster name (used by orchestrator) |
| `eks_cluster_endpoint` | EKS API server URL |
| `alb_dns_name` | ALB DNS — application entry point |
| `ecr_repository_urls` | Map of ECR repository URLs keyed by service name |
| `db_endpoint` | RDS endpoint (host:port) |
| `db_address` | RDS hostname |
| `s3_diagrams_bucket` | Diagrams S3 bucket name |
| `sqs_processing_queue_url` | Processing queue URL |
| `sqs_dlq_url` | Dead-letter queue URL |
| `kubeconfig_command` | `aws eks update-kubeconfig …` command |

---

## Security Notes

- **Secrets Manager** — all sensitive credentials stored in AWS Secrets Manager; pods fetch them at startup via an init container using node-level LabRole credentials (IMDS)
- **No IRSA** — Academy blocks `iam:CreateRole`; pods use node instance profile
- **Least-privilege SGs** — EKS nodes only accept NodePort traffic from the ALB SG; RDS only accepts port 5432 from the EKS nodes SG
- **NetworkPolicies** — default-deny ingress in every application namespace; explicit allow-list per flow
- **No NAT Gateway** — nodes in public subnets; S3 traffic via VPC Gateway Endpoint
- **`terraform.tfvars` excluded from git** — `.gitignore` blocks `terraform.tfvars` and `*.tfstate*`

---

## Cost Estimate (AWS Academy)

| Resource | Spec | Est. $/mo |
|---|---|---|
| EKS Control Plane | Managed | ~$73 |
| EC2 EKS Nodes (×2) | t3.small | ~$30 |
| RDS PostgreSQL | db.t3.micro, single-AZ | ~$13 |
| ALB | HTTP listener | ~$16 |
| S3 + SQS + ECR | Moderate usage | ~$3 |
| **Total** | | **~$135/mo** |

> The EKS control plane (~$73/mo) is the main cost driver. Nodes in public subnets avoid NAT Gateway costs (~$32/mo per AZ).

---

## CI/CD

| Workflow | Trigger | Jobs |
|---|---|---|
| `infra-pr.yml` | PR → main | Terraform fmt/validate/tflint, kubeconform, property tests, smoke tests, Infracost |
| `infra-main.yml` | Push → main | Terraform plan → manual approval → apply → smoke tests |

Service repos each have a `k8s-validate.yml` workflow that runs kubeconform + the `no-aws-literals` guardrail on every PR.
