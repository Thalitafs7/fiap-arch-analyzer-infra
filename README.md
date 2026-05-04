# Arch Analyzer - Infrastructure as Code

Monorepo de infraestrutura Terraform para o projeto **Arch Analyzer**, projetado para rodar no **AWS Academy** com **Amazon EKS**.

## Arquitetura

```
┌─────────────────────────────────────────────────────────────────────┐
│                          VPC (10.0.0.0/16)                          │
│                                                                      │
│  ┌─────────────────────┐       ┌─────────────────────┐              │
│  │ Public Subnet A      │       │ Public Subnet B      │             │
│  │ (10.0.1.0/24)       │       │ (10.0.2.0/24)       │             │
│  │                      │       │                      │             │
│  │ ┌──────────────────┐│       │ ┌──────────────────┐ │             │
│  │ │ EKS Node (ASG)   ││       │ │ EKS Node (ASG)   │ │             │
│  │ │                  ││       │ │                  │ │             │
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

K8s Workloads:
  ├── namespace: arch-analyzer-api  → API Cadastro
  ├── namespace: arch-analyzer-ia   → IA Service + Qdrant (Vector DB)
  └── namespace: ingress-nginx      → NGINX Ingress Controller
```

## Fluxo da Aplicação

1. **Upload de diagramas** → API Cadastro recebe → Upload para S3 → Envia mensagem para SQS
2. **Processamento IA** → Serviço IA consome SQS → Baixa diagramas do S3 → Processa com Qdrant (Vector DB)
3. **Webhook de retorno** → IA envia relatório via webhook → API Cadastro atualiza status
4. **Tratamento de erros** → DLQ captura mensagens falhadas → Consumer de erros atualiza status

## Estrutura do Projeto

```
arch-analyzer-infra/
├── main.tf                          # Orquestração dos módulos
├── variables.tf                     # Variáveis globais
├── outputs.tf                       # Outputs globais
├── provider.tf                      # Provider AWS + versões
├── terraform.tfvars.example         # Exemplo de variáveis
├── .gitignore
│
├── modules/
│   ├── network/                     # VPC, subnets, route tables, VPC endpoints
│   ├── security/                    # Security Groups (ALB, EKS nodes, RDS)
│   ├── storage/                     # S3 buckets (diagramas + access logs)
│   ├── messaging/                   # SQS processing queue + DLQ
│   ├── database/                    # RDS PostgreSQL 15
│   ├── eks/                         # EKS cluster + managed node group + addons
│   ├── alb/                         # Application Load Balancer
│   └── k8s-config/                  # Namespaces, NetworkPolicies, ConfigMaps, NGINX Ingress
│
│
└── examples/
    ├── app-repo-api/                # Exemplo: repo da API Cadastro
    │   └── k8s/
    │       ├── base/                # Manifests K8s base (Kustomize)
    │       └── overlays/dev/        # Overlay para dev
    └── app-repo-ia/                 # Exemplo: repo do Serviço IA
        └── k8s/
            ├── base/                # Manifests + Qdrant StatefulSet
            └── overlays/dev/
```

## Modelo Multi-Repo

| Repositório | Conteúdo | Responsabilidade |
|---|---|---|
| `arch-analyzer-infra` (este) | Terraform + GitOps config | Infraestrutura AWS |
| `arch-analyzer-api` | Código + K8s manifests | API Cadastro |
| `arch-analyzer-ia` | Código + K8s manifests | Serviço de IA |

## Pré-requisitos

- Terraform >= 1.5.0
- AWS Academy Lab ativo
- AWS CLI v2 configurado com credenciais do Lab
- kubectl instalado
- helm instalado (para post-deploy)

## Quick Start

```bash
# 1. Clone o repositório
git clone <repo-url>
cd arch-analyzer-infra

# 2. Configure as variáveis
cp terraform.tfvars.example terraform.tfvars
# Edite terraform.tfvars com seus valores (lab_role_arn obrigatório)

# 3. Inicialize o Terraform
terraform init

# 4. Verifique o plano
terraform plan

# 5. Aplique a infraestrutura
terraform apply

# 6. Configure o kubeconfig
aws eks update-kubeconfig --region us-east-1 --name $(terraform output -raw eks_cluster_name)
```

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
- **EKS Subnet Tags**: tags kubernetes.io corretas para service discovery

### Limitações (AWS Academy)
- **ALB HTTP only**: sem HTTPS (ACM pode não estar disponível)
- **LabRole**: IAM role pré-existente do Academy para EKS e nodes
- **RDS single-AZ**: sem Multi-AZ (custo)
- **Nodes em subnets públicas**: evita NAT Gateway (~$32/mês)

## Estimativa de Custos

| Recurso | Especificação | Custo Estimado/mês |
|---|---|---|
| EKS Control Plane | Gerenciado | ~$73 |
| EC2 EKS Nodes (x2) | t3.small | ~$30 |
| RDS PostgreSQL | db.t3.micro, single-AZ | ~$13 |
| ALB | HTTP listener | ~$16 |
| S3 + SQS | Uso moderado | ~$2 |
| **Total estimado** | | **~$134/mês** |

> **Nota**: O custo do EKS control plane (~$73/mês) é o principal fator de aumento comparado a K3s. Em troca, obtém-se cluster gerenciado, auto-scaling, melhor integração AWS e menor overhead operacional.

## Decisões Técnicas

| Decisão | Justificativa |
|---|---|
| EKS (gerenciado) | Cluster Kubernetes gerenciado pela AWS, auto-scaling, menor overhead |
| EKS Managed Node Group | Nodes gerenciados com AMI otimizada, rolling updates automáticos |
| Kustomize (em vez de Helm) | Simplicidade para manifests de apps, patches nativos K8s |
| Qdrant no EKS | Banco vetorial leve, roda como StatefulSet |
| NGINX Ingress (NodePort) | Integração com ALB via NodePort, controle de roteamento no cluster |
| Terraform K8s Config | Configuração K8s via Terraform, sem scripts externos |

## Outputs do Terraform

Após `terraform apply`, os seguintes outputs estarão disponíveis:

- `eks_cluster_name` - Nome do cluster EKS
- `eks_cluster_endpoint` - URL do API server EKS
- `eks_cluster_version` - Versão do Kubernetes
- `alb_dns_name` - URL de acesso à aplicação
- `db_endpoint` - Endpoint do RDS
- `s3_diagrams_bucket` - Nome do bucket S3
- `sqs_processing_queue_url` - URL da fila SQS
- `kubeconfig_command` - Comando AWS CLI para configurar kubectl
