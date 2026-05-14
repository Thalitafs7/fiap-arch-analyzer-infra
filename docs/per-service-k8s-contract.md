# Per-Service `k8s/` Folder Contract

Every microservice repo **MUST** ship a top-level `k8s/` folder containing its Kubernetes manifests. The reference implementation is [`fiap-arch-analyzer-auth-service/k8s/`](../../fiap-arch-analyzer-auth-service/k8s/) and is the canonical contract every service repo must match.

---

## Required Files

| File | Required | Purpose |
|---|---|---|
| `deployment.yaml` | **yes** | Pod template, replicas, probes, secret-sync init container |
| `service.yaml` | **yes** | ClusterIP Service fronting the pods |
| `ingress.yaml` | yes (except `celery-worker`) | NGINX Ingress routing `/api/<service>` |
| `hpa.yaml` | yes (except `celery-worker`) | HorizontalPodAutoscaler on CPU |
| `configmap.yaml` | **yes** | Service-specific non-sensitive app config |
| `aws-secret-template.yaml` | **yes** | Template documenting the in-cluster Secret materialised by the init container |
| `namespace.yaml` | optional | Idempotent re-declaration (authoritative definition lives in infra repo) |
| `kustomization.yaml` | recommended | Enables `kubectl apply -k k8s/` and per-environment overlays |

---

## Service Inventory

| Service | Repo | Namespace | Port | Ingress path |
|---|---|---|---|---|
| api-gateway | `fiap-arch-analyzer-api-gateway` | `arch-analyzer-api` | 8080 | `/api/gateway` |
| auth-service | `fiap-arch-analyzer-auth-service` | `auth` | 5002 | `/api/auth` |
| registration-service | `fiap-arch-analyzer-registration-service` | `arch-analyzer-api` | 5002 | `/api/registration` |
| processing-service | `fiap-arch-analyzer-processing-service` | `arch-analyzer-ia` | 8000 | `/api/analyses` |
| celery-worker | `fiap-arch-analyzer-processing-service` | `arch-analyzer-ia` | — | — |
| report-service | `fiap-arch-analyzer-report-service` | `arch-analyzer-ia` | 8001 | `/api/reports` |

---

## Naming Conventions

| Concern | Convention | Example (auth-service) |
|---|---|---|
| Namespace | One of `arch-analyzer-api`, `arch-analyzer-ia`, `auth` | `auth` |
| Deployment name | `<service-short>-api` for HTTP services, `<service-short>-worker` for workers | `ms-auth-api` |
| Service name | `<service-short>-service` | `ms-auth-service` |
| Ingress name | `<service-short>-ingress` | `auth-ingress` |
| ConfigMap name | `<service-short>-config` | `ms-auth-config` |
| Secret name | `<service-short>-secret` | `ms-auth-secret` |
| Container image | `arch-analyzer-<service>:${IMAGE_TAG}` — resolved via `infra-outputs` | `arch-analyzer-auth:${IMAGE_TAG}` |
| Ingress path | `/api/<service>(/\|$)(.*)` with `rewrite-target: /$2` | `/api/auth(/\|$)(.*)` |

---

## Required Labels

Every Deployment, Service, and Ingress **MUST** carry:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: <service-short>
    app.kubernetes.io/part-of: arch-analyzer
    app.kubernetes.io/component: <api|worker|gateway>
```

---

## Deployment Spec Requirements

### Replicas and history

```yaml
spec:
  replicas: 2
  revisionHistoryLimit: 5
```

### Pod security context

```yaml
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10000
    fsGroup: 10000
```

### Container security context

```yaml
containers:
  - name: <service-short>-api
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

### Resource requests and limits

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Health probes

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: <container_port>
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /health
    port: <container_port>
  initialDelaySeconds: 5
  periodSeconds: 5
```

---

## Secret-Sync Init Container Pattern

Every pod that needs secrets from AWS Secrets Manager **MUST** include a `secrets-sync` init container. This is the only supported pattern — no IRSA, no Kubernetes Secrets pre-created in Git.

```yaml
volumes:
  - name: secrets-vol
    emptyDir:
      medium: Memory   # never touches disk

initContainers:
  - name: secrets-sync
    image: amazon/aws-cli:2.15.0
    command:
      - /bin/sh
      - -c
      - |
        set -e
        SECRET=$(aws secretsmanager get-secret-value \
          --secret-id arch-analyzer/auth/mongo \
          --region us-east-1 \
          --query SecretString \
          --output text)
        echo "$SECRET" > /secrets/mongo.json
    volumeMounts:
      - name: secrets-vol
        mountPath: /secrets
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

The init container uses the **node-level LabRole credentials** available via IMDS — no service account token is needed (`automountServiceAccountToken: false`).

---

## Consuming `infra-outputs` — No Hardcoded AWS Values

