# Requirements Document

## Introduction

This document derives requirements from the approved `design.md` for the **AWS Academy Deployment** feature of the Arch Analyzer solution. The feature provisions a reproducible, budget-constrained AWS environment (VPC, EKS, RDS PostgreSQL, SQS, S3, ECR, ALB, Secrets Manager, CloudWatch) via Terraform in the `fiap-arch-analyzer-infra` monorepo and deploys the full microservice stack (api-gateway, auth-service, registration-service, processing-service + celery-worker, report-service, optional streamlit-ui, MongoDB, Redis) onto EKS, targeting the AWS Academy Learner Lab in `us-east-1`.

The design formalises a **repository-ownership split**: the Infra_Repo owns all AWS resources and the shared Kubernetes cluster bootstrap (namespaces, NetworkPolicies, NGINX Ingress Controller, MongoDB and Redis StatefulSets, Fluent Bit and CloudWatch Container Insights DaemonSets, and the shared per-namespace `infra-outputs` ConfigMap), plus the Deployment_Orchestrator and Validator scripts. Each Service_Repo owns its own top-level `k8s/` folder (Service_K8s_Folder) containing the per-service Kubernetes manifests, following the canonical layout of `fiap-arch-analyzer-auth-service/k8s/`. Service manifests never hardcode AWS Terraform outputs; they consume the Infra_Outputs_ConfigMap via `envFrom: configMapRef` or `valueFrom: configMapKeyRef`.

The requirements capture both the infrastructure contracts and the deployment automation contracts implied by the design, including the AWS Academy compatibility constraints (reuse of `LabRole`, no IRSA, HTTP-only ALB, USD 50-100 monthly budget) and the end-to-end validation and rollback flows.

## Glossary

- **Infra_Repo**: The `fiap-arch-analyzer-infra` Terraform monorepo; single source of truth for AWS infrastructure, shared Kubernetes bootstrap, Deployment_Orchestrator, and Validator.
- **Service_Repo**: Generic term for any of the five microservice repos — `fiap-arch-analyzer-api-gateway`, `fiap-arch-analyzer-auth-service`, `fiap-arch-analyzer-registration-service`, `fiap-arch-analyzer-processing-service` (which also hosts the `celery-worker` Deployment manifest), and `fiap-arch-analyzer-report-service`.
- **Service_K8s_Folder**: The top-level `k8s/` folder owned by a Service_Repo, containing that service's Kubernetes manifests (`deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, and optional `namespace.yaml` / `kustomization.yaml`). Canonical reference: `fiap-arch-analyzer-auth-service/k8s/`.
- **Infra_Outputs_ConfigMap**: The shared Kubernetes ConfigMap named `infra-outputs` published by the Infra_Repo `k8s-config` module into every application namespace. Sole channel through which Service_K8s_Folder manifests learn AWS Terraform outputs.
- **Learner_Lab**: AWS Academy Learner Lab account in `us-east-1` with ~4-hour session-credential lifetime and restricted IAM permissions.
- **LabRole**: Pre-provisioned IAM role available inside the Learner_Lab account; referenced by `lab_role_arn`.
- **Deployment_Orchestrator**: The `scripts/deploy-all.ps1` (Windows) and `scripts/deploy-all.sh` (Linux/macOS) bootstrap entry points, driven by the declarative service list in `scripts/deploy-all.config.yaml`.
- **Validator**: The `validateAll` health-check algorithm executed by the Deployment_Orchestrator and by `scripts/validate.ps1`.
- **EKS_Cluster**: The `arch-analyzer-dev` Amazon EKS cluster with a single managed node group on `t3.small` instances across two availability zones.
- **Ingress_Controller**: The NGINX Ingress Controller running inside EKS_Cluster on NodePort 30080.
- **ALB**: The Application Load Balancer fronting the Ingress_Controller, listening on port 80.
- **RDS_Instance**: The PostgreSQL 15 instance on `db.t3.micro`, single-AZ, in the private subnets.
- **MongoDB_Cluster**: MongoDB 7 StatefulSet running inside EKS_Cluster in the `data` namespace.
- **Redis_Cluster**: Redis StatefulSet running inside EKS_Cluster in the `data` namespace.
- **Secrets_Store**: AWS Secrets Manager plus the in-cluster secret-sync init container pattern described in the design.
- **Observability_Stack**: CloudWatch Logs groups, Fluent Bit DaemonSet, CloudWatch Container Insights agent, CloudWatch metric alarms, and the CloudWatch dashboard defined by the `observability` module.
- **Services**: The set `{api-gateway, auth-service, registration-service, processing-service, celery-worker, report-service}`; `streamlit-ui` is optional.
- **Service_Health_Endpoint**: `GET /health` on each application container and `GET /api/{service}/health` via ALB.
- **Diagrams_Bucket**: The private S3 bucket `arch-analyzer-diagrams-<env>-<suffix>` storing uploaded diagrams.
- **Access_Logs_Bucket**: The private S3 bucket storing ALB access logs and S3 server access logs.
- **Processing_Queue**: The SQS Standard queue `arch-analyzer-processing-<env>` used by registration-service to enqueue analysis jobs.
- **Processing_DLQ**: The SQS dead-letter queue receiving messages after `max_receive_count=3` failures on Processing_Queue.
- **Academy_Budget**: Default monthly cost ceiling of USD 100 for the deployed stack.

