# Design Document: AWS Academy Deployment

## Overview

This feature defines the end-to-end deployment of the Arch Analyzer solution (API Gateway, Auth, Registration, Processing, Report services + optional Streamlit UI) onto AWS Academy Learner Lab using the `fiap-arch-analyzer-infra` Terraform monorepo as the source of truth for **all AWS resources and shared Kubernetes cluster bootstrap**, while **each microservice repo owns its own `k8s/` folder** containing the per-service Kubernetes manifests. The target topology is a single-VPC, two-AZ EKS cluster with RDS PostgreSQL, MongoDB (on-EKS), SQS, S3, ECR, an Application Load Balancer fronting the NGINX Ingress Controller, Secrets Manager, and CloudWatch.

The design accounts for AWS Academy constraints: reuse of `LabRole` (no IAM role creation), ~4h session-credential expiry, `us-east-1` region lock, restricted instance types, no public ACM/DNS validation, no KMS CMK creation in some labs, and a tight monthly budget (~USD 50-100). All infrastructure and shared cluster bootstrap are reproducible through `terraform apply` + infra-owned manifest application, followed by a bootstrap orchestrator that iterates the declared service repos, builds and pushes their images to ECR, applies each repo's `k8s/` manifests, waits for readiness, runs health checks, and emits a final validation report. Rollback is provided via `kubectl rollout undo` per Deployment and `terraform destroy -target` for infrastructure resources.

This spec is additive and organised around a **repository-ownership split**:

- The infra repo (`fiap-arch-analyzer-infra`) owns ALL AWS resources via Terraform (VPC, EKS, RDS, SQS, S3, ECR, ALB, Secrets Manager, CloudWatch) AND the shared Kubernetes cluster bootstrap: namespaces, default-deny + allow NetworkPolicies, NGINX Ingress Controller Helm release, MongoDB StatefulSet, Redis StatefulSet, Fluent Bit DaemonSet, CloudWatch Container Insights DaemonSet, the shared `infra-outputs` ConfigMap published per application namespace, and the Deployment_Orchestrator + Validator scripts. It reuses the `network`, `security`, `eks`, `database`, `messaging`, `storage`, `ecr`, `alb`, and `k8s-config` modules already present, and adds new modules for `secrets`, `observability`, `mongodb-on-eks`, and `redis-on-eks`.
- Each microservice repo (`fiap-arch-analyzer-api-gateway`, `fiap-arch-analyzer-auth-service`, `fiap-arch-analyzer-registration-service`, `fiap-arch-analyzer-processing-service` — which also contains the `celery-worker` Deployment manifest, `fiap-arch-analyzer-report-service`; optional `streamlit-ui` out of scope for first cut) owns its own `Dockerfile`, its database migrations (when applicable), and its `k8s/` folder containing `namespace.yaml` (only when the service owns a dedicated namespace not already bootstrapped by infra), `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, and `aws-secret-template.yaml` (for the secret-sync init container). The layout already present in `fiap-arch-analyzer-auth-service/k8s/` is the canonical contract every service repo must match.
- A cross-repo orchestrator script (`scripts/deploy-all.ps1` / `.sh`) lives in the infra repo and sequences Terraform, shared k8s bootstrap, per-service image builds, per-service `k8s/` applies, rollout waits, and validation.

---

## Architecture

This section corresponds to the **High-Level Design** view. It describes the context, AWS service mapping, request flows, deployment topology, and dependency graph.

### Context Diagram

```mermaid
graph TB
    Users[End Users / Browser / curl]
    Student[Student Workstation<br/>Terraform + kubectl + AWS CLI]

    subgraph AWS["AWS Academy Learner Lab (us-east-1)"]
        ALB[Application Load Balancer<br/>:80 HTTP]

        subgraph EKS["EKS Cluster (arch-analyzer-dev)"]
            Nginx[NGINX Ingress Controller<br/>NodePort 30080]
            Gateway[api-gateway<br/>.NET YARP]
            Auth[auth-service<br/>.NET 8]
            Reg[registration-service<br/>.NET 8]
            Proc[processing-service<br/>Python FastAPI]
            Worker[processing-worker<br/>Celery]
            Report[report-service<br/>Python FastAPI]
            Streamlit[streamlit-ui<br/>optional]
            Mongo[MongoDB<br/>StatefulSet]
            Redis[Redis<br/>StatefulSet]
        end

        RDS[(RDS PostgreSQL 15<br/>db.t3.micro)]
        SQS[SQS processing + DLQ]
        S3[S3 diagrams bucket]
        ECR[ECR repositories]
        Secrets[Secrets Manager]
        CWL[CloudWatch Logs]
    end

    Users -->|HTTP :80| ALB
    Student -->|terraform apply| AWS
    Student -->|docker push| ECR
    Student -->|kubectl apply| EKS

    ALB -->|NodePort 30080| Nginx
    Nginx -->|/api/gateway| Gateway
    Gateway -->|/api/auth| Auth
    Gateway -->|/api/registration| Reg
    Gateway -->|/api/analyses| Proc
    Gateway -->|/api/reports| Report

    Auth --> Mongo
    Reg --> RDS
    Reg -->|enqueue| SQS
    Proc -->|consume| SQS
    Proc --> RDS
    Proc --> Redis
    Worker --> Redis
    Worker --> RDS
    Worker --> S3
    Report --> RDS
    Streamlit --> Gateway

    EKS -.->|pull images| ECR
    EKS -.->|fetch secrets| Secrets
    EKS -.->|logs/metrics| CWL
    Proc -.->|upload diagrams| S3
```

### AWS Service Mapping

| Concern | AWS Service | Justification | Academy Fit |
|---|---|---|---|
| Container orchestration | EKS (managed) | Multi-service workload, HPA, rolling updates, NetworkPolicies | Allowed; control plane ~$73/mo is main cost driver |
| Worker nodes | EC2 via EKS Managed Node Group (`t3.small` x2) | Covers all services at idle; HPA scales to max 5 | Instance type whitelisted in Academy |
| Relational DB | RDS PostgreSQL 15 (`db.t3.micro`, single-AZ) | Shared by registration, processing, report | Allowed; Multi-AZ skipped for cost |
| Document DB | MongoDB 7 StatefulSet on EKS | DocumentDB requires IAM role creation (Academy blocks) | In-cluster avoids blocked service |
| Cache / broker | Redis StatefulSet on EKS | ElastiCache requires SG + IAM that Academy restricts | In-cluster keeps Celery + SSE cheap |
| Async queue | SQS Standard + DLQ | Decouples registration ingress from LLM pipeline | Allowed; SSE-SQS managed key (no CMK) |
| Object storage | S3 (private, SSE-S3 or aws:kms managed) | Diagram uploads + ALB access logs | Allowed; `aws:kms` falls back to `AES256` if CMK create fails |
| Container registry | ECR (per service) | Private, image scanning on push | Allowed |
| Ingress | ALB + NGINX Ingress (NodePort 30080) | HTTPS offloaded to ALB default cert if any, otherwise HTTP-only | Allowed; ACM public cert skipped |
| Secrets | AWS Secrets Manager + init-container sync | Academy blocks IRSA; init container uses LabRole node credentials via IMDS | Allowed |
| IAM | Reuse `LabRole` / `LabInstanceProfile` | Academy denies `iam:CreateRole`, `iam:CreatePolicy` | Hard constraint |
| Logs & metrics | CloudWatch Logs (Container Insights via Fluent Bit DaemonSet) | Centralized log groups per service, 7-day retention | Allowed |
| CI/CD | GitHub Actions → ECR → kubectl | Offloads build from lab; keeps session credentials short-lived | Requires `AWS_SESSION_TOKEN` in GH secrets |
| DNS / TLS | ALB DNS name, HTTP :80 only | Route53 hosted zones + ACM public certs restricted | Academy limitation documented |

### Request Flow 1: Authentication

```mermaid
sequenceDiagram
    participant U as User
    participant ALB
    participant NGX as NGINX Ingress
    participant GW as api-gateway
    participant AUTH as auth-service
    participant M as MongoDB

    U->>ALB: POST /api/auth/login {user,pass}
    ALB->>NGX: NodePort 30080
    NGX->>GW: /api/auth/login
    GW->>AUTH: POST /login
    AUTH->>M: find user + verify hash
    M-->>AUTH: user doc
    AUTH-->>GW: 200 {jwt}
    GW-->>NGX: 200 {jwt}
    NGX-->>ALB: 200
    ALB-->>U: 200 {jwt}
```

### Request Flow 2: Diagram Submission & Analysis Pipeline

```mermaid
sequenceDiagram
    participant U as User
    participant GW as api-gateway
    participant REG as registration-service
    participant S3
    participant SQS
    participant PROC as processing-service
    participant W as celery-worker
    participant RDS
    participant R as Redis

    U->>GW: POST /api/registration/diagrams (jwt, file)
    GW->>REG: POST /diagrams
    REG->>S3: PutObject(diagrams/{id}.png)
    REG->>RDS: INSERT analysis(status='queued')
    REG->>SQS: SendMessage({analysis_id, s3_key})
    REG-->>GW: 202 {analysis_id}
    GW-->>U: 202 {analysis_id}

    PROC->>SQS: ReceiveMessage (long poll)
    PROC->>R: enqueue celery task
    W->>R: dequeue
    W->>S3: GetObject
    W->>W: LLM vision + RAG
    W->>RDS: UPDATE analysis SET status='done', report=...
    W->>R: publish job:{id} event
```

### Request Flow 3: Report Retrieval

```mermaid
sequenceDiagram
    participant U as User
    participant GW as api-gateway
    participant REP as report-service
    participant RDS

    U->>GW: GET /api/reports/{analysis_id} (jwt)
    GW->>REP: GET /reports/{id}
    REP->>RDS: SELECT analysis + report
    RDS-->>REP: rows
    REP-->>GW: 200 {analysis, report}
    GW-->>U: 200
