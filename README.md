# Arch Analyzer - Infrastructure as Code

Monorepo de infraestrutura Terraform para o projeto **Arch Analyzer**, projetado para rodar no **AWS Academy** com **Amazon EKS**.

---

## Sumário Arquitetural

- **Tipo de sistema:** Microserviços event-driven (6 repos, multi-linguagem)
- **Componentes principais:** API Gateway (.NET), Auth Service (.NET/MongoDB), Registration Service (.NET/PostgreSQL), Processing Service (Python/FastAPI), Report Service (Python/FastAPI), Infra (Terraform/AWS)
- **Infraestrutura:** AWS EKS, RDS PostgreSQL 15, pgvector, MongoDB, RabbitMQ, SQS+DLQ, S3, Redis, ALB, NGINX Ingress, ECR, VPC c/ subnets públicas+privadas
- **Fluxos críticos:** Upload diagrama → RabbitMQ/SQS → Pipeline IA (5 etapas LLM) → Webhook callback → Persistência relatório
- **Padrões identificados:** Clean Architecture, Hexagonal Architecture, CQRS, DDD, Event-Driven, API Gateway, Webhook, RAG, Pub/Sub SSE

---

## Diagramas de Arquitetura

### 1. Topologia Macro — Serviços e Integrações

Visão de alto nível de todos os serviços, bancos, filas e integrações externas.

```mermaid
graph LR
    subgraph Clients
        USER["Usuário / Frontend"]
    end

    subgraph "API Layer"
        GW["API Gateway<br>.NET 9"]
        AUTH["Auth Service<br>.NET 9"]
    end

    subgraph "Business Layer"
        REG["Registration Service<br>.NET 9"]
        PROC["Processing Service<br>FastAPI / Python"]
        REP["Report Service<br>FastAPI / Python"]
    end

    subgraph "Messaging"
        RMQ["RabbitMQ"]
        SQS["AWS SQS"]
        DLQ["SQS DLQ"]
        REDIS["Redis"]
    end

    subgraph "Data Stores"
        MONGO["MongoDB<br>API Keys"]
        PGRE["PostgreSQL<br>Registration DB"]
        PGAI["PostgreSQL + pgvector<br>Processing DB"]
        S3["Amazon S3<br>Diagrams"]
    end

    subgraph "External"
        LLM["OpenAI GPT-4o<br>Vision + Text + Embeddings"]
    end

    USER -->|HTTP| GW
    GW -->|validate key| AUTH
    GW -->|route| REG
    AUTH -->|read/write| MONGO
    REG -->|persist| PGRE
    REG -->|publish diagram.uploaded| RMQ
    REG -->|upload file| S3
    RMQ -->|consume| PROC
    SQS -->|consume| PROC
    PROC -->|download| S3
    PROC -->|webhook callback| REG
    PROC -->|persist + RAG| PGAI
    PROC -->|LLM calls| LLM
    PROC -->|task broker + events| REDIS
    REDIS -->|dispatch| CELERY["Celery Worker"]
    CELERY -->|persist| PGAI
    CELERY -->|LLM calls| LLM
    REP -->|read-only| PGAI
    SQS -.->|failed msgs| DLQ
```

---

### 2. Topologia de Infraestrutura — AWS EKS

Layout cloud: VPC, subnets, EKS, RDS e serviços de suporte.

