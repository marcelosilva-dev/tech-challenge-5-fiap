# FinOps Report — SolidaryTech

> Atende ao requisito do Tech Challenge FASE 5, item 2 (FinOps):
> "Implemente uma política de tags rigorosa diretamente no seu código
> Terraform... Crie uma projeção (Forecast) de custos mensais...
> Indique pelo menos uma recomendação prática de otimização."

---

## 1. Política de Tags (FinOps obrigatório)

### Tags aplicadas em TODO recurso AWS

Definidas via `default_tags` no provider AWS — propagam automaticamente
para todos os recursos suportados pelo Terraform AWS provider.

```hcl
# terraform/environments/primary/providers.tf
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Production"   # ou "DR" no environment de DR
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
      Repository  = "marcelosilva-dev/tech-challenge-5-fiap"
    }
  }
}
```

### Cobertura

| Recurso AWS | Tagueado? | Como |
|-------------|-----------|------|
| EC2 instances (EKS nodes) | ✅ | `launch_template.tag_specifications` + default_tags |
| EBS volumes | ✅ | default_tags via launch template |
| RDS instances | ✅ | default_tags |
| RDS snapshots | ✅ | `copy_tags_to_snapshot = true` |
| DynamoDB tables | ✅ | default_tags |
| SQS queues | ✅ | default_tags |
| ECR repositories | ✅ | default_tags |
| VPC + subnets + IGW + NAT | ✅ | default_tags + `Name` específico |
| ALB/NLB (criados pelo K8s) | ⚠️ | K8s não propaga tags AWS por default — fix futuro com AWS Load Balancer Controller |
| Velero S3 backups | ✅ | tags na criação via script |

### Tags adicionais por componente

Algumas resources têm tags **adicionais** ao default:

```hcl
# Exemplo: donation-service RDS (Hot Path)
tags = {
  Name      = "solidarytech-donation-db"   # já vem com default_tags
  Component = "database"
  Service   = "donation"
  Role      = "primary"                    # ou "cross-region-read-replica" no DR
}
```

### Filtros úteis no AWS Cost Explorer

```
Filter: tag:Project = SolidaryTech
   └─ Group by: tag:Environment   → comparar Production vs DR
   └─ Group by: tag:Service       → ver custo por microsserviço (DB)
   └─ Group by: tag:Component     → ver custo por camada (network, compute, database)
```

---

## 2. Forecast de custos mensais

### Setup atual rodando 24/7 (worst case)

| Componente | Quantidade | $/h | $/mês | % total |
|-----------|-----------|-----|-------|---------|
| **EKS control plane** | 1 cluster | $0.10 | $73.00 | 33% |
| **EC2 nodes** (t3.medium) | 3 | $0.0416 × 3 | $89.86 | 41% |
| **RDS PostgreSQL** db.t3.micro | 2 (ngo + donation) | $0.017 × 2 | $24.48 | 11% |
| **NAT Gateway** | 1 | $0.045 | $32.40 | 15% |
| **Elastic IP** (NAT) | 1 alocada | $0.005 (se idle) | $3.60 | 2% |
| **EBS gp3** (nodes 3×20GB) | 60GB | $0.08/GB | $4.80 | 2% |
| **EBS gp3** (RDS 2×20GB) | 40GB | $0.115/GB | $4.60 | 2% |
| **RDS backups** (7 dias retention) | ~7GB | $0.095/GB | $0.67 | <1% |
| **DynamoDB** PAY_PER_REQUEST | mínimo | ~$0 | ~$0 | 0% |
| **SQS** Standard | mínimo | ~$0 | ~$0 | 0% |
| **ECR storage** (3 repos × ~50MB × 10 imgs) | ~1.5GB | $0.10/GB | $0.15 | <1% |
| **S3** state + Velero | ~5GB | $0.023/GB | $0.12 | <1% |
| **CloudWatch logs** (EKS control plane) | ~5GB ingest | $0.50/GB | $2.50 | 1% |
| **Cross-region data transfer** (DDB Global Tables + RDS replica) | minimal | ~$0.10 | $3.00 | 1% |
| **DR posture** (RDS replica + Velero S3) | always-on | $0.40 + $0.12 | $15.60 | 7% |
| **TOTAL (24/7, sem DR ativado)** | | | **~$235/mês** | |
| **TOTAL (24/7, com DR posture)** | | | **~$250/mês** | |

### Setup real (uso dev: ~8h/dia × 22 dias)

A infra é destruída no fim do dia via `destroy-all.sh`:

| Item | $/mês com destroy diário |
|------|--------------------------|
| EKS + nodes + NAT + RDS (8h/dia × 22 dias) | ~$74 |
| S3 state + DDB lock (24/7, mínimo) | ~$0.20 |
| Velero backups (24/7) | ~$0.12 |
| **Total mensal (uso típico)** | **~$74** |

**Economia via destroy diário: 70%** vs always-on. Estratégia documentada
em `scripts/destroy-all.sh` e `setup-full.sh`.

### Cenário Hot Path (failover DR ativo)

| Componente | Adicional/mês |
|-----------|----------------|
| EKS DR cluster | $73 |
| 1 node t3.medium DR | $30 |
| NAT DR | $32 |
| Cross-region replication ativa | $5-10 |
| **Total adicional durante failover** | **~$140/mês** |

> Failover só ocorre durante incidente regional — exceção, não regra.
> RTO target: 15min. Custo aceitável vs perda de receita.

---

## 3. Recomendações de Otimização

### 🥇 #1 — DynamoDB: Scan → GSI (alta prioridade, FACIL)

**Problema:**
`volunteer-service` tem operação `GET /volunteers/{ngo_id}` implementada com `Scan + FilterExpression`:

```python
# microservices/volunteer-service/app.py
response = table.scan(
    FilterExpression=boto3.dynamodb.conditions.Attr('ngo_id').eq(ngo_id)
)
```

**Custo do Scan:** lê **toda** a tabela e depois filtra. Custo proporcional ao **tamanho total**, não ao número de resultados.

| Cenário | Scan cost | Query w/ GSI cost |
|---------|-----------|-------------------|
| 10k voluntários, busca 100 de 1 ONG | 10k RCUs ($0.25) | 100 RCUs ($0.0025) |
| 1M voluntários, busca 100 | 1M RCUs ($25) | 100 RCUs ($0.0025) |

**Escalabilidade:** Scan é O(n) com o tamanho da tabela; Query+GSI é O(k) com o número de resultados.

**Implementação:**
```hcl
# terraform/modules/databases/main.tf
resource "aws_dynamodb_table" "volunteers" {
  ...
  global_secondary_index {
    name            = "ngo_id-index"
    hash_key        = "ngo_id"
    projection_type = "ALL"
  }

  attribute {
    name = "ngo_id"
    type = "N"
  }
}
```

```python
# Em volunteer-service/app.py
response = table.query(
    IndexName='ngo_id-index',
    KeyConditionExpression=boto3.dynamodb.conditions.Key('ngo_id').eq(ngo_id)
)
```

**ROI estimado:** **99%+ de redução de custo** desse endpoint em qualquer escala.

---

### 🥈 #2 — RDS Reserved Instances (longo prazo)

**Problema:**
RDS db.t3.micro on-demand: **$0.017/h × 24 × 30 = $12.24/mês por instância**.

**Solução:** Reserved Instance (RI) 1-year No Upfront:
- ~$8/mês por instância (35% economia)
- Ou Reserved 1-year All Upfront: ~$7/mês (45% economia)

**Aplicabilidade:** Se a SolidaryTech crescer e parar de destruir diariamente, ROI imediato.

**Limitação atual:** AWS Academy não permite criar RIs (apenas on-demand).

---

### 🥉 #3 — SQS Long Polling (free, mas frequentemente esquecido)

**Problema:**
SQS Short Polling (default) faz consumidor "girar" perguntando "tem mensagem?". Cada chamada é **cobrada**.

**Solução:** Configurar `ReceiveMessageWaitTimeSeconds = 20` (max) na queue. Reduz # de chamadas em até **90%** em filas com baixo throughput.

**Implementação:**
```hcl
# terraform/modules/messaging/main.tf (futuro fix)
resource "aws_sqs_queue" "main" {
  ...
  receive_wait_time_seconds = 20  # long polling
}
```

**ROI:** SQS é pay-per-request. Mesmo com a queue vazia, polling curto custa. Long polling reduz pra ~zero.

**Hoje:** Nosso `donation-service` só publica, não consome. Mas se adicionarmos consumer (Sprint futuro), aplicar antes de subir.

---

### #4 — Rightsizing de pods (validado no Sprint 5)

**Aplicação atual:** YAMLs em `gitops/<svc>/deployment.yaml` têm `resources.requests` e `limits` conservadores:

| Service | requests CPU | requests Mem | limits CPU | limits Mem |
|---------|--------------|--------------|------------|------------|
| ngo | 100m | 128Mi | 500m | 512Mi |
| donation (Hot Path) | 200m | 128Mi | 1000m | 512Mi |
| volunteer | 100m | 128Mi | 500m | 512Mi |