## Requirements

### Requirement 1: Network Topology

**User Story:** As an infrastructure engineer, I want a single-VPC, two-AZ network topology provisioned by Terraform, so that the EKS cluster and RDS instance have the subnets, routing, and endpoints required for the Arch Analyzer workload without incurring NAT Gateway costs.

#### Acceptance Criteria

1. WHEN `terraform apply` runs against a clean Learner_Lab account, THE `network` module SHALL create one VPC with CIDR `10.0.0.0/16` in `us-east-1`.
2. WHEN `terraform apply` runs, THE `network` module SHALL create two public subnets (`10.0.1.0/24` in `us-east-1a`, `10.0.2.0/24` in `us-east-1b`) and two private subnets (`10.0.3.0/24` in `us-east-1a`, `10.0.4.0/24` in `us-east-1b`).
3. WHEN `terraform apply` runs, THE `network` module SHALL attach one Internet Gateway to the VPC and associate public-subnet route tables with a `0.0.0.0/0` route via the Internet Gateway.
4. THE `network` module SHALL create one S3 Gateway VPC Endpoint associated with the private and public route tables.
5. THE `network` module SHALL NOT provision any NAT Gateway.
6. THE `network` module SHALL enable VPC Flow Logs to CloudWatch Logs with `LabRole` as the delivery role.
7. WHEN `terraform apply` runs, THE `network` module SHALL tag public subnets with `kubernetes.io/role/elb=1` and private subnets with `kubernetes.io/role/internal-elb=1` and `kubernetes.io/cluster/<cluster_name>=shared`.

### Requirement 2: Security Group Least Privilege

**User Story:** As a security reviewer, I want security groups restricted to the minimum required flows, so that the deployed environment exposes only the ALB to the internet and keeps all service-to-service traffic within referenced security groups.

#### Acceptance Criteria

1. THE `security` module SHALL create three security groups: `alb_security_group`, `eks_nodes_security_group`, and `rds_security_group`.
2. THE `alb_security_group` SHALL allow ingress on TCP port 80 only from the CIDR list in `alb_ingress_cidrs`.
3. THE `eks_nodes_security_group` SHALL allow ingress on TCP ports 30000-32767 only from `alb_security_group` by security-group reference.
4. THE `rds_security_group` SHALL allow ingress on TCP port 5432 only from `eks_nodes_security_group` by security-group reference.
5. IF `allowed_ssh_cidrs` is non-empty, THEN THE `eks_nodes_security_group` SHALL allow ingress on TCP port 22 from the supplied CIDR list.
6. FOR ALL security-group rules created by the Infra_Repo, THE `security` module SHALL reject any ingress rule with CIDR `0.0.0.0/0` unless the rule targets `alb_security_group` on port 80.
7. THE `eks_nodes_security_group` SHALL allow egress on TCP ports 80 and 443 to `0.0.0.0/0` for ECR pulls and AWS API calls.

### Requirement 3: Object Storage

**User Story:** As a platform operator, I want private S3 buckets for diagrams and access logs with enforced encryption and TLS, so that uploaded artifacts and audit logs remain confidential.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `storage` module SHALL create the Diagrams_Bucket with a unique suffix and block all public access.
2. WHEN `terraform apply` runs, THE `storage` module SHALL create the Access_Logs_Bucket with a unique suffix and block all public access.
3. THE Diagrams_Bucket SHALL have server-side encryption enabled using `aws:kms` when CMK creation succeeds, and SHALL fall back to `AES256` when CMK creation is denied.
4. THE Diagrams_Bucket SHALL have versioning enabled.
5. THE Diagrams_Bucket SHALL have a bucket policy that denies any request where `aws:SecureTransport` equals `false`.
6. THE Access_Logs_Bucket SHALL grant write access to the AWS ALB log-delivery principal scoped to the bucket ARN.
7. WHEN the `force_destroy` Terraform variable is `true`, THE `storage` module SHALL allow non-empty buckets to be deleted by `terraform destroy`.

### Requirement 4: Container Registry

**User Story:** As a developer, I want one private ECR repository per microservice with image scanning on push, so that container images are stored securely and vulnerabilities are detected early.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `ecr` module SHALL create one private ECR repository for each entry in `repository_names` (`arch-analyzer-gateway`, `arch-analyzer-auth`, `arch-analyzer-registration`, `arch-analyzer-processing`, `arch-analyzer-report`).
2. THE `ecr` module SHALL enable image scanning on push for every created repository.
3. THE `ecr` module SHALL expose `repository_urls` as a Terraform output keyed by repository name.
4. WHEN the `force_delete` Terraform variable is `true`, THE `ecr` module SHALL allow non-empty repositories to be deleted by `terraform destroy`.

### Requirement 5: Asynchronous Messaging