```mermaid
graph TD
    subgraph "VPC 10.0.0.0/16"
        subgraph "Public Subnets"
            PUB_A["10.0.1.0/24<br>EKS Node A"]
            PUB_B["10.0.2.0/24<br>EKS Node B"]
        end

        subgraph "Private Subnets"
            PRIV_A["10.0.3.0/24<br>RDS PostgreSQL"]
            PRIV_B["10.0.4.0/24"]
        end

        ALB["ALB<br>HTTP :80"]
        EKS["EKS Control Plane<br>K8s 1.29"]
        NGINX["NGINX Ingress<br>NodePort 30080"]

        ALB --> NGINX
        NGINX --> PUB_A
        NGINX --> PUB_B
        EKS --> PUB_A
        EKS --> PUB_B
        PUB_A -.->|SG ref| PRIV_A
    end

    subgraph "K8s Namespaces"
        NS_API["arch-analyzer-api<br>Registration + Auth"]
        NS_IA["arch-analyzer-ia<br>Processing + Report"]
        NS_ING["ingress-nginx"]
    end

    subgraph "AWS Services"
        S3_SVC["S3 Diagrams<br>KMS encrypted"]
        SQS_SVC["SQS + DLQ<br>SSE enabled"]
        ECR_SVC["ECR<br>api / ia"]
        KMS["KMS<br>EKS Secrets"]
    end

    VPCE["VPC Endpoint S3<br>Gateway"]

    PUB_A --> VPCE
    VPCE --> S3_SVC
    NS_API --> PUB_A
    NS_IA --> PUB_B
    NS_ING --> NGINX
```

---

### 3. Fluxo Principal — Pipeline de Análise de Diagramas

Sequência end-to-end do upload até entrega do relatório.

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant GW as API Gateway
    participant AUTH as Auth Service
    participant REG as Registration Service
    participant PGRE as PostgreSQL Reg
    participant RMQ as RabbitMQ
    participant PROC as Processing Service
    participant S3 as S3
    participant LLM as OpenAI GPT-4o
    participant PGAI as PostgreSQL + pgvector
    participant REDIS as Redis

    U->>GW: POST /api/analise (file)
    GW->>AUTH: POST /api/auth/validate (X-Api-Key)
    AUTH-->>GW: 200 Authorized
    GW->>REG: POST /api/analise (FormData)
    REG->>PGRE: INSERT analise (status: Recebido)
    REG->>RMQ: publish diagram.uploaded
    REG-->>GW: 200 AnaliseDto
    GW-->>U: Analysis created

    RMQ->>PROC: consume message
    PROC->>REDIS: pub event (step: ingestion)
    PROC->>PROC: Validate + decode file
    PROC->>LLM: Vision API (classify image)
    LLM-->>PROC: is_architecture_diagram: true
    PROC->>LLM: Vision API (extract components)
    LLM-->>PROC: ExtractionResult
    PROC->>PGAI: Index embeddings (pgvector)
    PROC->>PGAI: Similarity search (RAG context)
    PROC->>LLM: Generate report + risks
    LLM-->>PROC: TechnicalReport
    PROC->>LLM: QA validation
    LLM-->>PROC: QAScore (valid)
    PROC->>PGAI: Persist report
    PROC->>REG: POST webhook/report/callback
    REG->>PGRE: INSERT relatorio + UPDATE status Analisado
    PROC->>REDIS: pub event (step: done)
```

---

### 4. Arquitetura Interna — Processing Service

Camadas hexagonais e estágios do pipeline dentro do processing-service.

```mermaid
flowchart TD
    subgraph "Entry Points"
        SQS_IN["SQS Consumer<br>Thread daemon"]
        RMQ_IN["RabbitMQ Consumer<br>Thread daemon"]
        HTTP_IN["FastAPI Endpoints<br>/analyze /analyze/async"]
        CELERY_IN["Celery Worker<br>Redis broker"]
    end

    subgraph "Application Layer"
        UC["AnalyzeDiagramUseCase"]
    end

    subgraph "Pipeline Steps"
        S0["Step 0: Input Guardrails<br>Sanitize + injection detect"]
        S1["Step 1: Ingestion<br>Validate type/size"]
        S1B["Step 1.5: Classification<br>LLM Vision"]
        S2["Step 2: Extraction<br>LLM Vision components"]
        S3["Step 3: RAG<br>pgvector index + search"]
        S4["Step 4: Report + Risks<br>LLM Text + Output Guardrails"]
        S5["Step 5: QA<br>Deterministic + LLM"]
    end

    subgraph "Infrastructure Adapters"
        VISION["OpenAIVisionAdapter"]
        TEXT["OpenAITextAdapter"]
        PGV["PGVectorAdapter"]
        REPO["SQLAlchemy Repositories"]
        WEBHOOK["WebhookSender<br>Retry 3x backoff"]
        REDIS_PUB["Redis Pub/Sub<br>SSE events"]
    end

    SQS_IN --> UC
    RMQ_IN --> UC
    HTTP_IN --> UC
    CELERY_IN --> UC

    UC --> S0 --> S1 --> S1B --> S2 --> S3 --> S4 --> S5

    S1B --> VISION
    S2 --> VISION
    S3 --> PGV
    S4 --> TEXT
    S5 --> TEXT
    S5 --> REPO
    UC --> WEBHOOK
    UC --> REDIS_PUB