```

### Deployment Topology

```mermaid
graph TB
    subgraph VPC["VPC 10.0.0.0/16 (us-east-1)"]
        direction TB
        IGW[Internet Gateway]
        subgraph AZA["AZ us-east-1a"]
            PubA[Public 10.0.1.0/24]
            PrvA[Private 10.0.3.0/24]
        end
        subgraph AZB["AZ us-east-1b"]
            PubB[Public 10.0.2.0/24]
            PrvB[Private 10.0.4.0/24]
        end
        ALB[ALB in PubA + PubB]
        NodeA[EKS Node in PubA]
        NodeB[EKS Node in PubB]
        RDSA[RDS primary in PrvA]
        RDSGrp[DB Subnet Group PrvA + PrvB]
        S3EP[VPC Endpoint: S3 Gateway]
    end

    IGW --- PubA
    IGW --- PubB
    ALB --- NodeA
    ALB --- NodeB
    NodeA --- RDSA
    NodeB --- RDSA
    RDSA --- RDSGrp
    NodeA --- S3EP
    NodeB --- S3EP
```

Key decisions:
- **Nodes in public subnets** — avoids NAT Gateway (~USD 32/mo per AZ). Security enforced via SG (no inbound except ALB NodePort + optional SSH).
- **RDS in private subnets** — no public accessibility, ingress only from EKS node SG on :5432.
- **S3 Gateway Endpoint** — free; keeps S3 traffic off public internet and avoids NAT.
- **ALB across both public subnets** — two AZs required by ALB.
- **MongoDB + Redis on EKS** — StatefulSets with `gp3` EBS-backed PVCs, single replica (Academy budget).

### Dependency Graph & Deployment Order

```mermaid
graph LR
    subgraph INFRA["fiap-arch-analyzer-infra (AWS + shared k8s bootstrap)"]
        N[network] --> S[security]
        N --> STO[storage]
        N --> ECR
        N --> MSG[messaging]
        S --> DB[database/RDS]
        S --> EKS
        N --> EKS
        EKS --> K8SCFG[k8s-config<br/>namespaces + NetworkPolicies<br/>+ infra-outputs ConfigMap]
        STO --> K8SCFG
        MSG --> K8SCFG
        DB --> K8SCFG
        EKS --> ALB
        STO --> ALB
        K8SCFG --> NGX[NGINX Ingress<br/>Helm release]
        K8SCFG --> SEC[secrets sync]
        SEC --> MDB[mongodb StatefulSet]
        SEC --> RDZ[redis StatefulSet]
        K8SCFG --> OBS[Fluent Bit + CW Insights DS]
    end

    subgraph AUTHR["fiap-arch-analyzer-auth-service"]
        AUTHIMG[docker build<br/>+ ECR push]
        AUTHK8S[k8s/ apply]
        AUTHIMG --> AUTHK8S
    end

    subgraph REGR["fiap-arch-analyzer-registration-service"]
        REGIMG[docker build<br/>+ ECR push + migrations]
        REGK8S[k8s/ apply]
        REGIMG --> REGK8S
    end

    subgraph REPR["fiap-arch-analyzer-report-service"]
        REPIMG[docker build<br/>+ ECR push]
        REPK8S[k8s/ apply]
        REPIMG --> REPK8S
    end

    subgraph PROCR["fiap-arch-analyzer-processing-service"]
        PROCIMG[docker build<br/>+ ECR push]
        PROCK8S[k8s/ apply<br/>processing + celery-worker]
        PROCIMG --> PROCK8S
    end

    subgraph GWR["fiap-arch-analyzer-api-gateway"]
        GWIMG[docker build<br/>+ ECR push]
        GWK8S[k8s/ apply]
        GWIMG --> GWK8S
    end

    MDB --> AUTHK8S
    RDZ --> PROCK8S
    DB --> REGK8S
    DB --> REPK8S
    DB --> PROCK8S
    NGX --> AUTHK8S
    NGX --> REGK8S
    NGX --> REPK8S
    NGX --> PROCK8S
    NGX --> GWK8S

    AUTHK8S --> GWK8S
    REGK8S --> GWK8S
    PROCK8S --> GWK8S
    REPK8S --> GWK8S

    GWK8S --> ING[ingress wired end-to-end]
    ING --> HC[health validation report]
```

Stages:
1. **Infra repo — AWS**: `terraform apply` — network → security → storage → ECR → messaging → database → EKS → alb → k8s-config.
2. **Infra repo — shared k8s bootstrap**: namespaces + default-deny + allow NetworkPolicies, NGINX Ingress Controller Helm release, MongoDB StatefulSet, Redis StatefulSet, Fluent Bit DaemonSet, CloudWatch Container Insights DaemonSet, and the `infra-outputs` ConfigMap published in every application namespace.
3. **Per-service — build + push**: Deployment_Orchestrator iterates each service repo and runs `docker build` → ECR push (parallel where possible).
4. **Per-service — apply `k8s/`**: `kubectl apply -k <repo_path>/k8s` (or `-f <repo_path>/k8s/`) + `kubectl rollout status`, in dependency order: `auth-service` → `{registration-service, report-service, processing-service incl. celery-worker}` → `api-gateway`.
5. **Ingress wiring**: ALB target group attachment confirmed; per-service Ingress objects already applied by step 4.
6. **Validation**: Validator probes every service through the ALB and writes the report.

### Trust Boundaries and Data Flows

| Boundary | Crosses | Control |
|---|---|---|
| Internet → ALB | ALB SG allows :80 from `alb_ingress_cidrs` (configurable; `0.0.0.0/0` for lab) | Security group ingress rule |
| ALB → EKS nodes | ALB SG egress to node SG on 30000–32767 | Referenced SG rule (no CIDR) |
| EKS pod → EKS pod | NetworkPolicies per namespace (default-deny + allow-list) | `kubernetes.io/network-policy` |
| EKS node → RDS | node SG → RDS SG on :5432 | Referenced SG rule |
| EKS node → S3 | VPC Endpoint + bucket policy (project prefix only) | Endpoint policy |
| EKS node → SQS | HTTPS over internet; SQS queue policy denies insecure transport | Queue policy |
| EKS node → Secrets Manager | HTTPS over internet using LabRole node credentials | LabRole permissions |
| Student → EKS API | `eks_public_access_cidrs` restricted to student IP | EKS endpoint ACL |

---

## Repository Ownership Model

The solution is split across one infra monorepo and five microservice repos. This section is the authoritative ownership contract: every artifact type has **exactly one** owning repo.

### Repository Ownership Matrix

| Artifact | `infra` | `api-gateway` | `auth-service` | `registration-service` | `processing-service` | `report-service` |
|---|---|---|---|---|---|---|
| AWS VPC / subnets / routing / S3 Gateway Endpoint | ✅ | — | — | — | — | — |
| AWS Security Groups | ✅ | — | — | — | — | — |
| AWS EKS cluster + managed node group | ✅ | — | — | — | — | — |
| AWS RDS PostgreSQL | ✅ | — | — | — | — | — |
| AWS SQS (queue + DLQ) | ✅ | — | — | — | — | — |
| AWS S3 buckets (diagrams, access-logs) | ✅ | — | — | — | — | — |
| AWS ECR repositories | ✅ | — | — | — | — | — |
| AWS ALB + target group + listener | ✅ | — | — | — | — | — |
| AWS Secrets Manager secret definitions | ✅ | — | — | — | — | — |
| AWS CloudWatch log groups + alarms + dashboard | ✅ | — | — | — | — | — |
| Kubernetes namespaces | ✅ (shared bootstrap) | — | — | — | — | — |
| Default-deny + allow NetworkPolicies | ✅ | — | — | — | — | — |
| NGINX Ingress Controller Helm release | ✅ | — | — | — | — | — |
| MongoDB StatefulSet + Service + PVC | ✅ | — | — | — | — | — |
| Redis StatefulSet + Service + PVC | ✅ | — | — | — | — | — |
| Fluent Bit DaemonSet | ✅ | — | — | — | — | — |
| CloudWatch Container Insights DaemonSet | ✅ | — | — | — | — | — |
| Shared `infra-outputs` ConfigMap (per namespace) | ✅ | — | — | — | — | — |
| Deployment_Orchestrator + Validator scripts | ✅ | — | — | — | — | — |
| Helm charts (shared / cluster-level) | ✅ | — | — | — | — | — |
| Per-service `Dockerfile` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/namespace.yaml` (only if dedicated ns not bootstrapped by infra) | — | ✅ (opt) | ✅ | ✅ (opt) | ✅ (opt) | ✅ (opt) |
| Per-service `k8s/deployment.yaml` | — | ✅ | ✅ | ✅ | ✅ (incl. `celery-worker`) | ✅ |
| Per-service `k8s/service.yaml` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/ingress.yaml` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/hpa.yaml` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/configmap.yaml` (service-specific app config) | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/aws-secret-template.yaml` (init-container secret sync) | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Per-service `k8s/kustomization.yaml` (optional but recommended) | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| Database migrations | — | — | — | ✅ (EF) | ✅ (Alembic) | — |

### Key ownership rules

- **No AWS resource is defined outside the infra repo.** Service manifests MUST NOT reference AWS output values (e.g. queue URL, bucket name, RDS endpoint) directly; they consume the `infra-outputs` ConfigMap.
- **No shared-cluster resource is defined in a service repo.** A service repo MUST NOT publish NetworkPolicies that affect other services, MUST NOT install cluster-wide Helm charts, and MUST NOT deploy shared data stores.
- **`celery-worker` lives in `processing-service/k8s/`** as a sibling Deployment manifest (no Service, no Ingress, no HPA required by default but HPA on queue depth via KEDA is permitted as a future addition).
- **Namespaces**: the infra repo creates `arch-analyzer-api`, `arch-analyzer-ia`, `auth`, and `data`. A service repo MAY ship a `namespace.yaml` that is a no-op re-declaration for local dev (`kubectl apply` of an existing Namespace is idempotent) but MUST NOT diverge labels or annotations from the infra bootstrap.
- **Optional `streamlit-ui`** is out of scope for the first cut; when added, it follows the same per-service contract.

---

## Per-Service `k8s/` Folder Contract

Every microservice repo MUST ship a top-level `k8s/` folder. The reference implementation is `fiap-arch-analyzer-auth-service/k8s/` and is the canonical contract. This subsection is normative.

### Required files