**User Story:** As a backend engineer, I want a Standard SQS queue with a dead-letter queue for the analysis pipeline, so that registration-service can decouple ingress from the LLM processing workflow with bounded retries.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `messaging` module SHALL create one Processing_Queue (Standard SQS) and one Processing_DLQ.
2. THE Processing_Queue SHALL set `visibility_timeout_seconds` to 600.
3. THE Processing_Queue SHALL set its `redrive_policy` to target Processing_DLQ with `max_receive_count` equal to 3.
4. THE Processing_Queue and Processing_DLQ SHALL have server-side encryption enabled using the SQS-managed key (SSE-SQS).
5. THE Processing_Queue SHALL have a queue policy that denies any request where `aws:SecureTransport` equals `false`.
6. THE `messaging` module SHALL expose `processing_queue_url`, `processing_queue_arn`, `dlq_url`, and `dlq_arn` as Terraform outputs.

### Requirement 6: Relational Database

**User Story:** As a backend engineer, I want a single-AZ RDS PostgreSQL 15 instance reachable only from EKS nodes, so that registration-service, processing-service, and report-service can persist relational data within the budget.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `database` module SHALL create an RDS PostgreSQL 15 instance on `db.t3.micro` with 20 GB of `gp3` storage in single-AZ mode.
2. THE RDS_Instance SHALL be placed in a DB subnet group composed of the two private subnets.
3. THE RDS_Instance SHALL have `publicly_accessible` set to `false`.
4. THE RDS_Instance SHALL have `storage_encrypted` set to `true`.
5. THE RDS_Instance SHALL have `iam_database_authentication_enabled` set to `true`.
6. THE RDS_Instance SHALL have `monitoring_interval` set to `0` because the Learner_Lab denies creation of `rds-monitoring-role`.
7. THE RDS_Instance SHALL have `backup_retention_period` set to 7 days.
8. THE RDS_Instance SHALL have `skip_final_snapshot` set to `true` in non-production environments.
9. THE `database` module SHALL expose `db_address`, `db_endpoint`, and `db_port` as Terraform outputs.

### Requirement 7: EKS Cluster and Managed Node Group

**User Story:** As a platform operator, I want an EKS cluster with a two-node managed node group using the LabRole, so that the Arch Analyzer workload runs on EKS without provisioning new IAM roles.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `eks` module SHALL create one EKS cluster named `arch-analyzer-<environment>` that references `lab_role_arn` as its cluster service role.
2. THE EKS_Cluster control plane SHALL have logging enabled for `api`, `audit`, and `authenticator` log types.
3. THE EKS_Cluster SHALL expose its public API endpoint only to the CIDR list in `eks_public_access_cidrs`.
4. THE `eks` module SHALL create one managed node group with `instance_types=["t3.small"]`, `desired_size=2`, `min_size=1`, and `max_size=5`.
5. THE managed node group SHALL reference `lab_role_arn` as the node IAM role.
6. THE managed node group SHALL attach the `eks_nodes_security_group` to its launch template.
7. IF CMK creation for envelope encryption fails with `AccessDenied`, THEN THE `eks` module SHALL fall back to `encryption_config.provider.key_arn = alias/aws/eks` when `use_aws_managed_kms=true`.
8. THE `eks` module SHALL expose `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority`, `cluster_security_group_id`, and `node_group_asg_names` as Terraform outputs.

### Requirement 8: Application Load Balancer

**User Story:** As an end user, I want a single ALB on port 80 forwarding to the NGINX Ingress Controller, so that I can reach every microservice through one stable DNS name within AWS Academy constraints.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `alb` module SHALL create one internet-facing Application Load Balancer spanning both public subnets.
2. THE ALB SHALL have one HTTP listener on port 80 forwarding to the NGINX Ingress target group.
3. THE ALB SHALL attach the NGINX Ingress target group to the ASGs in `node_group_asg_names` on NodePort 30080.
4. THE ALB target group SHALL perform HTTP health checks against `/healthz` on NodePort 30080 with a healthy threshold of 2 and an unhealthy threshold of 2.
5. THE ALB SHALL enable access logging to Access_Logs_Bucket under prefix `alb/`.
6. THE `alb` module SHALL expose `alb_dns_name`, `alb_arn`, and `target_group_arn` as Terraform outputs.
7. THE `alb` module SHALL NOT configure any HTTPS listener because ACM public certificates with DNS validation are not available in the Learner_Lab.

### Requirement 9: Kubernetes Namespaces and Shared Cluster Bootstrap