```

---

### 5. Fluxo de Autenticação

Geração e validação de API Keys.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Admin
    actor Client as Client
    participant GW as API Gateway
    participant AUTH as Auth Service
    participant MONGO as MongoDB

    Note over Admin, MONGO: API Key Generation (one-time setup)
    Admin->>AUTH: POST /api/auth/apikey (X-Internal-Key)
    AUTH->>AUTH: Validate internal key
    AUTH->>MONGO: Persist new API Key
    AUTH-->>Admin: 200 {apiKey}

    Note over Client, MONGO: Request Authentication
    Client->>GW: Request + X-Api-Key header
    GW->>AUTH: POST /api/auth/validate (X-Api-Key)
    AUTH->>MONGO: Find active key
    alt Key valid
        MONGO-->>AUTH: Key found
        AUTH-->>GW: 200 Authorized
        GW->>GW: Route to target service
    else Key invalid
        MONGO-->>AUTH: Not found
        AUTH-->>GW: 401 Unauthorized
        GW-->>Client: HTTP 401
    end
```

---

### 6. Máquina de Estados — Ciclo de Vida da Análise

Transições de status de uma análise entre serviços.

```mermaid
stateDiagram-v2
    [*] --> Recebido: POST /api/analise
    Recebido --> EmProcessamento: Processing picks up message
    EmProcessamento --> Analisado: Pipeline success + webhook
    EmProcessamento --> Error: Pipeline failure
    Error --> [*]
    Analisado --> [*]

    note right of Recebido: Registration Service persists
    note right of EmProcessamento: Processing Service updates via webhook
    note right of Analisado: Report delivered via callback
    note right of Error: Error details in webhook payload
```

---

### 7. Topologia de Mensageria — RabbitMQ + SQS + Redis

Todos os canais de comunicação assíncrona, exchanges, filas e padrões.

```mermaid
flowchart LR
    subgraph "RabbitMQ (internal/dev)"
        EX["Exchange: reports.events<br>type: topic"]
        Q1["Queue: ia.diagram.uploads<br>binding: diagram.uploaded"]
    end

    subgraph "AWS SQS (production)"
        SQS_Q["Processing Queue<br>VisibilityTimeout: 5min"]
        SQS_DLQ["Dead Letter Queue<br>maxReceiveCount: 3"]
    end

    subgraph "Redis (internal)"
        BROKER["Celery Broker<br>Task dispatch"]
        PUBSUB["Pub/Sub Channels<br>job:{id}"]
        LIST["Lists<br>job:{id}:events<br>TTL: 10min"]
    end

    REG["Registration Service"] -->|publish| EX
    EX -->|route| Q1
    Q1 -->|consume| PROC["Processing Service"]

    S3["S3"] -->|trigger or external| SQS_Q
    SQS_Q -->|consume| PROC
    SQS_Q -.->|fail 3x| SQS_DLQ

    PROC -->|delay task| BROKER
    BROKER -->|dispatch| CELERY["Celery Worker"]
    PROC -->|progress events| PUBSUB
    PROC -->|persist events| LIST
    CELERY -->|progress events| PUBSUB
```

---

### 8. Network Policies — Kubernetes

Regras de comunicação inter-namespace gerenciadas pelo módulo Terraform k8s-config.