| File | Required | Purpose |
|---|---|---|
| `deployment.yaml` | yes | Pod template + replicas + probes + secret-sync init container |
| `service.yaml` | yes | ClusterIP Service fronting the pods |
| `ingress.yaml` | yes (except `celery-worker`) | NGINX Ingress routing the service's `/api/<service>` path |
| `hpa.yaml` | yes (except `celery-worker`) | HorizontalPodAutoscaler on CPU |
| `configmap.yaml` | yes | Service-specific app config (framework env, non-sensitive keys) |
| `aws-secret-template.yaml` | yes | Template / documentation of the in-cluster `Secret` materialised by the init container |
| `namespace.yaml` | optional | Namespace declaration (idempotent re-declaration; authoritative definition lives in infra) |
| `kustomization.yaml` | recommended | Enables `kubectl apply -k k8s/` and per-environment overlays |

### Naming conventions

| Concern | Convention | Example (`auth-service`) |
|---|---|---|
| Namespace | `<domain>` (one of `arch-analyzer-api`, `arch-analyzer-ia`, `auth`) — bootstrapped by infra | `auth` |
| Deployment name | `<service-short>-api` for HTTP services, `<service-short>-worker` for workers | `ms-auth-api` |
| Service name | `<service-short>-service` | `ms-auth-service` |
| Ingress name | `<service-short>-ingress` | `auth-ingress` |
| ConfigMap name | `<service-short>-config` | `ms-auth-config` |
| Secret name (materialised by init container) | `<service-short>-secret` | `ms-auth-secret` |
| Container image | `<ecr_registry>/<ecr_repository>:<image_tag>` — both values read from `infra-outputs` ConfigMap | `…/arch-analyzer-auth:${IMAGE_TAG}` |
| Ingress path pattern | `/api/<service>(/|$)(.*)` with `rewrite-target: /$2` and `X-Forwarded-Prefix: /api/<service>` | `/api/auth(/|$)(.*)` |
| Container ports | `api-gateway=8080`, `auth=5002`, `registration=5002`, `processing=8000`, `report=8001` | `5002` |
| Health endpoint (container) | `GET /health` | `/health` |
| Health endpoint (through ALB) | `GET /api/<service>/health` | `/api/auth/health` |

### Required labels and annotations

Every Deployment, Service, and Ingress MUST carry:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: <service-short>
    app.kubernetes.io/part-of: arch-analyzer
    app.kubernetes.io/component: <api|worker|gateway>
```

Every Deployment pod template MUST include:

```yaml
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10000
    fsGroup: 10000
  containers:
    - name: <service-short>-api
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

### Consuming `infra-outputs` — no hardcoded AWS values

A service manifest MUST NOT embed literal Terraform outputs. It consumes the shared `infra-outputs` ConfigMap (created per namespace by the infra `k8s-config` module) through either mode:

**Mode A — import everything via `envFrom`** (preferred when the service needs the whole surface):

```yaml
containers:
  - name: ms-auth-api
    envFrom:
      - configMapRef: { name: infra-outputs }        # AWS_REGION, AWS_ACCOUNT_ID, CLUSTER_NAME, ALB_DNS_NAME, DB_ADDRESS, ...
      - configMapRef: { name: ms-auth-config }       # service-specific non-sensitive config
      - secretRef:    { name: ms-auth-secret }       # service-specific materialised secret
```

**Mode B — cherry-pick individual keys via `valueFrom`** (when the framework expects a specific env name):

```yaml
env:
  - name: AWS__Region
    valueFrom: { configMapKeyRef: { name: infra-outputs, key: AWS_REGION } }
  - name: AWS__QueueUrl
    valueFrom: { configMapKeyRef: { name: infra-outputs, key: SQS_PROCESSING_QUEUE_URL } }
  - name: S3__DiagramsBucket
    valueFrom: { configMapKeyRef: { name: infra-outputs, key: S3_DIAGRAMS_BUCKET } }
```

Either mode is acceptable; mixing is allowed. A service repo SHALL NOT inline the literal values.

### `kustomization.yaml` (recommended)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: auth
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - hpa.yaml
  - configmap.yaml
  - aws-secret-template.yaml
# namespace.yaml omitted when the namespace is bootstrapped by infra
commonLabels:
  app.kubernetes.io/part-of: arch-analyzer
images:
  - name: arch-analyzer-auth
    newName: ${ECR_REGISTRY}/arch-analyzer-auth
    newTag: ${IMAGE_TAG}
```

The orchestrator prefers `kubectl apply -k <repo>/k8s` when `kustomization.yaml` is present and falls back to `kubectl apply -f <repo>/k8s/` otherwise.

---

## Shared `infra-outputs` ConfigMap

The infra repo's `k8s-config` module publishes a **single ConfigMap named `infra-outputs`** into every application namespace (`arch-analyzer-api`, `arch-analyzer-ia`, `auth`, `data` when applicable). It is the sole channel through which service manifests learn AWS Terraform outputs; service repos MUST consume it and MUST NOT hardcode AWS values.

### Schema

| Key | Source (Terraform output) | Example |
|---|---|---|
| `AWS_REGION` | provider region | `us-east-1` |
| `AWS_ACCOUNT_ID` | `data.aws_caller_identity.current.account_id` | `123456789012` |
| `CLUSTER_NAME` | `module.eks.cluster_name` | `arch-analyzer-dev` |
| `ALB_DNS_NAME` | `module.alb.alb_dns_name` | `arch-analyzer-dev-*.us-east-1.elb.amazonaws.com` |
| `DB_ADDRESS` | `module.database.db_address` | `arch-analyzer-dev.xyz.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | `module.database.db_port` | `5432` |
| `DB_NAME` | `var.db_name` | `archanalyzer` |
| `SQS_PROCESSING_QUEUE_URL` | `module.messaging.processing_queue_url` | `https://sqs.us-east-1.amazonaws.com/…/arch-analyzer-processing-dev` |
| `SQS_DLQ_URL` | `module.messaging.dlq_url` | `https://sqs.us-east-1.amazonaws.com/…/arch-analyzer-processing-dlq-dev` |
| `S3_DIAGRAMS_BUCKET` | `module.storage.diagrams_bucket_id` | `arch-analyzer-diagrams-dev-ab12cd` |
| `ECR_REGISTRY` | `"${account_id}.dkr.ecr.${region}.amazonaws.com"` | `123456789012.dkr.ecr.us-east-1.amazonaws.com` |
| `ECR_REPOSITORY_URL_GATEWAY` | `module.ecr.repository_urls["arch-analyzer-gateway"]` | `…/arch-analyzer-gateway` |
| `ECR_REPOSITORY_URL_AUTH` | `module.ecr.repository_urls["arch-analyzer-auth"]` | `…/arch-analyzer-auth` |
| `ECR_REPOSITORY_URL_REGISTRATION` | `module.ecr.repository_urls["arch-analyzer-registration"]` | `…/arch-analyzer-registration` |
| `ECR_REPOSITORY_URL_PROCESSING` | `module.ecr.repository_urls["arch-analyzer-processing"]` | `…/arch-analyzer-processing` |
| `ECR_REPOSITORY_URL_REPORT` | `module.ecr.repository_urls["arch-analyzer-report"]` | `…/arch-analyzer-report` |

The ConfigMap is **rewritten on every `terraform apply`**; service pods read the current values on start. Rotating a value (e.g. new ALB DNS after a cluster rebuild) requires `kubectl rollout restart` of the consuming Deployments.

### Rendered manifest (example, namespace `auth`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: infra-outputs
  namespace: auth
  labels:
    app.kubernetes.io/part-of: arch-analyzer
    app.kubernetes.io/managed-by: terraform
data:
  AWS_REGION: "us-east-1"
  AWS_ACCOUNT_ID: "123456789012"
  CLUSTER_NAME: "arch-analyzer-dev"
  ALB_DNS_NAME: "arch-analyzer-dev-1234567890.us-east-1.elb.amazonaws.com"
  DB_ADDRESS: "arch-analyzer-dev.xyz.us-east-1.rds.amazonaws.com"
  DB_PORT: "5432"
  DB_NAME: "archanalyzer"
  SQS_PROCESSING_QUEUE_URL: "https://sqs.us-east-1.amazonaws.com/123456789012/arch-analyzer-processing-dev"
  SQS_DLQ_URL: "https://sqs.us-east-1.amazonaws.com/123456789012/arch-analyzer-processing-dlq-dev"
  S3_DIAGRAMS_BUCKET: "arch-analyzer-diagrams-dev-ab12cd"
  ECR_REGISTRY: "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  ECR_REPOSITORY_URL_GATEWAY: "123456789012.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-gateway"
  ECR_REPOSITORY_URL_AUTH: "123456789012.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-auth"
  ECR_REPOSITORY_URL_REGISTRATION: "123456789012.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-registration"
  ECR_REPOSITORY_URL_PROCESSING: "123456789012.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-processing"
  ECR_REPOSITORY_URL_REPORT: "123456789012.dkr.ecr.us-east-1.amazonaws.com/arch-analyzer-report"
```

### Terraform publishing pattern

```hcl
# modules/k8s-config/main.tf (fragment)
locals {
  app_namespaces = ["arch-analyzer-api", "arch-analyzer-ia", "auth"]
  infra_outputs = {
    AWS_REGION                     = var.aws_region
    AWS_ACCOUNT_ID                 = data.aws_caller_identity.current.account_id
    CLUSTER_NAME                   = var.cluster_name
    ALB_DNS_NAME                   = var.alb_dns_name
    DB_ADDRESS                     = var.db_address
    DB_PORT                        = tostring(var.db_port)
    DB_NAME                        = var.db_name
    SQS_PROCESSING_QUEUE_URL       = var.sqs_processing_queue_url
    SQS_DLQ_URL                    = var.sqs_dlq_url
    S3_DIAGRAMS_BUCKET             = var.s3_diagrams_bucket
    ECR_REGISTRY                   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    ECR_REPOSITORY_URL_GATEWAY     = var.ecr_repository_urls["arch-analyzer-gateway"]
    ECR_REPOSITORY_URL_AUTH        = var.ecr_repository_urls["arch-analyzer-auth"]
    ECR_REPOSITORY_URL_REGISTRATION= var.ecr_repository_urls["arch-analyzer-registration"]
    ECR_REPOSITORY_URL_PROCESSING  = var.ecr_repository_urls["arch-analyzer-processing"]
    ECR_REPOSITORY_URL_REPORT      = var.ecr_repository_urls["arch-analyzer-report"]
  }
}