**User Story:** As a platform operator, I want Terraform to bootstrap only the shared Kubernetes primitives (namespaces, NetworkPolicies, ingress controller, and the shared `infra-outputs` ConfigMap) so that per-service manifests owned by the Service_Repos can plug into a stable cluster baseline without the Infra_Repo taking ownership of per-service workloads.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `k8s-config` module SHALL create the namespaces `arch-analyzer-api`, `arch-analyzer-ia`, `auth`, and `data`.
2. THE `k8s-config` module SHALL apply a default-deny ingress NetworkPolicy to each application namespace (`arch-analyzer-api`, `arch-analyzer-ia`, `auth`).
3. THE `k8s-config` module SHALL apply explicit allow NetworkPolicies matching the flows `ingress-controller → api-gateway`, `api-gateway → {auth, registration, processing, report}`, `processing → celery-worker`, and `{registration, processing, report} → data`.
4. THE `k8s-config` module SHALL install the NGINX Ingress Controller via Helm and expose it on NodePort 30080.
5. THE `k8s-config` module SHALL publish the Infra_Outputs_ConfigMap in each application namespace (`arch-analyzer-api`, `arch-analyzer-ia`, `auth`) carrying exactly the keys `AWS_REGION`, `AWS_ACCOUNT_ID`, `CLUSTER_NAME`, `ALB_DNS_NAME`, `DB_ADDRESS`, `DB_PORT`, `DB_NAME`, `SQS_PROCESSING_QUEUE_URL`, `SQS_DLQ_URL`, `S3_DIAGRAMS_BUCKET`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_GATEWAY`, `ECR_REPOSITORY_URL_AUTH`, `ECR_REPOSITORY_URL_REGISTRATION`, `ECR_REPOSITORY_URL_PROCESSING`, and `ECR_REPOSITORY_URL_REPORT`.
6. THE `k8s-config` module SHALL NOT create any per-service Deployment, Service, Ingress, HorizontalPodAutoscaler, or service-specific ConfigMap resource other than the shared bootstrap components listed in criteria 1–5 and the shared data stores declared in Requirements 11 and 12 and the observability agents declared in Requirement 13.

### Requirement 10: Secrets Management

**User Story:** As a security engineer, I want every sensitive credential stored in AWS Secrets Manager and synchronised into pods at start-up, so that no plaintext secret is committed to the repository or rendered in ConfigMaps.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `secrets` module SHALL create one AWS Secrets Manager secret for each of `arch-analyzer/db/registration`, `arch-analyzer/db/processing`, `arch-analyzer/db/report`, `arch-analyzer/auth/mongo`, `arch-analyzer/auth/jwt`, `arch-analyzer/redis/password`, and `arch-analyzer/llm/keys`.
2. THE `secrets` module SHALL declare `db_password`, `jwt_signing_key`, `mongo_password`, `redis_password`, and `llm_api_keys` as `sensitive=true` input variables.
3. FOR ALL pods owned by Services, THE pod spec SHALL include an init container that fetches the pod's secret from Secrets_Store using node-level `LabRole` credentials via IMDS and writes the value to an `emptyDir{medium: Memory}` volume.
4. FOR ALL pods owned by Services, THE pod spec SHALL set `automountServiceAccountToken` to `false`.
5. FOR ALL Kubernetes Secret resources created from `data.aws_secretsmanager_secret_version`, THE Terraform state backend SHALL be configured with encryption at rest.
6. IF a secret value written to Secrets_Store is rotated via `aws secretsmanager update-secret-version-stage`, THEN THE Deployment_Orchestrator SHALL support `kubectl rollout restart` to propagate the new value.
7. THE Infra_Repo `.gitignore` SHALL exclude `terraform.tfvars` and all files matching `*.tfstate*`.

### Requirement 11: MongoDB on EKS

**User Story:** As a backend engineer, I want a MongoDB StatefulSet deployed into the EKS cluster, so that auth-service can persist users and API keys without relying on DocumentDB (which is blocked in the Learner_Lab).

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `mongodb-on-eks` module SHALL deploy MongoDB 7 as a single-replica StatefulSet in the `data` namespace.
2. THE MongoDB_Cluster SHALL use a `gp3`-backed PersistentVolumeClaim sized `10Gi`.
3. THE MongoDB_Cluster root password SHALL be sourced from the `arch-analyzer/auth/mongo` secret via the secret-sync init container pattern.
4. THE MongoDB_Cluster SHALL expose a ClusterIP Service named `mongodb` on port 27017 within the `data` namespace.
5. THE MongoDB_Cluster SHALL reject connections from namespaces other than `auth` per the NetworkPolicy defined in the `k8s-config` module.

### Requirement 12: Redis on EKS

**User Story:** As a backend engineer, I want a Redis StatefulSet deployed into the EKS cluster, so that processing-service and celery-worker have a shared broker and SSE event bus without ElastiCache (which is restricted in the Learner_Lab).

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `redis-on-eks` module SHALL deploy Redis as a single-replica StatefulSet in the `data` namespace.
2. THE Redis_Cluster SHALL use a `gp3`-backed PersistentVolumeClaim sized `2Gi`.
3. THE Redis_Cluster password SHALL be sourced from the `arch-analyzer/redis/password` secret via the secret-sync init container pattern.
4. THE Redis_Cluster SHALL expose a ClusterIP Service named `redis` on port 6379 within the `data` namespace.
5. THE Redis_Cluster SHALL require `AUTH` for every client connection.

### Requirement 13: Observability Stack

**User Story:** As an operator, I want centralised logs, metrics, alarms, and a dashboard, so that I can troubleshoot EKS workloads against AWS Academy session constraints.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE `observability` module SHALL create the CloudWatch log groups `/aws/eks/arch-analyzer/app` and `/aws/eks/arch-analyzer/system` with 7-day retention.
2. THE `observability` module SHALL install the `aws-for-fluent-bit` DaemonSet via Helm to forward pod `stdout` and `stderr` to `/aws/eks/arch-analyzer/app`.
3. THE `observability` module SHALL install the CloudWatch Container Insights agent as a DaemonSet.
4. THE `observability` module SHALL create one `aws_cloudwatch_metric_alarm` for pod CPU utilisation exceeding 80% for 5 minutes.
5. THE `observability` module SHALL create one `aws_cloudwatch_metric_alarm` for node memory utilisation exceeding 85% for 5 minutes.
6. THE `observability` module SHALL create one `aws_cloudwatch_metric_alarm` for the ALB `HTTPCode_Target_5XX_Count` metric and one alarm for `ApproximateNumberOfMessagesVisible` on Processing_DLQ greater than 0.
7. THE `observability` module SHALL create one `aws_cloudwatch_dashboard` containing per-service widgets for CPU, memory, 5xx rate, and Processing_DLQ depth.
8. THE `observability` module SHALL expose `log_group_names` (map) and `alarm_arns` (list) as Terraform outputs.

### Requirement 14: Microservice Deployments, Services, and HPAs

**User Story:** As a developer, I want each microservice deployed through manifests that live in its own Service_Repo, following a shared contract, so that the stack is reachable via the ALB, scales within node capacity, and keeps AWS infrastructure values out of the service manifests.

#### Acceptance Criteria

1. FOR ALL Services, THE Kubernetes manifests for that Service SHALL live in the Service_K8s_Folder of the owning Service_Repo following the canonical layout of `fiap-arch-analyzer-auth-service/k8s/` (`deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, with optional `namespace.yaml` and optional `kustomization.yaml`).
2. FOR ALL Services, THE Deployment manifest SHALL define `replicas=2`, resource requests (`cpu=100m`, `memory=256Mi`), and resource limits (`cpu=500m`, `memory=512Mi`).
3. FOR ALL Services, THE Deployment manifest SHALL set `securityContext.runAsNonRoot=true`, `runAsUser=10000`, `fsGroup=10000`, and `capabilities.drop=[ALL]` on each application container.
4. FOR ALL Services, THE Deployment manifest SHALL reference a container image whose registry and repository are resolved from the Infra_Outputs_ConfigMap keys `ECR_REGISTRY` and `ECR_REPOSITORY_URL_*` for that service, with tag equal to the current `IMAGE_TAG` environment variable.
5. FOR ALL Services, THE Deployment manifest SHALL expose `livenessProbe` and `readinessProbe` as `GET /health` on the container port with `initialDelaySeconds=30` and `periodSeconds=10` for liveness and `initialDelaySeconds=5` and `periodSeconds=5` for readiness.
6. FOR ALL Services, THE Deployment manifest SHALL set `revisionHistoryLimit` to 5.
7. FOR ALL Services except `celery-worker`, THE manifests SHALL define a ClusterIP Service matching the Deployment selector on the service's listed port (`api-gateway=8080`, `auth-service=5002`, `registration-service=5002`, `processing-service=8000`, `report-service=8001`).
8. FOR ALL Services except `celery-worker`, THE manifests SHALL define one `Ingress` of class `nginx` routing `/api/<service>(/|$)(.*)` with `rewrite-target=/$2` and `X-Forwarded-Prefix=/api/<service>` to the service port.
9. FOR ALL Services except `celery-worker`, THE manifests SHALL define a `HorizontalPodAutoscaler` with `minReplicas=2`, `maxReplicas=5`, and CPU target utilisation of 70%.
10. THE `celery-worker` Deployment manifest SHALL live in the `fiap-arch-analyzer-processing-service` Service_K8s_Folder and SHALL NOT declare a Service, Ingress, or HorizontalPodAutoscaler.
11. THE `api-gateway` ConfigMap SHALL contain `ReverseProxy__Clusters__auth__Destinations__d1__Address=http://auth-service.auth.svc.cluster.local:5002`, `…registration…=http://registration-service.arch-analyzer-api.svc.cluster.local:5002`, `…processing…=http://processing-service.arch-analyzer-ia.svc.cluster.local:8000`, and `…report…=http://report-service.arch-analyzer-ia.svc.cluster.local:8001`.
12. FOR ALL Kubernetes Service resources defined by any Service_K8s_Folder, THE Service type SHALL NOT equal `LoadBalancer`.
13. FOR ALL Service_K8s_Folder manifests, THE manifests SHALL consume AWS Terraform output values (AWS region, account id, cluster name, ALB DNS, RDS address/port/name, SQS URLs, S3 bucket names, ECR registry, per-service ECR repository URL) exclusively through `envFrom: configMapRef: { name: infra-outputs }` or `valueFrom: configMapKeyRef: { name: infra-outputs, key: <KEY> }` and SHALL NOT embed these values as string literals.