```mermaid
flowchart TD
    subgraph "ingress-nginx namespace"
        NGINX["NGINX Ingress Controller"]
    end

    subgraph "arch-analyzer-api namespace"
        API_PODS["API Pods<br>Registration + Auth"]
    end

    subgraph "arch-analyzer-ia namespace"
        IA_PODS["IA Pods<br>Processing + Report"]
    end

    NGINX -->|allowed| API_PODS
    NGINX -->|allowed| IA_PODS
    IA_PODS -->|webhook allowed| API_PODS
    API_PODS -->|refresh-status allowed| IA_PODS
```

---

### 9. Pipeline CI/CD

Padrão de workflows GitHub Actions compartilhado entre todos os repos.

```mermaid
flowchart LR
    subgraph "Feature Branch"
        CI_F["ci-feature.yml<br>Build + Test"]
    end

    subgraph "Develop Branch"
        CI_D["ci-develop.yml<br>Build + Test + Lint"]
    end

    subgraph "Release Branch"
        CI_R["ci-release.yml<br>Build + Test + Docker"]
    end

    subgraph "Main Branch"
        CD_M["cd-main.yml<br>Build + Push ECR + Deploy"]
    end

    CI_F -->|PR merge| CI_D
    CI_D -->|PR merge| CI_R
    CI_R -->|PR merge| CD_M
    CD_M -->|push| ECR["AWS ECR"]
    CD_M -->|apply| EKS["EKS Cluster"]
```

---

## Arquitetura da VPC

```
┌─────────────────────────────────────────────────────────────────────┐
│                          VPC (10.0.0.0/16)                          │
│                                                                      │
│  ┌─────────────────────┐       ┌─────────────────────┐              │
│  │ Public Subnet A      │       │ Public Subnet B      │             │
│  │ (10.0.1.0/24)       │       │ (10.0.2.0/24)       │             │
│  │ ┌──────────────────┐│       │ ┌──────────────────┐ │             │
│  │ │ EKS Node (ASG)   ││       │ │ EKS Node (ASG)   │ │             │
│  │ └──────────────────┘│       │ └──────────────────┘ │             │
│  └─────────────────────┘       └─────────────────────┘              │
│            │                            │                            │
│            └──────────┬─────────────────┘                            │
│                    ┌──▼──┐                                           │
│                    │ ALB │ ← HTTP :80                                │
│                    └─────┘                                           │
│                                                                      │
│              ┌────────────────────────┐                               │
│              │ EKS Control Plane      │ (gerenciado pela AWS)        │
│              │ (API Server, etcd)     │                               │
│              └────────────────────────┘                               │
│                                                                      │
│  ┌─────────────────────┐       ┌─────────────────────┐              │
│  │ Private Subnet A     │       │ Private Subnet B     │             │
│  │ (10.0.3.0/24)       │       │ (10.0.4.0/24)       │             │
│  │ ┌──────────────────┐│       │                      │             │
│  │ │ RDS PostgreSQL   ││       │                      │             │
│  │ │ (db.t3.micro)    ││       │                      │             │
│  │ └──────────────────┘│       │                      │             │
│  └─────────────────────┘       └─────────────────────┘              │
│                                                                      │
│  S3 (diagramas) ─── VPC Endpoint S3 Gateway                         │
│  SQS + DLQ (processamento de análises)                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Fluxo da Aplicação

1. **Upload de diagramas** → API Cadastro recebe → Upload para S3 → Envia mensagem para SQS/RabbitMQ
2. **Processamento IA** → Serviço IA consome fila → Baixa diagramas do S3 → Pipeline 5 etapas com LLM + RAG
3. **Webhook de retorno** → IA envia relatório via webhook → Registration Service atualiza status
4. **Tratamento de erros** → DLQ captura mensagens falhadas → Consumer de erros atualiza status

---

## Estrutura do Projeto

```
arch-analyzer-infra/
├── main.tf                          # Orquestração dos módulos
├── variables.tf                     # Variáveis globais
├── outputs.tf                       # Outputs globais
├── provider.tf                      # Provider AWS + versões
├── terraform.tfvars.example         # Exemplo de variáveis
│
├── modules/
│   ├── network/                     # VPC, subnets, route tables, VPC endpoints
│   ├── security/                    # Security Groups (ALB, EKS nodes, RDS)
│   ├── storage/                     # S3 buckets (diagramas + access logs)
│   ├── messaging/                   # SQS processing queue + DLQ
│   ├── database/                    # RDS PostgreSQL 15
│   ├── ecr/                         # Container registries
│   ├── eks/                         # EKS cluster + managed node group + addons
│   ├── alb/                         # Application Load Balancer
│   └── k8s-config/                  # Namespaces, NetworkPolicies, ConfigMaps, NGINX Ingress
│
└── examples/
    ├── app-repo-api/                # Exemplo: repo da API Cadastro (Kustomize)
    └── app-repo-ia/                 # Exemplo: repo do Serviço IA (Kustomize)
