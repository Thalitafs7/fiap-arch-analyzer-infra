# Deploy no AWS Academy — Guia Completo

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| AWS CLI | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| Terraform | 1.5+ | [developer.hashicorp.com/terraform](https://developer.hashicorp.com/terraform/install) |
| kubectl | 1.29+ | [kubernetes.io/docs](https://kubernetes.io/docs/tasks/tools/) |
| Docker | 24+ | [docs.docker.com](https://docs.docker.com/get-docker/) |
| PowerShell | 7+ | [github.com/PowerShell](https://github.com/PowerShell/PowerShell/releases) |
| Python 3 + pyyaml | 3.10+ | `pip install pyyaml` |

---

## Estrutura de repositórios esperada

```
c:\projects\
├── fiap-arch-analyzer-infra\          ← este repo (Terraform + scripts)
├── fiap-arch-analyzer-api-gateway\
├── fiap-arch-analyzer-auth-service\
├── fiap-arch-analyzer-registration-service\
├── fiap-arch-analyzer-processing-service\
└── fiap-arch-analyzer-report-service\
```

---

## Passo 1 — Credenciais AWS Academy

No portal do Learner Lab, clique em **AWS Details** e copie as credenciais:

```powershell
# Windows — configure as variáveis de ambiente
$env:AWS_ACCESS_KEY_ID     = "ASIA..."
$env:AWS_SECRET_ACCESS_KEY = "..."
$env:AWS_SESSION_TOKEN     = "..."
$env:AWS_DEFAULT_REGION    = "us-east-1"
```

Ou edite `~\.aws\credentials`:
```ini
[default]
aws_access_key_id     = ASIA...
aws_secret_access_key = ...
aws_session_token     = ...
```

> ⚠️ Credenciais do Academy expiram em ~4h. Se o deploy falhar com `ExpiredToken`, renove e reexecute.

---

## Passo 2 — Configurar terraform.tfvars

```powershell
cd c:\projects\fiap-arch-analyzer-infra
```

Edite o arquivo `terraform.tfvars` (já criado como template):

```hcl
# Obrigatório: ARN do LabRole
# AWS Console → IAM → Roles → LabRole → copie o ARN
lab_role_arn = "arn:aws:iam::123456789012:role/LabRole"

# Senhas — gere com: openssl rand -base64 32
db_password     = "SenhaForte16Chars!"
jwt_signing_key = "ChaveJWT32CaracteresMinimo!!"
mongo_password  = "SenhaMongoForte!!"
redis_password  = "SenhaRedisForte!!"

# LLM Keys (obrigatório para o processing-service)
llm_api_keys = {
  OPENAI_API_KEY    = "sk-..."
  ANTHROPIC_API_KEY = "sk-ant-..."
}
```

---

## Passo 3 — Deploy completo (automatizado)

```powershell
cd c:\projects\fiap-arch-analyzer-infra
pwsh scripts\deploy-all.ps1
```

O script executa em ordem:
1. Valida que todos os repos existem localmente
2. Verifica credenciais AWS (`sts get-caller-identity`)
3. `terraform init` + `terraform apply` (cria EKS, RDS, ECR, SQS, S3, MongoDB, Redis, ALB)
4. Atualiza o `kubeconfig` para o cluster criado
5. Build + push de cada imagem para o ECR
6. Aguarda MongoDB e Redis ficarem prontos
7. Aplica os manifests K8s em ordem: `auth` → `registration/report/processing` → `api-gateway`
8. Aguarda rollout de cada deployment
9. Valida health de todos os serviços via ALB
10. Gera relatório em `artifacts/validation-report-*.json`

**Tempo estimado:** 25–40 minutos (EKS leva ~15min para provisionar)

---

## Passo 4 — Verificar o deploy

```powershell
# Status dos pods
kubectl get pods -A

# URL do ALB
terraform output alb_dns_name

# Health de cada serviço
$alb = terraform output -raw alb_dns_name
curl "http://$alb/api/auth/health"
curl "http://$alb/api/registration/health"
curl "http://$alb/api/analyses/health"
curl "http://$alb/api/reports/health"
curl "http://$alb/api/gateway/health"
```

---

## Deploy via GitHub Actions (CI/CD)

Cada repositório tem um workflow `cd-main.yml` que dispara no push para `main`.

### Secrets necessários em cada repositório GitHub

| Secret | Onde obter |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS Academy → AWS Details |
| `AWS_SECRET_ACCESS_KEY` | AWS Academy → AWS Details |
| `AWS_SESSION_TOKEN` | AWS Academy → AWS Details |

Configure em: **GitHub repo → Settings → Secrets and variables → Actions**

> ⚠️ O `AWS_SESSION_TOKEN` expira. Para CI/CD contínuo, use OIDC com o LabRole (não disponível no Academy básico).

---

## Namespaces K8s

| Namespace | Serviços |
|---|---|
| `auth` | ms-auth-api |
| `arch-analyzer-api` | api-gateway, registration-service |
| `arch-analyzer-ia` | processing-service, celery-worker, report-service |
| `data` | mongodb, redis |
| `ingress-nginx` | nginx ingress controller |

---

## Portas e rotas

| Serviço | Porta interna | Rota ALB |
|---|---|---|
| api-gateway | 8080 | `/api/gateway/*` |
| auth-service | 5002 | `/api/auth/*` |
| registration-service | 5002 | `/api/registration/*` |
| processing-service | 8000 | `/api/analyses/*` |
| report-service | 8001 | `/api/reports/*` |

---

## Destruir a infraestrutura

```powershell
cd c:\projects\fiap-arch-analyzer-infra
terraform destroy -auto-approve
```

> ⚠️ Isso remove **tudo**: EKS, RDS, S3, ECR, SQS. Dados não recuperáveis.

---

## Troubleshooting

**Pods em `CrashLoopBackOff`:**
```powershell
kubectl logs -n <namespace> <pod-name> --previous
kubectl describe pod -n <namespace> <pod-name>
```

**Secrets Manager — init container falhando:**
```powershell
# Verifique se o LabRole tem permissão para secretsmanager:GetSecretValue
kubectl logs -n <namespace> <pod-name> -c secrets-sync
```

**ECR push negado:**
```powershell
# Renove o login ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
```

**Terraform — erro de permissão IAM:**
O AWS Academy usa `LabRole` com permissões restritas. Não é possível criar IAM roles/policies customizadas. O Terraform já está configurado para usar o `LabRole` existente.
