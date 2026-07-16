# Environment: DR (Disaster Recovery)

**Status:** Stub — sera preenchido no Sprint 6.

## Estrategia

**Warm Standby cross-region (us-west-2)** focado no `donation-service` (Hot Path):
- VPC + EKS espelho com tamanho **menor** (1 node) para reduzir custo
- DynamoDB Global Tables (replicacao nativa multi-region)
- RDS de `donation_db`: read replica cross-region, promovida em caso de failover
- RDS de `ngo_db`: backup via Velero (nao-critico)
- SQS recriada na regiao DR via Terraform

## Como ativar (futuro)

```bash
cd terraform/environments/dr
cp terraform.tfvars.example terraform.tfvars
# editar para apontar para outputs do primary (cross-region peering, replicas)
terraform init
terraform apply
```

## Arquivos pendentes (Sprint 6)

- `backend.tf` — state em `environments/dr/terraform.tfstate`
- `providers.tf` — `region = us-west-2`, default_tags com `Environment = "DR"`
- `variables.tf` — inclui referencias a recursos do primary (DB ARN, etc.)
- `main.tf` — chama os mesmos modulos com tamanhos menores + Global Tables
- `outputs.tf` — endpoints da regiao DR
- `terraform.tfvars.example`

## Tags FinOps (DR)

| Tag | Valor |
|-----|-------|
| `Project` | `SolidaryTech` |
| `Environment` | `DR` |
| `CostCenter` | `NGO-Core` |
| `ManagedBy` | `Terraform` |
| `Repository` | `marcelosilva-dev/tech-challenge-5-fiap` |

`Environment=DR` (em vez de Production) permite alertas separados de FinOps e filtros de billing.