```

---

## Modelo Multi-Repo

| Repositório | Conteúdo | Responsabilidade |
|---|---|---|
| `arch-analyzer-infra` (este) | Terraform + K8s config | Infraestrutura AWS |
| `arch-analyzer-api-gateway` | ASP.NET Core | Roteamento + entry point |
| `arch-analyzer-auth-service` | .NET 9 + MongoDB | Autenticação (API Keys) |
| `arch-analyzer-registration-service` | .NET 9 + PostgreSQL | Cadastro + ciclo de vida |
| `arch-analyzer-processing-service` | Python + FastAPI | Pipeline IA (LLM + RAG) |
| `arch-analyzer-report-service` | Python + FastAPI | Consulta de relatórios (read-only) |

---

## Segurança

### Implementado
- **EKS Secrets Encryption**: KMS key dedicada com rotação automática
- **EKS Control Plane Logs**: API, audit e authenticator logs habilitados
- **S3**: versioning, KMS encryption, block public access, deny insecure transport
- **SQS**: SSE habilitado, deny insecure transport
- **RDS**: storage encrypted, IAM auth, private subnet, audit logs
- **Security Groups**: princípio do menor privilégio (SG referenciando SGs)
- **NetworkPolicies K8s**: default-deny-ingress + allow explícito
- **VPC Flow Logs**: auditoria de tráfego
- **VPC Endpoint S3**: policy restritiva
- **Pod Security**: runAsNonRoot, runAsUser 10000, readOnlyRootFilesystem, drop ALL capabilities

### Limitações (AWS Academy)
- **ALB HTTP only**: sem HTTPS (ACM pode não estar disponível)
- **LabRole**: IAM role pré-existente do Academy para EKS e nodes
- **RDS single-AZ**: sem Multi-AZ (custo)
- **Nodes em subnets públicas**: evita NAT Gateway (~$32/mês)

---

## Estimativa de Custos

| Recurso | Especificação | Custo Estimado/mês |
|---|---|---|
| EKS Control Plane | Gerenciado | ~$73 |
| EC2 EKS Nodes (x2) | t3.small | ~$30 |
| RDS PostgreSQL | db.t3.micro, single-AZ | ~$13 |
| ALB | HTTP listener | ~$16 |
| S3 + SQS | Uso moderado | ~$2 |
| **Total estimado** | | **~$134/mês** |

---

## Quick Start

```bash
# 1. Configure as variáveis
cp terraform.tfvars.example terraform.tfvars

# 2. Inicialize o Terraform
terraform init

# 3. Verifique o plano
terraform plan

# 4. Aplique a infraestrutura
terraform apply

# 5. Configure o kubeconfig
aws eks update-kubeconfig --region us-east-1 --name $(terraform output -raw eks_cluster_name)
```

---

## Outputs do Terraform

| Output | Descrição |
|---|---|
| `eks_cluster_name` | Nome do cluster EKS |
| `eks_cluster_endpoint` | URL do API server EKS |
| `alb_dns_name` | URL de acesso à aplicação |
| `db_endpoint` | Endpoint do RDS |
| `s3_diagrams_bucket` | Nome do bucket S3 |
| `sqs_processing_queue_url` | URL da fila SQS |
| `kubeconfig_command` | Comando para configurar kubectl |
