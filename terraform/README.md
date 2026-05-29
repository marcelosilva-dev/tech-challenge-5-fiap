# Terraform — SolidaryTech (FASE 5)

Infraestrutura como Codigo para o Hackathon SolidaryTech. Reusa o padrao modular validado na FASE 3 do ToggleMaster, com evolucoes para:
- Suporte a multi-environment (primary + DR) via `environments/`
- Tags FinOps obrigatorias aplicadas globalmente
- ECR com lifecycle policy + scan on push
- SQS com Dead Letter Queue
- DynamoDB com PITR habilitado e preparado para Global Tables
- EKS com OIDC provider (pre-requisito para IRSA)

## Estrutura

```
terraform/
├── modules/                # blocos reutilizaveis (regiao-agnostico)
│   ├── networking/         # VPC + subnets + NAT + IGW + RTs + SGs
│   ├── eks/                # cluster + node group + OIDC provider
│   ├── databases/          # 2x RDS PostgreSQL + 1 DynamoDB
│   ├── messaging/          # SQS standard + DLQ
│   └── ecr/                # 3 repositorios com lifecycle policy
└── environments/
    ├── primary/            # us-east-1 (producao ativa)
    └── dr/                 # us-west-2 (Warm Standby - Sprint 6)
```

## Backend remoto

**Nomes sufixados com AWS Account ID** porque bucket S3 e GLOBAL entre todas as contas. Cada grupo da FIAP tem seu proprio bucket sem conflito:

- `s3://tc5-solidarytech-tfstate-{ACCOUNT_ID}/environments/primary/terraform.tfstate`
- `s3://tc5-solidarytech-tfstate-{ACCOUNT_ID}/environments/dr/terraform.tfstate`

Lock via DynamoDB: `tc5-solidarytech-tflock-{ACCOUNT_ID}`.

O `backend.tf` declara configuracao parcial — bucket e dynamodb_table sao injetados em runtime via `-backend-config` no `terraform init` (ja automatizado em `scripts/setup-full.sh`).

## Tags FinOps obrigatorias

Aplicadas via `default_tags` no provider AWS (propagam para todos os recursos suportados):

| Tag | Valor |
|-----|-------|
| `Project` | `SolidaryTech` |
| `Environment` | `Production` (primary) ou `DR` (dr) |
| `CostCenter` | `NGO-Core` |
| `ManagedBy` | `Terraform` |
| `Repository` | `rivachef/TC5-SolidaryTech` |

## Subir ambiente primary (1 comando)

```bash
# Exportar credenciais AWS Academy ativas
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."

# Da raiz do repo:
./scripts/setup-full.sh
```

O script `setup-full.sh` ja automatiza:
- Deteccao do AWS Account ID
- Auto-criacao do `terraform.tfvars` (com `lab_role_arn` correto e `db_password` random de 24 chars)
- Bootstrap idempotente do bucket S3 + tabela DynamoDB (com ACCOUNT_ID no nome)
- `terraform init` com `-backend-config` dinamico
- `terraform plan` + confirmacao interativa
- `terraform apply` (~15-20 min)
- `aws eks update-kubeconfig` + `kubectl get nodes` para validar

## Destruir ambiente (fim do dia, economia)

```bash
./scripts/destroy-all.sh
```

Cleanup robusto: K8s LBs -> LBs orfaos -> ENIs orfas -> `terraform destroy`. Bucket de state e DynamoDB lock sao **preservados** para proximo apply.

## AWS Academy

LabRole obrigatorio (nao posso criar IAM roles customizados). Sessao expira em 4h — renovar `AWS_SESSION_TOKEN` periodicamente.

ARN tipicamente: `arn:aws:iam::<ACCOUNT_ID>:role/LabRole`

Para descobrir:
```bash
aws sts get-caller-identity
```