resource "kubernetes_config_map" "infra_outputs" {
  for_each = toset(local.app_namespaces)
  metadata {
    name      = "infra-outputs"
    namespace = each.value
    labels = {
      "app.kubernetes.io/part-of"    = "arch-analyzer"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  data = local.infra_outputs
}
```

### Service-side consumption rule

Any service manifest referencing an AWS output value MUST do so through either `envFrom: configMapRef: { name: infra-outputs }` or `valueFrom: configMapKeyRef: { name: infra-outputs, key: <KEY> }`. CI MUST fail a service repo PR that embeds an AWS URL, RDS hostname, ECR registry, or bucket name as a literal.

---

## Components and Interfaces

This section corresponds to the **Low-Level Design** view. It defines every module, manifest, environment variable contract, and automation interface needed to deploy the solution.

### Terraform Module Composition

Root `main.tf` wiring (additions marked with `NEW`):

| Module | Inputs | Key Outputs | Depends On |
|---|---|---|---|
| `network` | `project_name`, `environment`, `vpc_cidr`, `public_subnet_cidrs`, `private_subnet_cidrs`, `lab_role_arn`, `cluster_name` | `vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids` | — |
| `security` | `vpc_id`, `vpc_cidr`, `allowed_ssh_cidrs`, `alb_ingress_cidrs` | `alb_security_group_id`, `eks_nodes_security_group_id`, `rds_security_group_id` | `network` |
| `storage` | `project_name`, `environment`, `force_destroy` | `diagrams_bucket_id`, `access_logs_bucket_id` | — |
| `ecr` | `project_name`, `environment`, `repository_names`, `force_delete` | `repository_urls` (map) | — |
| `messaging` | `project_name`, `environment` | `processing_queue_url`, `processing_queue_arn`, `dlq_url`, `dlq_arn` | — |
| `database` | `vpc_id`, `private_subnet_ids`, `rds_security_group_id`, `db_name`, `db_username`, `db_password`, `db_instance_class` | `db_address`, `db_endpoint`, `db_port` | `network`, `security` |
| `eks` | `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `eks_node_security_group_id`, `node_instance_types`, `lab_role_arn`, `public_access_cidrs` | `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority`, `cluster_security_group_id`, `node_group_asg_names` | `network`, `security` |
| `alb` | `vpc_id`, `public_subnet_ids`, `alb_security_group_id`, `node_group_asg_names`, `access_logs_bucket_id` | `alb_dns_name`, `alb_arn`, `target_group_arn` | `eks`, `storage` |
| `k8s-config` | `aws_region`, `db_address`, `db_name`, `sqs_processing_queue_url`, `sqs_dlq_url`, `s3_diagrams_bucket` | `namespaces` | `eks`, `messaging`, `storage`, `database` |
| `secrets` **NEW** | `project_name`, `environment`, `db_password`, `jwt_signing_key`, `mongo_password`, `redis_password`, `llm_api_keys` (map) | `secret_arns` (map) | — |
| `observability` **NEW** | `project_name`, `environment`, `cluster_name`, `log_retention_days` | `log_group_names` (map), `alarm_arns` (list) | `eks` |
| `mongodb-on-eks` **NEW** (Helm Bitnami or raw StatefulSet via `kubernetes_manifest`) | `namespace`, `storage_class`, `storage_size`, `root_password_secret_name` | `service_host`, `service_port` | `k8s-config`, `secrets` |
| `redis-on-eks` **NEW** (same pattern) | `namespace`, `storage_class`, `storage_size`, `password_secret_name` | `service_host`, `service_port` | `k8s-config`, `secrets` |

Root composition (snippet, additive):

```terraform
module "secrets" {
  source           = "./modules/secrets"
  project_name     = var.project_name
  environment      = var.environment
  db_password      = var.db_password
  jwt_signing_key  = var.jwt_signing_key
  mongo_password   = var.mongo_password
  redis_password   = var.redis_password
  llm_api_keys     = var.llm_api_keys # { OPENAI_API_KEY = "...", ANTHROPIC_API_KEY = "..." }
}

module "observability" {
  source             = "./modules/observability"
  project_name       = var.project_name
  environment        = var.environment
  cluster_name       = module.eks.cluster_name
  log_retention_days = 7
  depends_on         = [module.eks]
}

module "mongodb" {
  source                    = "./modules/mongodb-on-eks"
  namespace                 = "data"
  storage_size              = "10Gi"
  root_password_secret_name = "mongodb-root-password"
  depends_on                = [module.k8s_config, module.secrets]
}

module "redis" {
  source                 = "./modules/redis-on-eks"
  namespace              = "data"
  storage_size           = "2Gi"
  password_secret_name   = "redis-password"
  depends_on             = [module.k8s_config, module.secrets]
}
```

### Kubernetes Manifests per Microservice

Per the Repository Ownership Matrix, **per-service Kubernetes manifests (`deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, and optional `namespace.yaml` / `kustomization.yaml`) live in each microservice repo's own `k8s/` folder**, not in the infra repo. The shape, naming conventions, labels, security context, and `infra-outputs` consumption rules are defined normatively in the *Per-Service `k8s/` Folder Contract* and *Shared `infra-outputs` ConfigMap* sections above. The reference implementation is `fiap-arch-analyzer-auth-service/k8s/`.

The worked example below (auth-service) is shown here as an **illustrative composition** of the contract — it is the shape a service repo's `k8s/` folder renders to, not a manifest the infra repo ships. The same shape applies to: `api-gateway` (namespace `arch-analyzer-api`, port 8080), `registration-service` (namespace `arch-analyzer-api`, port 5002), `processing-service` (namespace `arch-analyzer-ia`, port 8000, with a sibling `celery-worker` Deployment — no Service, no Ingress), and `report-service` (namespace `arch-analyzer-ia`, port 8001).

```yaml
# Lives in fiap-arch-analyzer-auth-service/k8s/ (NOT in infra repo)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ms-auth-api
  namespace: auth
  labels:
    app.kubernetes.io/name: auth-service
    app.kubernetes.io/part-of: arch-analyzer
    app.kubernetes.io/component: api
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels: { app: ms-auth-api }
  template:
    metadata:
      labels: { app: ms-auth-api }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10000
        fsGroup: 10000
      initContainers:
        - name: secrets-sync
          image: amazon/aws-cli:2.15.0
          command: ["/bin/sh","-c"]
          args:
            - |
              aws secretsmanager get-secret-value --secret-id arch-analyzer/auth/mongo \
                --region $AWS_REGION --query SecretString --output text > /secrets/mongo.json
          envFrom:
            - configMapRef: { name: infra-outputs }   # provides AWS_REGION, AWS_ACCOUNT_ID
          volumeMounts:
            - { name: secrets, mountPath: /secrets }
      containers:
        - name: ms-auth-api
          image: arch-analyzer-auth:${IMAGE_TAG}       # rewritten by kustomize to {ECR_REGISTRY}/arch-analyzer-auth:${IMAGE_TAG}
          ports: [{ containerPort: 5002 }]
          envFrom:
            - configMapRef: { name: infra-outputs }    # AWS values (region, account, ALB DNS, ECR, DB, SQS, S3)
            - configMapRef: { name: ms-auth-config }   # service-specific non-sensitive config
            - secretRef:    { name: ms-auth-secret }   # materialised by secret-sync
          env:
            - name: MongoDb__ConnectionString
              valueFrom: { secretKeyRef: { name: ms-auth-secret, key: MONGO_CONNECTION_STRING } }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          livenessProbe:
            httpGet: { path: /health, port: 5002 }
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /health, port: 5002 }
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: secrets, mountPath: /secrets, readOnly: true }
      volumes:
        - { name: secrets, emptyDir: { medium: Memory } }
---
apiVersion: v1
kind: Service
metadata: { name: ms-auth-service, namespace: auth }
spec:
  selector: { app: ms-auth-api }
  ports: [{ port: 5002, targetPort: 5002 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: auth-ingress
  namespace: auth
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api/auth(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: ms-auth-service
                port: { number: 5002 }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: ms-auth-hpa, namespace: auth }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: ms-auth-api }
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: ms-auth-config, namespace: auth }
data:
  ASPNETCORE_ENVIRONMENT: Production
  MongoDb__DatabaseName: arch-analyzer-auth
  MongoDb__ApiKeysCollectionName: apiKeys
```

Same shape applied in each of the other service repos: `fiap-arch-analyzer-api-gateway/k8s/`, `fiap-arch-analyzer-registration-service/k8s/`, `fiap-arch-analyzer-processing-service/k8s/` (with a sibling `celery-worker` Deployment manifest), and `fiap-arch-analyzer-report-service/k8s/`.

### Environment Variables Contract

| Service | Variable | Source | Example |
|---|---|---|---|
| api-gateway | `ReverseProxy__Clusters__auth__Destinations__d1__Address` | ConfigMap | `http://auth-service.auth.svc.cluster.local:5002` |
| api-gateway | `ReverseProxy__Clusters__registration__...` | ConfigMap | `http://registration-service.arch-analyzer-api.svc.cluster.local:5002` |
| api-gateway | `ReverseProxy__Clusters__processing__...` | ConfigMap | `http://processing-service.arch-analyzer-ia.svc.cluster.local:8000` |
| api-gateway | `ReverseProxy__Clusters__report__...` | ConfigMap | `http://report-service.arch-analyzer-ia.svc.cluster.local:8001` |
| auth-service | `MongoDb__ConnectionString` | Secret (synced from Secrets Manager `arch-analyzer/auth/mongo`) | `mongodb://root:***@mongodb.data.svc.cluster.local:27017` |
| auth-service | `Security__XInternalKey` | Secret | generated per env |
| auth-service | `Jwt__Key` | Secret (shared with registration) | 64-byte random |
| registration-service | `ConnectionStrings__DefaultConnection` | Secret (Secrets Manager `arch-analyzer/db/registration`) | `Host=<rds>;Port=5432;Database=archanalyzer;Username=registration;Password=***` |
| registration-service | `Jwt__Key` | Secret (shared) | — |
| registration-service | `AWS__Region` | ConfigMap | `us-east-1` |
| registration-service | `AWS__QueueUrl` | ConfigMap (from TF output) | `https://sqs.us-east-1.amazonaws.com/<acct>/arch-analyzer-processing-dev` |
| registration-service | `S3__DiagramsBucket` | ConfigMap | `arch-analyzer-diagrams-dev-xxxx` |
| processing-service | `POSTGRES_CONNECTION_STRING` | Secret | `postgresql+psycopg://processing:***@<rds>:5432/archanalyzer` |
| processing-service | `SQS_QUEUE_URL` | ConfigMap | from TF output |
| processing-service | `S3_BUCKET_NAME` | ConfigMap | from TF output |
| processing-service | `REDIS_URL` | ConfigMap | `redis://:***@redis.data.svc.cluster.local:6379/0` |
| processing-service | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | Secret (`arch-analyzer/llm/keys`) | user-provided at bootstrap |
| processing-service | `AWS_REGION` | ConfigMap | `us-east-1` |
| celery-worker | same as processing-service | same | same |
| report-service | `POSTGRES_CONNECTION_STRING` | Secret (`arch-analyzer/db/report` — read-only role) | `postgresql+psycopg://report:***@<rds>:5432/archanalyzer` |
| All services | `AWS_REGION`, `ENVIRONMENT` | ConfigMap | `us-east-1`, `dev` |

### Secrets Strategy

AWS Academy blocks IAM role creation → **IRSA is out of scope**. Approach:

1. **Single source of truth**: `aws_secretsmanager_secret` per logical secret, written by Terraform `secrets` module. Paths:
   - `arch-analyzer/db/registration`
   - `arch-analyzer/db/processing`
   - `arch-analyzer/db/report`
   - `arch-analyzer/auth/mongo`
   - `arch-analyzer/auth/jwt`
   - `arch-analyzer/redis/password`
   - `arch-analyzer/llm/keys`
2. **Pod sync**: init container (`amazon/aws-cli:2.15.0`) runs `aws secretsmanager get-secret-value` using the node-level instance profile (LabRole on EKS worker ENIs via IMDS). Output written to `emptyDir{medium: Memory}` volume shared with the app container.
3. **Kubernetes Secret mirroring** (simpler fallback for dev): `kubernetes_secret` resources created by Terraform at apply time, populated from `data.aws_secretsmanager_secret_version`. Trade-off: secret value becomes part of tfstate → must be stored encrypted (S3 backend + `aws:kms` or local with restricted ACL).
4. **Noted alternative**: External Secrets Operator (ESO) with `ClusterSecretStore` using `jwt` auth is preferable for prod but requires ServiceAccount → IRSA. Documented as future work; not executed under Academy.
5. **Plaintext-free guarantees**: `db_password`, `jwt_signing_key`, `llm_api_keys` declared as `sensitive = true`; `.gitignore` blocks `terraform.tfvars` and `*.tfstate*`; Secrets Manager is the only persistent plaintext sink (required).

### Networking — Security Group Rules Matrix

| Source | Destination | Port | Protocol | Rule type | Current module |
|---|---|---|---|---|---|
| `alb_ingress_cidrs` (e.g. `0.0.0.0/0` for lab) | ALB SG | 80 | TCP | CIDR ingress | `security` |
| ALB SG | EKS node SG | 30000–32767 | TCP | SG ref ingress | `security` |
| ALB SG | EKS cluster SG | 30000–32767 | TCP | SG ref ingress | `main.tf` root |
| EKS node SG | EKS node SG | all | all | SG self ingress (pod ↔ pod) | EKS-managed cluster SG |
| EKS node SG | RDS SG | 5432 | TCP | SG ref ingress | `security` |
| EKS node SG | Internet | 443 | TCP | CIDR egress | `security` (all outbound) |
| EKS node SG | Internet | 80 | TCP | CIDR egress | allowed for ECR pull fallback |
| `allowed_ssh_cidrs` | EKS node SG | 22 | TCP | CIDR ingress (optional) | `security` |
| RDS SG | VPC CIDR | all | all | CIDR egress | `security` |
| (none) | ALB SG | anything other than :80 | — | **denied** | default |

**Least-privilege invariant**: no `0.0.0.0/0` ingress anywhere except ALB :80. Verified by a post-apply Terraform `check` block or a property test (see Correctness Properties).

### IAM Strategy under AWS Academy

| Concern | Prod approach | Academy approach |
|---|---|---|
| EKS cluster role | Dedicated `eks-cluster-role` | Reuse `LabRole` via `lab_role_arn` |
| EKS node role | Dedicated `eks-node-role` with `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy` | Reuse `LabRole` (pre-attached policies cover required actions) |
| Pod identities | IRSA via OIDC provider + per-SA role | **Not available**: OIDC provider requires `iam:CreateOpenIDConnectProvider` → denied. Falls back to node-level `LabRole` credentials via IMDS. All pods inherit node permissions; isolation enforced at K8s layer (NetworkPolicies, Secrets Manager path ACLs effectively scoped by naming convention only). |
| VPC Flow Logs role | Dedicated role | Reuse `LabRole` (already in `network` module) |
| RDS enhanced monitoring | `rds-monitoring-role` | Disabled (Academy blocks creation) |

The tradeoff: every pod on the cluster has the same AWS permissions. Mitigation: strict namespace isolation, default-deny NetworkPolicies, and least-privilege Secrets Manager naming (e.g. `auth-service` can read any secret under `arch-analyzer/*`, but RBAC on namespaces keeps the secret-sync init container scoped per deployment).

### Observability

```mermaid
graph TB
    subgraph K8s
        App[app pods]
        FB[fluent-bit DaemonSet]
        CWA[cloudwatch-agent DaemonSet<br/>Container Insights]
    end
    App -->|stdout/stderr| FB
    FB -->|PutLogEvents| CWL1[Log Group: /aws/eks/arch-analyzer/app]
    CWA -->|PutMetricData| CW[CloudWatch Metrics]
    CW --> Alarm1[Alarm: pod_cpu > 80% 5m]
    CW --> Alarm2[Alarm: node_mem > 85% 5m]
    CWL1 --> Alarm3[Metric filter: ERROR count > 10/min]
```

| Resource | Config | Terraform |
|---|---|---|
| `/aws/eks/arch-analyzer/app` | retention 7 d | `observability` |
| `/aws/eks/arch-analyzer/system` | retention 7 d | `observability` |
| `/aws/eks/arch-analyzer/cluster` (control plane) | already created by `eks` module | — |
| Fluent Bit DaemonSet | Helm chart `aws-for-fluent-bit` | `observability` |
| CloudWatch Agent DaemonSet (Container Insights) | `amazon-cloudwatch-observability` Helm chart or manifest | `observability` |
| Alarms | `aws_cloudwatch_metric_alarm` for CPU, memory, 5xx rate on ALB target group, SQS DLQ depth > 0 | `observability` |
| Dashboards | One `aws_cloudwatch_dashboard` with per-service widgets | `observability` |

### Health Checks

| Level | Check | Expected |
|---|---|---|
| Container liveness | `GET /health` → 200 | Kubelet restarts on failure |
| Container readiness | `GET /health` → 200 | Pod removed from Service endpoints on failure |
| ALB target group | `GET /healthz` on NodePort 30080 (NGINX health endpoint) | 200 → target `healthy` |
| End-to-end (bootstrap validator) | `GET http://{alb_dns}/api/{service}/health` per service → 200 | Validator marks service `PASS` |
| Deep probe (optional) | `GET /api/registration/health/ready` verifies DB + SQS reachability | 200 → fully ready |

### Deployment Automation

Bootstrap orchestration script (`scripts/deploy-all.ps1` on Windows, `scripts/deploy-all.sh` on Linux/macOS) lives in the infra repo. Single entry point; idempotent; re-runnable after credential refresh. It is **repo-aware**: it reads a declarative service list from the orchestrator config and drives each service repo through build → push → `kubectl apply k8s/` → rollout wait, in a fixed topological order.

#### Orchestrator config (`scripts/deploy-all.config.yaml`)

```yaml
aws_region: us-east-1
tf_vars_path: ./terraform.tfvars
git_sha_strategy: short            # or "fixed" with git_sha override
stages:
  - [auth-service]
  - [registration-service, report-service, processing-service]
  - [api-gateway]
services:
  - name: auth-service
    repo_path: ../fiap-arch-analyzer-auth-service
    dockerfile: Dockerfile
    build_context: .
    k8s_dir: k8s                   # default
    ecr_key: arch-analyzer-auth
    namespace: auth
    container_port: 5002
    ingress_path: /api/auth
    health_path: /api/auth/health
    deployments:                   # rollout targets to wait on
      - ms-auth-api
  - name: registration-service
    repo_path: ../fiap-arch-analyzer-registration-service
    dockerfile: Dockerfile
    build_context: .
    k8s_dir: k8s
    ecr_key: arch-analyzer-registration
    namespace: arch-analyzer-api
    container_port: 5002
    ingress_path: /api/registration
    health_path: /api/registration/health
    migrations:
      command: ["dotnet", "ef", "database", "update"]
    deployments:
      - registration-service
  - name: report-service
    repo_path: ../fiap-arch-analyzer-report-service
    dockerfile: Dockerfile
    build_context: .
    k8s_dir: k8s
    ecr_key: arch-analyzer-report
    namespace: arch-analyzer-ia
    container_port: 8001
    ingress_path: /api/reports
    health_path: /api/reports/health
    deployments:
      - report-service
  - name: processing-service
    repo_path: ../fiap-arch-analyzer-processing-service
    dockerfile: Dockerfile
    build_context: .
    k8s_dir: k8s
    ecr_key: arch-analyzer-processing
    namespace: arch-analyzer-ia
    container_port: 8000
    ingress_path: /api/analyses
    health_path: /api/analyses/health
    deployments:
      - processing-service
      - celery-worker                # worker Deployment manifest lives in this repo's k8s/
  - name: api-gateway
    repo_path: ../fiap-arch-analyzer-api-gateway
    dockerfile: Dockerfile
    build_context: .
    k8s_dir: k8s
    ecr_key: arch-analyzer-gateway
    namespace: arch-analyzer-api
    container_port: 8080
    ingress_path: /api/gateway
    health_path: /api/gateway/health
    deployments:
      - api-gateway
```

Pseudocode (structured):

```pascal
ALGORITHM deployAll(config)
INPUT:  config (aws_region, tf_vars_path, git_sha, stages[][], services[])
         where services[i] has: name, repo_path, dockerfile, build_context,
                                 k8s_dir, ecr_key, namespace, container_port,
                                 ingress_path, health_path, deployments[]
OUTPUT: ValidationReport

BEGIN
  ASSERT config != NULL
  ASSERT hasActiveAwsCredentials() = true
  FOR each svc IN config.services DO
    ASSERT directoryExists("{svc.repo_path}/{svc.k8s_dir}")
    ASSERT fileExists("{svc.repo_path}/{svc.dockerfile}")
  END FOR

  // Stage 1: Infrastructure (AWS)
  terraformInit(config.tf_vars_path)
  terraformApply(config.tf_vars_path, autoApprove=true)
  tfOut ← terraformOutputAsJson()

  // Stage 2: Kubeconfig
  RUN "aws eks update-kubeconfig --region {config.aws_region} --name {tfOut.eks_cluster_name}"
  ASSERT kubectlClusterInfoSucceeds() = true

  // Stage 3: Shared k8s bootstrap (owned by infra repo)
  //   terraformApply above already applied k8s-config (namespaces, NetworkPolicies,
  //   infra-outputs ConfigMap per namespace, NGINX Ingress, MongoDB, Redis,
  //   Fluent Bit, CW Container Insights). Wait for stateful readiness.
  kubectlWaitReady(namespace="data",            selector="app=mongodb", timeout=5m)
  kubectlWaitReady(namespace="data",            selector="app=redis",   timeout=5m)
  kubectlWaitReady(namespace="ingress-nginx",   selector="app.kubernetes.io/name=ingress-nginx", timeout=5m)

  // Stage 4: Per-service build + push (iterate declarative list)
  dockerLoginEcr(config.aws_region, tfOut.account_id)
  FOR each svc IN config.services DO
    ecr_url ← tfOut.ecr_repository_urls[svc.ecr_key]
    image   ← "{ecr_url}:{config.git_sha}"
    buildImage(
      context    = "{svc.repo_path}/{svc.build_context}",
      dockerfile = "{svc.repo_path}/{svc.dockerfile}",
      tag        = image
    )
    pushImage(image)
    svc.image ← image
  END FOR

  // Stage 5: Database migrations (services that declare them)
  FOR each svc IN config.services WHERE svc.migrations != NULL DO
    runJob(
      namespace = svc.namespace,
      name      = "db-migrate-{svc.name}",
      image     = svc.image,
      command   = svc.migrations.command
    )
    waitJobComplete("db-migrate-{svc.name}", timeout=10m)
  END FOR

  // Stage 6: Apply each service's own k8s/ folder, in topological stages
  FOR each stage IN config.stages DO
    FOR each svc_name IN stage DO
      svc ← findService(config.services, svc_name)
      k8s_path ← "{svc.repo_path}/{svc.k8s_dir}"

      // Prefer kustomize when present, else plain apply
      IF fileExists("{k8s_path}/kustomization.yaml") THEN
        RUN "kubectl apply -k {k8s_path}"
      ELSE
        RUN "kubectl apply -f {k8s_path}/ --namespace {svc.namespace}"
      END IF

      FOR each dep IN svc.deployments DO
        RUN "kubectl rollout status deployment/{dep} -n {svc.namespace} --timeout=5m"
      END FOR
    END FOR
    // stage boundary: all deployments in this stage must be Available before next stage
    ASSERT allDeploymentsAvailable(stage)
  END FOR

  // Stage 7: Wait for ALB target health
  waitForAlbHealthy(tfOut.alb_dns_name, timeout=10m)

  // Stage 8: Validation
  report ← validateAll(tfOut.alb_dns_name, config.services)

  // Stage 9: Auto-fix retry (once)
  IF report.hasFailures() THEN
    attemptAutoFix(report.failures)   // e.g. rollout restart, reapply configmap
    report ← validateAll(tfOut.alb_dns_name, config.services)
  END IF

  emitReport(report)   // ./artifacts/validation-report-{ts}.{json,md}
  RETURN report
END
```

**Preconditions**:
- AWS CLI session credentials valid (`aws sts get-caller-identity` succeeds).
- `terraform.tfvars` exists with `lab_role_arn`, `db_password`, `jwt_signing_key` populated.
- Every service repo declared in `services[]` is checked out at `svc.repo_path` and contains a `k8s/` folder matching the Per-Service k8s/ Folder Contract.
- `terraform apply` has already applied the shared k8s bootstrap (namespaces, NetworkPolicies, `infra-outputs` ConfigMap, NGINX Ingress, MongoDB, Redis, observability DaemonSets).

**Postconditions**:
- `terraformApply` drift is zero on immediate re-run.
- Every service listed in `config.services` passes its `/health` check through the ALB.
- ALB target group reports all targets `healthy`.
- Validation report written to `./artifacts/validation-report-{timestamp}.json` and `.md`.

**Loop invariants**:
- Stage 4 (image loop): all previously pushed images are present in ECR (verified via `aws ecr describe-images`); failure of service `i` does not prevent service `j>i` from building independently, but does prevent Stage 6 from applying service `i`'s manifests.
- Stage 6 (topological apply loop): for every already-processed stage `k` and every deployment `d` in stage `k`, `d` is `Available=True` before stage `k+1` begins. The orchestrator never applies a manifest from stage `k+1` until all of stage `k` reports ready.

### Health Validation Algorithm

```pascal
ALGORITHM validateAll(alb_dns, services)
INPUT:  alb_dns, services[] with name, path, expected_status
OUTPUT: ValidationReport { overall: bool, items: []ServiceStatus }

BEGIN
  report ← empty
  FOR each svc IN services DO
    url ← "http://{alb_dns}{svc.health_path}"
    start ← now()
    REPEAT
      resp ← httpGet(url, timeout=5s)
      IF resp.status = svc.expected_status THEN
        report.add(ServiceStatus{svc.name, "PASS", resp.latency_ms, resp.body})
        BREAK
      END IF
      sleep(10s)
    UNTIL now() - start > 5m
    IF not reported THEN
      report.add(ServiceStatus{svc.name, "FAIL", null, last_error})
    END IF
  END FOR
  report.overall ← ALL items have status = "PASS"
  RETURN report
END
```

### Rollback Strategy

| Failure class | Rollback action |
|---|---|
| Deployment rolled out bad image | `kubectl rollout undo deployment/{name} -n {ns}` (revision history limit 5) |
| ConfigMap change broke service | `kubectl rollout undo` + revert ConfigMap via GitOps commit revert |
| Terraform apply partial failure | Re-run `terraform apply` (idempotent); if resource corrupted, `terraform taint` + apply |
| Database schema migration broke app | Forward-fix via new migration; Academy does not permit restore from automated snapshot in-place, but manual snapshot restore is available |
| Secret rotation broke pods | Revert Secrets Manager version (`aws secretsmanager update-secret-version-stage`) + `kubectl rollout restart` |
| Full-stack abandon | `terraform destroy` (guarded by `force_destroy=true` on S3, `force_delete=true` on ECR, `skip_final_snapshot=true` on RDS for non-prod) |

### Cost Estimate

| Resource | Spec | Monthly USD | Notes |
|---|---|---|---|
| EKS control plane | 1 cluster | 73.00 | Fixed |
| EC2 `t3.small` | 2 nodes, on-demand | 30.00 | HPA can burst to 5 |
| EBS `gp3` | ~60 GB across nodes + PVCs | 5.00 | Nodes 30 GB each + Mongo/Redis PVCs |
| RDS `db.t3.micro` | single-AZ, 20 GB `gp3` | 13.00 | Backup retention 7 d |
| ALB | 1 LB, moderate traffic | 16.00 | ~USD 0.0225/h + LCU |
| S3 | ~1 GB storage + requests | 1.00 | Diagrams + access logs |
| SQS Standard | Free tier typically covers lab | 0.00–1.00 | 1M req free |
| ECR | ~2 GB images, 5 repos | 0.20 | 0.10/GB/month |
| Secrets Manager | 7 secrets | 2.80 | 0.40/secret/month |
| CloudWatch Logs | 7-day retention, ~2 GB/mo | 1.00 | ~0.50/GB ingested |
| **Total** | | **~142** | Exceeds USD 100 target; see mitigations below |

**Mitigations to fit USD 50–100 budget**:
- Run only during active labs; `terraform destroy` between sessions (saves EKS + RDS + ALB = ~USD 122/mo prorated).
- Use a single `t3.small` node with `eks_node_desired_size=1` (saves USD 15/mo).
- Consolidate Secrets Manager entries into one JSON blob (saves USD 2.40/mo).
- Drop ALB, expose NGINX via NodePort directly to a public IP (saves USD 16/mo; loses access logs).

Recommended operating pattern for Academy: teardown + recreate per session — effective monthly cost < USD 30 if labs run ~20 h/week.

### AWS Academy Compatibility Matrix

| Service / Feature | Academy constraint | Mitigation in this design |
|---|---|---|
| `iam:CreateRole` | Denied | Reuse `LabRole` for EKS cluster, node group, VPC Flow Logs |
| `iam:CreateOpenIDConnectProvider` | Denied | Skip IRSA; use node-level credentials via IMDS |
| KMS CMK create | Sometimes denied | `eks` module creates one CMK; if apply fails, swap `encryption_config.provider.key_arn` to AWS-managed `alias/aws/eks` (documented fallback) |
| ACM public certs via DNS | Domain validation blocked | ALB listener is HTTP :80 only; document as Academy limitation |
| Route53 hosted zone create | Sometimes denied | Use ALB DNS name directly; no custom domain |
| DocumentDB | Requires IAM role | Replaced with MongoDB StatefulSet |
| ElastiCache | Requires SG + subnet group + IAM | Replaced with Redis StatefulSet |
| Session credentials expire ~4 h | Long `terraform apply` may fail mid-run | Backend state supports resumption; bootstrap script detects `ExpiredToken` and prompts refresh |
| NAT Gateway | Allowed but expensive | Nodes in public subnets; S3 VPC Endpoint for S3 traffic |
| EKS instance types | Limited whitelist | `t3.small` used (confirmed allowed) |
| RDS Multi-AZ | Cost | Single-AZ only |
| `rds-monitoring-role` | Cannot create | `monitoring_interval = 0` |
| CloudFormation nested stacks | Sometimes throttled | Terraform used; no CFN |

---

## Data Models

### Data Model Summary per Service

| Service | Store | Schema / Collection | Owner | Notes |
|---|---|---|---|---|
| auth-service | MongoDB `arch-analyzer-auth` | `apiKeys`, `users` | auth-service only | Password hash bcrypt; JWT signed HS256 |
| registration-service | PostgreSQL `archanalyzer` schema `registration` | `analysis`, `diagram`, `outbox` | registration-service only | Outbox pattern for SQS publish |
| processing-service | PostgreSQL `archanalyzer` schema `processing` + pgvector | `analysis_status`, `embeddings` | processing + worker | pgvector extension loaded via parameter group or init SQL |
| report-service | PostgreSQL `archanalyzer` schema `processing` (read-only) | `analysis`, `report` (views) | report-service (read-only role) | No writes; migrations owned by processing |
| shared cache | Redis (in-cluster) | `job:{id}`, `job:{id}:events` | processing + worker | No persistence required |
| diagrams | S3 `arch-analyzer-diagrams-*` | `diagrams/{analysis_id}.{ext}` | registration (write) + worker (read) | Private bucket, SSE, TLS-only policy |

### PostgreSQL Schemas (logical)

```sql
-- schema: registration
CREATE TABLE registration.analysis (
  id            UUID PRIMARY KEY,
  user_id       UUID NOT NULL,
  s3_key        TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('queued','processing','done','error')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE registration.outbox (
  id            UUID PRIMARY KEY,
  aggregate_id  UUID NOT NULL,
  event_type    TEXT NOT NULL,
  payload       JSONB NOT NULL,
  published_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- schema: processing
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE processing.analysis_status (
  id             UUID PRIMARY KEY REFERENCES registration.analysis(id),
  phase          TEXT NOT NULL,
  progress_pct   INT NOT NULL CHECK (progress_pct BETWEEN 0 AND 100),
  error_message  TEXT
);

CREATE TABLE processing.report (
  id            UUID PRIMARY KEY,
  analysis_id   UUID NOT NULL REFERENCES registration.analysis(id),
  summary       TEXT NOT NULL,
  findings      JSONB NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE processing.embeddings (
  id            UUID PRIMARY KEY,
  analysis_id   UUID NOT NULL REFERENCES registration.analysis(id),
  chunk         TEXT NOT NULL,
  embedding     vector(1536) NOT NULL
);
```

### MongoDB Collections

```javascript
// db: arch-analyzer-auth
db.createCollection("users", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "username", "password_hash", "created_at"],
      properties: {
        _id:           { bsonType: "string" },
        username:      { bsonType: "string", minLength: 3 },
        password_hash: { bsonType: "string" },
        roles:         { bsonType: "array", items: { bsonType: "string" } },
        created_at:    { bsonType: "date" }
      }
    }
  }
});

db.createCollection("apiKeys", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "key_hash", "owner", "created_at"],
      properties: {
        _id:        { bsonType: "string" },
        key_hash:   { bsonType: "string" },
        owner:      { bsonType: "string" },
        scopes:     { bsonType: "array", items: { bsonType: "string" } },
        created_at: { bsonType: "date" },
        expires_at: { bsonType: "date" }
      }
    }
  }
});
```

### S3 Object Layout

```
s3://arch-analyzer-diagrams-<env>-<suffix>/
  diagrams/
    {analysis_id}.{png|jpg|pdf}              # uploaded by registration-service
  exports/
    {analysis_id}/report.pdf                  # optional generated export

s3://arch-analyzer-access-logs-<env>-<suffix>/
  alb/AWSLogs/.../                            # ALB access logs (written by ALB service account)
  diagrams-logs/                              # S3 server access logs for diagrams bucket
```

### Validation Rules

- `analysis.status` transitions strictly: `queued → processing → (done | error)`. Enforced in registration-service domain logic.
- `embeddings.embedding` dimension must match the embedding model in use (1536 for OpenAI `text-embedding-3-small`).
- `apiKeys.key_hash` stored as bcrypt (cost factor ≥ 10); plaintext keys never persisted.
- S3 object keys must match `^diagrams/[0-9a-f-]{36}\.(png|jpe?g|gif|webp|pdf)$`.

---

## Correctness Properties

Each property is stated as a universal quantification over system states or inputs, with a corresponding automated check strategy.

### Property 1: Idempotency of Infrastructure Apply

   ```
   ∀ state s₀ produced by `terraform apply` against a clean AWS account:
     let s₁ = state after running `terraform apply` a second time with identical vars.
     Then: plan(s₀ → s₁) = { add: 0, change: 0, destroy: 0 }
   ```

   **Validates: Requirements 15.14**

   Check: CI job runs `terraform apply -auto-approve`, then `terraform plan -detailed-exitcode`; exit code 0 required.

### Property 2: Deployment Order Correctness

   ```
   ∀ services A, B such that B depends on A (per dependency graph):
     readyTime(B) > readyTime(A)
   ```

   **Validates: Requirements 15.9, 15.10, 21.4**

   **Invariant** (unchanged): no service may become ready before all of its transitive dependencies.

   **Check strategy** (updated for repo-ownership split):
   The Deployment_Orchestrator iterates `config.services[].repo_path` in a fixed topological order declared in `config.stages` (`[auth-service] → [registration-service, report-service, processing-service] → [api-gateway]`). For every stage boundary, the orchestrator waits on `kubectl rollout status` of every Deployment in that stage (including `celery-worker` in the `processing-service` stage) before starting the next stage's build/apply. The property test synthesizes random permutations of the repo order via `hypothesis`, feeds each permutation into a mock orchestrator, and asserts:
   - when the permutation matches (or is a topological refinement of) the declared stage order, the apply succeeds and `readyTime(B) > readyTime(A)` holds for every dependency edge;
   - when the permutation violates the dependency DAG (e.g. `api-gateway` before `auth-service`), the orchestrator either fails the stage gate (`kubectl rollout status` times out because the dependency is missing) or `validateAll` reports the dependent service as `FAIL`, and the test asserts the expected failure.

   This makes the property falsifiable against order mutations while codifying the "apply per-repo `k8s/` in topological order" contract introduced by the split.

### Property 3: Health Invariant

   ```
   ∀ service s ∈ {api-gateway, auth, registration, processing, report}:
     after bootstrap completes, GET http://{alb_dns}/api/{s}/health returns 200
     within 5 minutes with latency < 2 s.
   ```

   **Validates: Requirements 16.1, 16.2, 16.3, 16.4, 16.5**

   Check: `validateAll` algorithm above. Implemented in `scripts/validate.ps1` and as a post-deploy CI step.

### Property 4: Secret Isolation

   ```
   ∀ secret value v ∈ {db_password, jwt_key, mongo_password, llm_keys}:
     v ∉ any committed file in the repo
     ∧ v ∉ plaintext in any Kubernetes manifest rendered by `kubectl get -o yaml`
     ∧ v ∉ application log output
   ```

   **Validates: Requirements 10.3, 10.4, 10.7**

   Check:
   - `gitleaks` or `trufflehog` on repo pre-commit + CI.
   - `kubectl get secrets -A -o yaml | grep -E 'password|key' | grep -v base64` should return only base64-wrapped values; a script decodes and asserts no plaintext env var carries the same value.
   - Log scrubbing regex test in CI against structured logs.

### Property 5: Network Least Privilege

   ```
   ∀ security group rule r in the VPC:
     (r.direction = "ingress" ∧ r.cidr = "0.0.0.0/0")
       ⟹ (r.security_group = alb_sg ∧ r.port = 80)
   ```

   **Validates: Requirements 2.6, 2.7**

   Check: Terraform `check` block or `aws ec2 describe-security-group-rules` postcondition, asserted by a property test that enumerates all rules and filters on the implication.

### Property 6: Cost Ceiling

   ```
   estimatedMonthlyCost(planned_state) ≤ AWS_ACADEMY_BUDGET (USD 100 default)
   ```

   **Validates: Requirements 19.1, 19.2, 19.3**

   Check: `infracost breakdown --path .` in CI; fails build if above ceiling. Manual override via PR label for documented exceptions.

### Property 7: Zero-Drift Rerun Under Session Refresh

   ```
   ∀ Terraform state s, ∀ credential refresh event e:
     applying the same code post-e yields zero drift.
   ```

   **Validates: Requirements 15.14, 18.1, 18.2, 18.4, 18.5**

   Check: periodic `terraform plan` during lab session; alerts if `plan` reports changes without code diff.

### Property 8: Port Exposure

   ```
   ∀ Service svc of type LoadBalancer in the cluster: svc = ∅
   ```

   **Validates: Requirements 8.7, 14.12, 22.3**

   All inbound traffic must enter via the ALB → NGINX Ingress path; no direct `LoadBalancer` Service is allowed. Check: `kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'` must be empty.

---

## Error Handling

| Scenario | Condition | Response | Recovery |
|---|---|---|---|
| Terraform session expired mid-apply | `ExpiredToken` | Bootstrap script catches, prompts `aws sso login` / re-export, resumes | Re-run script; Terraform resumes from state |
| KMS CMK creation denied | Apply error `AccessDenied` on `aws_kms_key.eks` | Fallback path sets `encryption_config` to AWS-managed `alias/aws/eks` via `-var use_aws_managed_kms=true` | Re-run apply |
| EKS node group `CREATE_FAILED` (instance type quota) | Node group fails | Retry with `eks_node_instance_types=["t3.small"]` + `node_desired_size=1` | Update tfvars + apply |
| ECR push denied | `denied: User is not authorized` | Script re-runs `aws ecr get-login-password` | Automatic |
| Pod `ImagePullBackOff` | Image missing / tag mismatch | Validator detects; re-push image + `kubectl rollout restart` | Automatic (one retry) |
| Pod `CrashLoopBackOff` | App exits | Validator collects last 100 log lines; fails with diagnostic | Manual: inspect ConfigMap/Secret |
| RDS connectivity failure | `timeout` on /health | Validator verifies SG rules + subnet routes; reports delta | Manual: re-apply `security` module |
| SQS send denied | `AccessDenied` | Queue policy check; LabRole test via `aws sqs send-message --dry-run` | Fix queue policy / Terraform |
| ALB targets unhealthy | TG health `unhealthy` | Validator checks NGINX NodePort reachability + `/healthz` response | Re-apply `alb` + restart NGINX controller |

---

## Testing Strategy

### Unit Testing

- **Terraform**: `terraform validate` + `terraform fmt -check` per module in CI. `tflint` with AWS plugin for best-practice checks.
- **K8s manifests**: `kubeconform` or `kubectl apply --dry-run=client -o yaml` validates schema against target Kubernetes version.
- **Orchestrator script**: Pester tests (Windows PowerShell) and bats tests (Bash) for helper functions (`buildImage`, `waitForAlbHealthy`, etc.) with mocked AWS CLI.

### Property-Based Testing

**Library**: Python `hypothesis` (for generating SG rule sets, service dependency graphs, cost inputs).

- **Property 5 (least privilege)** is testable via a hypothesis strategy that synthesizes random Terraform plans and asserts the implication on every rule.
- **Property 1 (idempotency)** is testable as a replayed-apply property: `apply; apply` ⟹ empty diff, run in CI against a sandbox account.
- **Property 2 (deployment order)** is testable by permuting deploy orders in the orchestrator and asserting the algorithm still respects the dependency graph (topological sort invariant).

### Integration Testing

- **Smoke test**: bootstrap against a disposable namespace `arch-analyzer-smoke`, run `validateAll`, tear down.
- **End-to-end**: submit a known diagram via `/api/registration/diagrams`, poll `/api/analyses/{id}/status` until `done`, fetch via `/api/reports/{id}`. Implemented as a `pytest` + `requests` test in `tests/e2e/`.
- **Chaos**: kill a random pod (`kubectl delete pod -n ... --selector app=...`) and assert HPA replaces it within 60 s; latency p95 during disruption < 5 s.

---

## Performance Considerations

- **Cluster capacity**: two `t3.small` nodes (2 vCPU, 2 GiB each) → ~3.6 vCPU / 3.4 GiB schedulable after system pods. Total pod requests at steady state: ~1.2 vCPU / 2.5 GiB. Headroom sufficient for HPA burst on one service.
- **RDS**: `db.t3.micro` = 2 vCPU burstable + 1 GiB. Adequate for dev workload (< 50 req/s sustained). Connection pool sized ≤ 20 per service instance (PgBouncer optional).
- **SQS**: visibility timeout 600 s (longer than LLM pipeline worst case), `max_receive_count=3` before DLQ.
- **Celery worker**: concurrency 2 per pod; autoscale on queue depth via KEDA optional (documented future work; KEDA requires no IAM role creation, safe under Academy).
- **LLM latency**: not controlled here; pipeline publishes SSE progress events to Redis so UX hides latency.

---

## Security Considerations

- **ALB HTTP only**: TLS termination limited because ACM public cert with DNS validation is not feasible on the Academy ALB DNS name. Documented as lab-grade posture; production would add ACM + custom domain.
- **Pod security**: `runAsNonRoot=true`, `runAsUser=10000`, `readOnlyRootFilesystem=true` (where supported by runtime), `drop: [ALL]` capabilities, `automountServiceAccountToken=false`.
- **NetworkPolicies**: default-deny-ingress per app namespace; explicit allow rules per flow (ingress controller → api-gateway, api-gateway → services, processing → processing-worker, etc.).
- **Secrets**: never in ConfigMaps; Secrets Manager versioned; K8s Secret values sourced at pod start via init container.
- **VPC Flow Logs**: enabled (7-day retention).
- **RDS**: `storage_encrypted=true`, `iam_database_authentication_enabled=true`, `deletion_protection` on prod, SG restricted to node SG.
- **S3**: block-public-access, deny-insecure-transport policy, bucket versioning, SSE default.
- **Audit trail**: CloudTrail is present at the AWS Academy account level (not configurable by student); `eks` control plane logs `api`, `audit`, `authenticator` enabled.

---

## Dependencies

### Tool dependencies (student workstation)

| Tool | Version | Purpose |
|---|---|---|
| Terraform | ≥ 1.5.0 | IaC |
| AWS CLI | v2 (≥ 2.13) | `eks update-kubeconfig`, ECR login, Secrets Manager, SQS |
| kubectl | ≥ 1.29 | Apply manifests, validate health |
| Docker | ≥ 24 | Image build |
| PowerShell 7+ (Windows) / Bash (Linux/macOS) | — | Run orchestrator |
| `jq` | ≥ 1.6 | Parse Terraform outputs in shell variant |
| `helm` | ≥ 3.12 | NGINX Ingress, Fluent Bit, MongoDB, Redis charts |

### Terraform provider dependencies

| Provider | Version |
|---|---|
| `hashicorp/aws` | `~> 5.0` |
| `hashicorp/kubernetes` | `~> 2.25` |
| `hashicorp/helm` | `~> 2.12` |
| `hashicorp/tls` | `~> 4.0` |

### Cross-repo dependencies

Every microservice repo owns its `Dockerfile` and its `k8s/` folder. The infra repo consumes these repos as siblings on disk (`../fiap-arch-analyzer-<svc>`) and drives them through the Deployment_Orchestrator. Every service consumes the shared `infra-outputs` ConfigMap for AWS values; the "Consumed `infra-outputs` keys" column lists the **minimum** set each service needs.

| Repo | Dockerfile | `k8s/` contents | Consumed `infra-outputs` keys | ECR image name | Namespace | Ingress path | Container port | Health path |
|---|---|---|---|---|---|---|---|---|
| `fiap-arch-analyzer-api-gateway` | `Dockerfile` (repo root) | `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, `kustomization.yaml` (opt) | `AWS_REGION`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_GATEWAY` | `arch-analyzer-gateway` | `arch-analyzer-api` | `/api/gateway` | `8080` | `/api/gateway/health` |
| `fiap-arch-analyzer-auth-service` | `Dockerfile` (repo root) | `namespace.yaml` (opt), `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, `kustomization.yaml` (opt) | `AWS_REGION`, `AWS_ACCOUNT_ID`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_AUTH` | `arch-analyzer-auth` | `auth` | `/api/auth` | `5002` | `/api/auth/health` |
| `fiap-arch-analyzer-registration-service` | `Dockerfile` (repo root) + EF migrations project | `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, `kustomization.yaml` (opt) | `AWS_REGION`, `DB_ADDRESS`, `DB_PORT`, `DB_NAME`, `SQS_PROCESSING_QUEUE_URL`, `S3_DIAGRAMS_BUCKET`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_REGISTRATION` | `arch-analyzer-registration` | `arch-analyzer-api` | `/api/registration` | `5002` | `/api/registration/health` |
| `fiap-arch-analyzer-processing-service` | `Dockerfile` (repo root) + Alembic migrations | `deployment.yaml` (processing-service) + `deployment.yaml` (celery-worker, no Service/Ingress), `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, `kustomization.yaml` (opt) | `AWS_REGION`, `DB_ADDRESS`, `DB_PORT`, `DB_NAME`, `SQS_PROCESSING_QUEUE_URL`, `SQS_DLQ_URL`, `S3_DIAGRAMS_BUCKET`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_PROCESSING` | `arch-analyzer-processing` | `arch-analyzer-ia` | `/api/analyses` | `8000` | `/api/analyses/health` |
| `fiap-arch-analyzer-report-service` | `Dockerfile` (repo root) | `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `configmap.yaml`, `aws-secret-template.yaml`, `kustomization.yaml` (opt) | `AWS_REGION`, `DB_ADDRESS`, `DB_PORT`, `DB_NAME`, `ECR_REGISTRY`, `ECR_REPOSITORY_URL_REPORT` | `arch-analyzer-report` | `arch-analyzer-ia` | `/api/reports` | `8001` | `/api/reports/health` |

The `fiap-arch-analyzer-auth-service/k8s/` folder already in the workspace is the canonical reference; the other service repos MUST mirror the same shape.

### External runtime dependencies

- OpenAI + Anthropic API keys (provided by student, injected via Secrets Manager).
- HuggingFace API token (optional, for fine-tuned model inference).

---

## Deployment Steps (Quick Reference)

1. `aws sso login` or paste Academy Lab credentials into `~/.aws/credentials`.
2. `cp terraform.tfvars.example terraform.tfvars` and fill `lab_role_arn`, `db_password`, `jwt_signing_key`, `eks_public_access_cidrs`, LLM keys.
3. `terraform init && terraform apply`.
4. `aws eks update-kubeconfig --region us-east-1 --name $(terraform output -raw eks_cluster_name)`.
5. Run `./scripts/deploy-all.ps1` (or `.sh`) from the infra repo root. The orchestrator: (a) waits for the shared k8s bootstrap created in step 3 (namespaces, `infra-outputs` ConfigMap, NGINX Ingress, MongoDB, Redis, Fluent Bit, Container Insights) to be ready, (b) iterates each service entry in `scripts/deploy-all.config.yaml`, running `docker build` + ECR push from the service repo's path, (c) applies that service's own `k8s/` folder via `kubectl apply -k <repo>/k8s` (or `-f <repo>/k8s/`) and waits for `kubectl rollout status`, (d) honours the stage order `auth-service → {registration-service, report-service, processing-service incl. celery-worker} → api-gateway`, (e) invokes Validator and writes the report to `./artifacts/`.
6. Inspect `./artifacts/validation-report-*.md` for per-service status and endpoints.
7. On session end: `terraform destroy` (optional; tear down to save cost).

---

## Next Steps

After approving this design, generate the requirements document, then the tasks breakdown, following the design-first workflow navigation links.