### Requirement 15: Deployment Orchestrator

**User Story:** As an operator, I want a single idempotent bootstrap script that applies Terraform, builds and pushes images, applies each Service_K8s_Folder in dependency order driven by a declarative service list, and runs validation, so that I can deploy the full stack within one Learner_Lab session.

#### Acceptance Criteria

1. THE Deployment_Orchestrator SHALL read a declarative service list from `scripts/deploy-all.config.yaml` whose entries carry the fields `name`, `repo_path`, `dockerfile`, `build_context`, `k8s_dir` (default `k8s`), `ecr_key`, `namespace`, `container_port`, `ingress_path`, `health_path`, `deployments[]`, and optional `migrations`.
2. WHEN Deployment_Orchestrator starts, THE Deployment_Orchestrator SHALL validate that every declared `repo_path` and every declared `<repo_path>/<k8s_dir>` exists on disk and SHALL fail fast with a non-zero exit status when any path is missing.
3. WHEN Deployment_Orchestrator is executed, THE Deployment_Orchestrator SHALL verify that `aws sts get-caller-identity` returns a successful response before proceeding.
4. WHEN Deployment_Orchestrator is executed, THE Deployment_Orchestrator SHALL execute `terraform init` followed by `terraform apply -auto-approve` against the Infra_Repo root.
5. WHEN Deployment_Orchestrator is executed, THE Deployment_Orchestrator SHALL execute `aws eks update-kubeconfig --region us-east-1 --name <cluster_name>` using the `eks_cluster_name` Terraform output.
6. WHEN Deployment_Orchestrator builds images, THE Deployment_Orchestrator SHALL tag each image with the current `git_sha` and push it to the ECR repository URL resolved from the `ecr_key` declared for that service.
7. WHEN Deployment_Orchestrator applies the shared cluster bootstrap (namespaces, NetworkPolicies, NGINX Ingress Controller, MongoDB_Cluster, Redis_Cluster, Fluent Bit, CloudWatch Container Insights, Infra_Outputs_ConfigMap), THE Deployment_Orchestrator SHALL wait for `kubectl rollout status` success on MongoDB_Cluster and Redis_Cluster before proceeding to per-service application.
8. WHEN Deployment_Orchestrator applies per-service manifests, THE Deployment_Orchestrator SHALL prefer `kubectl apply -k <repo_path>/<k8s_dir>` when `kustomization.yaml` exists in that folder and SHALL fall back to `kubectl apply -f <repo_path>/<k8s_dir>/` otherwise.
9. WHEN Deployment_Orchestrator applies per-service manifests, THE Deployment_Orchestrator SHALL honour the stage order `[auth-service] → [registration-service, report-service, processing-service] → [api-gateway]`.
10. WHEN Deployment_Orchestrator transitions between stages, THE Deployment_Orchestrator SHALL block on `kubectl rollout status` for every Deployment listed in `services[].deployments[]` of the previous stage before starting the next stage.
11. WHEN Deployment_Orchestrator finishes applying manifests, THE Deployment_Orchestrator SHALL invoke Validator and write the report to `./artifacts/validation-report-<timestamp>.json` and `./artifacts/validation-report-<timestamp>.md`.
12. WHEN Validator reports at least one failing Service, THE Deployment_Orchestrator SHALL execute one automatic retry (pod restart or ConfigMap re-apply) and re-run Validator.
13. IF AWS credentials return an `ExpiredToken` error during execution, THEN THE Deployment_Orchestrator SHALL stop, log the error, and prompt the user to refresh Learner_Lab credentials before exiting with a non-zero status.
14. WHEN Deployment_Orchestrator is re-executed after a successful run with no code changes, THE Deployment_Orchestrator SHALL produce zero Terraform drift and zero Kubernetes rollout changes.