Service manifests **MUST NOT** embed literal AWS values (account IDs, RDS hostnames, ECR URLs, SQS URLs, S3 bucket names). They consume the shared `infra-outputs` ConfigMap published by the infra repo.

**Mode A — import everything (preferred):**

```yaml
containers:
  - name: ms-auth-api
    envFrom:
      - configMapRef:
          name: infra-outputs        # AWS_REGION, DB_ADDRESS, SQS_*, S3_*, ECR_*, ...
      - configMapRef:
          name: ms-auth-config       # service-specific non-sensitive config
      - secretRef:
          name: ms-auth-secret       # materialised by init container
```

**Mode B — cherry-pick individual keys:**

```yaml
env:
  - name: AWS_REGION
    valueFrom:
      configMapKeyRef:
        name: infra-outputs
        key: AWS_REGION
  - name: SQS_QUEUE_URL
    valueFrom:
      configMapKeyRef:
        name: infra-outputs
        key: SQS_PROCESSING_QUEUE_URL
```

The CI `no-aws-literals` guardrail will **fail any PR** that embeds a literal AWS value in a k8s manifest.

---

## Service and Ingress Requirements

### Service

```yaml
apiVersion: v1
kind: Service
spec:
  type: ClusterIP   # MUST NOT be LoadBalancer
  ports:
    - port: <container_port>
      targetPort: <container_port>
```

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Forwarded-Prefix /api/<service>;
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api/<service>(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: <service-short>-service
                port:
                  number: <container_port>
```

### HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <deployment-name>
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## `kustomization.yaml` (recommended)

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
# namespace.yaml omitted — namespace bootstrapped by infra repo
commonLabels:
  app.kubernetes.io/part-of: arch-analyzer
images:
  - name: arch-analyzer-auth
    newName: ${ECR_REGISTRY}/arch-analyzer-auth
    newTag: ${IMAGE_TAG}
```

The Deployment_Orchestrator prefers `kubectl apply -k k8s/` when `kustomization.yaml` is present and falls back to `kubectl apply -f k8s/` otherwise.

---

## `configmap.yaml` Rules

The service ConfigMap **MUST** contain only non-sensitive, non-AWS app config:

```yaml
# GOOD — non-sensitive app config
data:
  ASPNETCORE_ENVIRONMENT: "Production"
  MongoDb__DatabaseName: "auth_db"
  Logging__LogLevel__Default: "Information"

# BAD — AWS values belong in infra-outputs, not here
# DB_ADDRESS: "arch-analyzer-dev.xxx.rds.amazonaws.com"
# SQS_QUEUE_URL: "https://sqs.us-east-1.amazonaws.com/..."
```

---

## `aws-secret-template.yaml` Rules

This file is a **template / documentation only** — it documents the shape of the in-cluster Secret materialised by the init container. It **MUST NOT** contain real secret values.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ms-auth-secret
  namespace: auth
type: Opaque
stringData:
  # Sourced from arch-analyzer/auth/mongo in Secrets Manager
  MONGO_CONNECTION_STRING: "REPLACE_AT_DEPLOY_TIME"
  # Sourced from arch-analyzer/auth/jwt in Secrets Manager
  Jwt__Key: "REPLACE_AT_DEPLOY_TIME"
```

---

## `celery-worker` Special Case

The `celery-worker` Deployment lives in `fiap-arch-analyzer-processing-service/k8s/` as a sibling to `deployment.yaml`. It:

- Uses the **same image** as `processing-service`
- Declares a custom `command` (`celery -A worker worker --loglevel=INFO --concurrency=2`)
- Reuses the same init container, security context, and `envFrom` stack
- **Does NOT** declare a `Service`, `Ingress`, or `HorizontalPodAutoscaler`

---

## Deployment Order

The Deployment_Orchestrator applies services in this stage order (Req 15.9):

```
Stage 1: auth-service
Stage 2: registration-service, report-service, processing-service (parallel)
Stage 3: api-gateway
```

Each stage blocks on `kubectl rollout status` for all Deployments in the previous stage before proceeding.

---

## CI Guardrails

Every service repo has a `.github/workflows/k8s-validate.yml` workflow that runs on PRs to `main`:

1. **kubeconform** — validates all `k8s/*.yaml` (except `aws-secret-template.yaml`) against Kubernetes 1.29 schema
2. **no-aws-literals** — scans manifests for hardcoded AWS values; fails if any are found

To add the guardrail to a new service repo, copy the `k8s-validate.yml` from any existing service repo.

---

## Rotating a Secret

1. Update the value in AWS Secrets Manager:
   ```bash
   aws secretsmanager update-secret \
     --secret-id arch-analyzer/auth/mongo \
     --secret-string '{"password":"new-password"}'
   ```
2. Restart the affected Deployment so the init container re-fetches:
   ```bash
   kubectl rollout restart deployment/ms-auth-api -n auth
   ```
3. Verify the rollout:
   ```bash
   kubectl rollout status deployment/ms-auth-api -n auth
   ```