**Observação real no cluster:**
```bash
kubectl top pods -n solidarytech
# CPU usage típico: 5-15m por pod (em load baixo)
# Memory usage típico: 60-90Mi por pod
```

**Próxima iteração:** baseando em métricas Prometheus de 7 dias, reduzir requests para o p95 do uso real. Isso libera capacidade para mais pods/node (lembrando o limite de 17 pods/t3.medium).

---

### #5 — NAT Gateway → VPC Endpoints (avançado)

**Problema:** NAT Gateway custa $32/mês + $0.045/GB de dados. Tráfego AWS-to-AWS (acesso a SQS, DynamoDB, ECR, S3) atravessa NAT desnecessariamente.

**Solução:** VPC Endpoints (Gateway para S3/DynamoDB grátis; Interface para outros serviços $0.01/h por AZ × 3 AZs = $21/mês).

**Trade-off:**
- VPC Endpoint S3/DynamoDB: **grátis**, **economia ~$5-10/mês** em data transfer
- VPC Endpoint Interface (ECR, SQS): $21/mês, economiza se tráfego > 470GB/mês

**Aplicabilidade:** ECR pull de imagens grandes vale a pena. Em produção real, sim.

---

### #6 — EKS Spot Instances para node group (avançado)

**Problema:** 3× t3.medium On-Demand = ~$90/mês.

**Solução:** Mixed Instances Policy com 80% Spot + 20% On-Demand:
- Spot t3.medium: ~$0.012/h (~70% economia)
- 3 nodes mixed: ~$30/mês vs $90/mês

**Trade-off:** Spot instances podem ser terminadas com 2min de aviso. Para workload stateless (que é o nosso — DBs externos), Kubernetes recoloca pods em outro node. Risco mitigado.

**Aplicabilidade:** AWS Academy não permite Spot. Em produção, sim.

---

## 4. Roadmap de otimização (priorizado)

| # | Item | Esforço | ROI mensal | Quando |
|---|------|---------|------------|--------|
| 1 | DynamoDB Scan→GSI | 2h | 99%+ desse endpoint | **Imediato** |
| 2 | SQS Long Polling | 5min | $1-5 | **Imediato** |
| 3 | Rightsizing pods (-30% requests) | 1h | Permite mais workloads sem mais nodes | Sprint+1 |
| 4 | VPC Endpoints S3/DDB | 30min | $5-10 | Sprint+2 |
| 5 | RDS Reserved Instances | 5min | $4-5 | Quando sair de AWS Academy |
| 6 | EKS Spot 80% | 4h | $50-60 | Quando sair de AWS Academy |

---

## 5. Evidências

**AWS Tag Editor — 22 recursos com tag `Project = SolidaryTech` (us-east-1):**

![AWS Tag Editor — 22 recursos tagged](screenshots/12-aws-tag-editor.png)

Cobertura observada:
- **EC2:** 13 recursos (VPC, IGW, NAT Gateway, EIP, 4 subnets, 2 route tables, 2 security groups, launch template)
- **RDS:** 5 recursos (2 DBs + 2 snapshots automáticos + 1 subnet group)
- **EKS:** 2 recursos (cluster + node group)
- **DynamoDB:** 2 tabelas (volunteers + tflock)
- **SQS:** 2 filas (main + DLQ)
- **ECR:** 3 repositórios (visíveis via CLI; UI mostra subset)

Total reportado pelo Resource Tagging API: **27 recursos** (incluindo route table associations e outros recursos internos não visíveis na UI).

> **AWS Cost Explorer:** filtragem por tag exige ativação manual em **Billing > Cost allocation tags** + processamento de até **24h** para histórico aparecer. Como infra foi provisionada hoje, Tag Editor é a evidência imediata equivalente.

---

## 6. Resumo executivo (1 página)

| | |
|---|---|
| **Política de tags** | 5 default_tags aplicadas a 100% recursos Terraform-gerenciados |
| **Custo atual (always-on)** | ~$235/mês |
| **Custo atual (uso real, destroy diário)** | ~$74/mês (-70%) |
| **Maior otimização identificada** | DynamoDB Scan → GSI (-99% naquele endpoint) |
| **Otimizações imediatas (esforço < 1h)** | GSI, SQS Long Polling |
| **Otimizações futuras** | VPC Endpoints, RIs, Spot Instances |
| **Filtro Cost Explorer** | `tag:Project = SolidaryTech` |