### Requirement 16: Health Validation

**User Story:** As an operator, I want a reusable validation routine that confirms every service is reachable via the ALB within a bounded time, so that deployment success is observable and automatable.

#### Acceptance Criteria

1. FOR ALL Services except `celery-worker`, THE Validator SHALL send `GET http://<alb_dns>/api/<service>/health` with a 5-second request timeout.
2. FOR ALL Services except `celery-worker`, THE Validator SHALL retry the request every 10 seconds until the response status equals 200 or until 5 minutes have elapsed.
3. WHEN Validator receives HTTP status 200 from a Service, THE Validator SHALL record that Service as `PASS` with the observed latency in milliseconds.
4. WHEN Validator exceeds 5 minutes of retries for a Service, THE Validator SHALL record that Service as `FAIL` with the last error message.
5. THE Validator SHALL set the overall report `overall` flag to `true` only when every recorded Service status equals `PASS`.
6. THE Validator SHALL emit the report as JSON and as Markdown to `./artifacts/`.

### Requirement 17: Rollback

**User Story:** As an operator, I want a documented rollback path for each failure class, so that I can recover from a bad deployment without destroying unrelated resources.

#### Acceptance Criteria

1. WHEN a Deployment's rollout introduces a failing image, THE operator documentation SHALL prescribe `kubectl rollout undo deployment/<name> -n <namespace>` as the rollback action.
2. FOR ALL Deployments defined by any Service_K8s_Folder, THE Deployment spec SHALL set `revisionHistoryLimit` to 5.
3. WHEN a ConfigMap change causes a Service to fail, THE operator documentation SHALL prescribe reverting the ConfigMap via Git and running `kubectl rollout undo`.
4. WHEN a Terraform apply fails mid-run, THE operator documentation SHALL prescribe re-running `terraform apply` because the operation is idempotent.
5. WHEN full teardown is required, THE Infra_Repo SHALL support `terraform destroy` with `force_destroy=true` on S3 buckets, `force_delete=true` on ECR repositories, and `skip_final_snapshot=true` on the RDS_Instance in non-production environments.

### Requirement 18: AWS Academy Compatibility

**User Story:** As a student, I want the deployment to work inside AWS Academy constraints without requiring denied IAM actions, so that the stack can be provisioned repeatedly during short-lived lab sessions.

#### Acceptance Criteria

1. FOR ALL IAM role references in the Infra_Repo, THE Terraform configuration SHALL reuse `LabRole` via the `lab_role_arn` variable and SHALL NOT invoke `aws_iam_role` or `aws_iam_policy` resources that create new roles.
2. THE Infra_Repo SHALL NOT provision an `aws_iam_openid_connect_provider` resource for the EKS cluster.
3. THE ALB listener SHALL use HTTP on port 80 and SHALL NOT require an ACM public certificate.
4. THE `database` module SHALL NOT reference `rds-monitoring-role`.
5. IF KMS CMK creation fails during `terraform apply`, THEN THE affected module SHALL accept a `use_aws_managed_kms=true` override that switches encryption to AWS-managed keys.
6. THE Infra_Repo SHALL target `us-east-1` in the provider configuration.
7. THE `eks` module SHALL default `eks_node_instance_types` to a Learner_Lab-whitelisted set containing `t3.small`.

### Requirement 19: Cost Ceiling

**User Story:** As a budget owner, I want the planned monthly infrastructure cost to stay within the Academy_Budget, so that lab accounts do not exceed their credit allowance.

#### Acceptance Criteria

1. THE Infra_Repo SHALL include an `infracost breakdown --path .` step in its CI pipeline.
2. WHEN Infracost reports a monthly cost greater than Academy_Budget, THE CI pipeline SHALL fail unless the pull request carries a `budget-exception` label.
3. THE default Terraform variables SHALL configure two `t3.small` nodes, one `db.t3.micro` RDS instance, one ALB, and 7-day CloudWatch log retention.
4. THE Infra_Repo documentation SHALL describe a teardown-per-session operating pattern that keeps monthly cost below USD 30 when labs run approximately 20 hours per week.

### Requirement 20: Data Model Invariants

**User Story:** As a data steward, I want domain-level validation rules to be enforced in the database schemas and S3 object keys, so that downstream consumers can rely on structural guarantees.

#### Acceptance Criteria

1. THE `registration.analysis` table SHALL enforce `CHECK (status IN ('queued','processing','done','error'))`.
2. WHEN the `registration.analysis.status` column transitions, THE registration-service domain logic SHALL allow only the transitions `queued → processing`, `processing → done`, and `processing → error`.
3. THE `processing.embeddings.embedding` column SHALL be typed as `vector(1536)` using the `vector` PostgreSQL extension.
4. THE `apiKeys.key_hash` values stored in MongoDB_Cluster SHALL be bcrypt hashes with cost factor greater than or equal to 10.
5. FOR ALL S3 object keys written to Diagrams_Bucket under the `diagrams/` prefix, THE registration-service SHALL enforce the pattern `^diagrams/[0-9a-f-]{36}\.(png|jpe?g|gif|webp|pdf)$`.

### Requirement 21: Testing Strategy

**User Story:** As a release engineer, I want unit, property-based, integration, and end-to-end tests wired into CI, so that regressions in infrastructure, manifests, and orchestration are detected before merge.

#### Acceptance Criteria

1. THE CI pipeline SHALL run `terraform validate` and `terraform fmt -check` for every module.
2. THE CI pipeline SHALL run `tflint` with the AWS plugin for every module.
3. THE CI pipeline SHALL run `kubeconform` (or `kubectl apply --dry-run=client`) against every Kubernetes manifest in the Infra_Repo and in every Service_K8s_Folder.
4. THE CI pipeline SHALL execute property-based tests implemented with `hypothesis` that assert the security-group least-privilege invariant, the Terraform apply idempotency invariant, and the deployment-order topological-sort invariant.
5. THE CI pipeline SHALL execute one smoke test that runs Deployment_Orchestrator against a disposable `arch-analyzer-smoke` environment and tears it down after Validator completes.
6. THE Infra_Repo SHALL include an end-to-end `pytest` test that submits a diagram via `/api/registration/diagrams`, polls `/api/analyses/{id}/status` until `done`, and fetches the final report via `/api/reports/{id}`.
7. THE Infra_Repo SHALL include a chaos test that deletes one random application pod and asserts the HPA restores the replica count within 60 seconds and that end-to-end p95 latency stays below 5 seconds during the disruption.

### Requirement 22: Repository Ownership Split

**User Story:** As a platform architect, I want a strict repository-ownership split between the Infra_Repo and the Service_Repos, so that AWS resources, shared cluster bootstrap, and per-service workloads each have a single authoritative owner and cross-repo drift is impossible.

#### Acceptance Criteria

1. THE Infra_Repo SHALL NOT contain any per-service Deployment, Service, Ingress, HorizontalPodAutoscaler, or service-specific ConfigMap manifest other than the shared bootstrap components enumerated in Requirement 9 (namespaces, default-deny and allow NetworkPolicies, NGINX Ingress Controller, Infra_Outputs_ConfigMap) and the shared data stores and agents enumerated in Requirements 11, 12, and 13 (MongoDB_Cluster, Redis_Cluster, Fluent Bit DaemonSet, CloudWatch Container Insights DaemonSet).
2. FOR ALL Service_Repos, THE Service_Repo SHALL contain a top-level `k8s/` folder (Service_K8s_Folder) with the files `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, and `aws-secret-template.yaml`; `service.yaml`, `ingress.yaml`, and `hpa.yaml` MAY be omitted only for the `celery-worker` manifest hosted inside `fiap-arch-analyzer-processing-service/k8s/`.
3. FOR ALL Service_Repos, THE Service_Repo SHALL NOT contain any AWS Terraform resource and SHALL NOT contain any shared-cluster Kubernetes resource (NetworkPolicy that affects other namespaces, cluster-wide Helm release, or shared data store).
4. FOR ALL Service_K8s_Folder manifests, THE manifests SHALL consume AWS Terraform output values (AWS region, account id, cluster name, ALB DNS, RDS address/port/name, SQS queue URLs, S3 bucket names, ECR registry, per-service ECR repository URL) exclusively through `envFrom: configMapRef: { name: infra-outputs }` or `valueFrom: configMapKeyRef: { name: infra-outputs, key: <KEY> }` and SHALL NOT embed those values as string literals.
5. WHEN a pull request in any Service_Repo introduces a YAML file under `k8s/` containing a string literal that matches an AWS URL (`*.amazonaws.com`), an RDS hostname (`*.rds.amazonaws.com`), an ECR registry (`<account_id>.dkr.ecr.<region>.amazonaws.com`), an S3 bucket name, or an SQS queue URL, THE Service_Repo CI pipeline SHALL fail that pull request.
6. THE Infra_Repo documentation SHALL publish the canonical `k8s/` layout of `fiap-arch-analyzer-auth-service/k8s/` as the contract every other Service_Repo MUST match.

### Requirement 23: Infra Outputs ConfigMap Contract

**User Story:** As a platform operator, I want a single, versioned ConfigMap contract through which Service_K8s_Folder manifests learn AWS Terraform outputs, so that rotating an AWS value never requires editing a Service_Repo and infrastructure stays the only writer of AWS values.

#### Acceptance Criteria

1. WHEN `terraform apply` runs, THE Infra_Repo `k8s-config` module SHALL create the Infra_Outputs_ConfigMap (a Kubernetes ConfigMap named `infra-outputs`) in every application namespace (`arch-analyzer-api`, `arch-analyzer-ia`, `auth`).
2. THE Infra_Outputs_ConfigMap SHALL expose exactly the keys `AWS_REGION`, `AWS_ACCOUNT_ID`, `CLUSTER_NAME`, `ALB_DNS_NAME`, `DB_ADDRESS`, `DB_PORT`, `DB_NAME`, `SQS_PROCESSING_QUEUE_URL`, `SQS_DLQ_URL`, `S3_DIAGRAMS_BUCKET`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_GATEWAY`, `ECR_REPOSITORY_URL_AUTH`, `ECR_REPOSITORY_URL_REGISTRATION`, `ECR_REPOSITORY_URL_PROCESSING`, and `ECR_REPOSITORY_URL_REPORT`.
3. FOR ALL values written into the Infra_Outputs_ConfigMap, THE `k8s-config` module SHALL store the value as a Kubernetes ConfigMap string and SHALL cast numeric Terraform outputs (for example `DB_PORT`) to string via `tostring(...)` before writing.
4. THE Infra_Outputs_ConfigMap SHALL carry the labels `app.kubernetes.io/part-of=arch-analyzer` and `app.kubernetes.io/managed-by=terraform`.
5. WHEN `terraform apply` re-runs with modified inputs that change any Infra_Outputs_ConfigMap value, THE Infra_Outputs_ConfigMap SHALL be updated in place in every application namespace.
6. WHEN the Infra_Outputs_ConfigMap is updated in place, THE Deployment_Orchestrator SHALL execute `kubectl rollout restart` on every Deployment that consumes the Infra_Outputs_ConfigMap via `envFrom` or `valueFrom` so that pods pick up the new values.
7. THE Infra_Outputs_ConfigMap SHALL be the sole Kubernetes channel through which Service_K8s_Folder manifests read AWS Terraform outputs; the `k8s-config` module SHALL NOT publish AWS Terraform outputs through any other ConfigMap, Secret, or inlined manifest consumed by Service_K8s_Folder pods.
