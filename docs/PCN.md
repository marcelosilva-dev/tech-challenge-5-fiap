# Plano de Continuidade de Negócios (PCN) — SolidaryTech

> Documento executivo para a diretoria da SolidaryTech.
> Define como garantimos que as doações não param mesmo em caso de desastre na nuvem primária.

## Sumário Executivo

A SolidaryTech depende da plataforma digital para receber doações em tempo real. Uma indisponibilidade prolongada significa:

- **Perda direta de doações** (doadores tentam novamente em concorrentes ou desistem)
- **Erosão de confiança** da rede nacional que apoia a iniciativa
- **Risco reputacional** para ONGs parceiras

Este PCN define **objetivos de recuperação formais** (RTO/RPO), a **arquitetura de continuidade** e os **procedimentos** para garantir que o caminho crítico de doações sobreviva a falhas regionais da AWS.

---

## 1. Objetivos de Recuperação por Serviço

| Componente | Criticidade | **RTO** (tempo máx p/ recuperar) | **RPO** (perda máx de dados) | Justificativa |
|------------|------------|----------------------------------|------------------------------|---------------|
| **donation-service** (Hot Path) | 🔴 Crítica | **15 minutos** | **5 minutos** | Doações são o caminho crítico — receita direta. RDS read replica cross-region (lag típico < 1 min) + promoção manual |
| **volunteer-service** | 🟡 Importante | **5 minutos** | **Segundos** | DynamoDB **Global Tables** replica nativamente entre regiões. Failover via DNS, sem perda de dados |
| **ngo-service** | 🟢 Não-crítico | **4 horas** | **24 horas** | Cadastro de ONGs muda raramente. Restore via Velero (snapshot diário) é suficiente |
| ArgoCD + GitOps | 🟡 Importante | **15 minutos** | **0 (Git)** | Manifests vivem no Git — reinstalação no DR é imediata |
| Stack monitoring | 🟢 Não-crítico | **1 hora** | N/A | Reinstalável via Helm; logs antigos podem ser perdidos |

### Por que esses números?

**RTO 15min para donations:**
- Tempo médio de aceitação do mercado para apps de doação (Stripe, PayPal: ~5-10min em incidentes)
- Limite acima do qual a ONG perde >$10k em receita (estimativa por hora de pico)
- Tecnicamente alcançável com cluster DR "warm" pré-provisionado e RDS replica promovida

**RPO 5min para donations:**
- Lag típico de RDS Cross-Region Read Replica em condições normais (medido em testes: 30s-2min)
- Aceitável: doações novas durante a janela podem ser re-confirmadas via SQS (mensagem persiste 14 dias)

---

## 2. Cenários de Desastre Cobertos

| Cenário | Probabilidade | Resposta |
|---------|--------------|----------|
| Falha de 1 AZ em us-east-1 | Alta (anual) | Multi-AZ EKS — failover automático, sem ação |
| Falha REGIONAL em us-east-1 (todas AZs) | Baixa (década) | **Failover Warm Standby para us-west-2** (este documento) |
| Corrupção lógica (delete acidental, ransomware) | Média | **Velero restore** de backup point-in-time |
| Falha de fornecedor externo (New Relic, etc.) | Média | Degradação graciosa — sistema funciona sem APM |
| Esgotamento de cota AWS | Baixa | Procedimento de aumento de limite + DR temporário em conta alternativa |

---

## 3. Arquitetura de Continuidade

```
                  ┌──────────────────────────────┐
                  │     CLOUD AWS — Primary       │
                  │     Region: us-east-1         │
                  │                                │
                  │  EKS cluster (3 nodes)        │
                  │  donation-service ×3 (Hot)    │
                  │  ngo-service ×2               │
                  │  volunteer-service ×2         │
                  │  RDS donation-db (primary) ───┼──┐
                  │  RDS ngo-db (single)          │  │
                  │  DynamoDB volunteers ─────────┼──┤
                  │  SQS solidary-donations       │  │
                  └──────────────┬────────────────┘  │
                                 │                    │
                                 │ ←─ Velero ────────┐│
                                 │   daily snapshot  ││
                                 │                   ▼▼
                                 │              ┌─────────────────────┐
                                 │              │  S3 bucket us-west-2 │
                                 │              │  (manifests + state) │
                                 │              └─────────────────────┘
                                 │                    │
                                 │ ←─── Replicação ───┤
                                 │   contínua         │
                                 │                    ▼
                  ┌──────────────┴────────────────┐
                  │     CLOUD AWS — DR (Warm)     │
                  │     Region: us-west-2         │
                  │                                │
                  │  EKS cluster (1 node)         │  ← skeleton, custo mínimo
                  │  donation-service ×0 (off)    │
                  │  RDS donation-db (replica) ◄──┘  ← read replica, promovível
                  │  DynamoDB volunteers ◄──         ← Global Tables nativo
                  │  SQS solidary-donations (vazia) │
                  └────────────────────────────────┘
```

### Componentes e estratégia de replicação

| Componente | Replicação primary → DR | Tipo |
|-----------|------------------------|------|
| **donation-db** (PostgreSQL) | Cross-Region Read Replica | Assíncrono (~30s-2min lag) |
| **volunteers** (DynamoDB) | Global Tables | Bidirecional (~segundos) |
| **ngo-db** (PostgreSQL) | Sem replica — backup Velero diário | RPO 24h aceitável |
| **SQS** | Não replicada — recriada em failover | Mensagens em voo se perdem (recovery via app) |
| **Manifests K8s + ArgoCD** | Git (GitHub) | Real-time via push |
| **Container images** | ECR cross-region replication | Automático |

### Custo da postura "Warm Standby"

| Item | Custo/dia (us-west-2) |
|------|----------------------|
| EKS control plane (parado, on-demand) | $0 (criado on-failover) |
| 1× RDS donation-db replica (db.t3.micro) | ~$0.40 |
| DynamoDB Global Tables (PAY_PER_REQUEST) | ~$0 (sem tráfego) |
| S3 storage (Velero backups, ~5GB) | ~$0.12 |
| Cross-region data transfer (replica + Velero) | ~$0.10 |
| **Total daily DR posture** | **~$0.62** |

**ROI:** US$ 18/mês para garantir RTO 15min vs perda potencial de US$ 10k+/hora em incidente regional → payback em **< 4 minutos** de incidente evitado.

---

## 4. Procedimento de Failover (resumo)

Detalhe técnico em [`DR-STRATEGY.md`](DR-STRATEGY.md). Visão executiva:

1. **Detecção** (até 5 min)
   - AlertManager + New Relic APM detectam degradação regional
   - PagerDuty escala para SRE on-call
2. **Decisão GO/NO-GO** (5 min)
   - SRE confirma escopo (1 AZ vs região inteira) consultando AWS Status Page
   - Comunicação imediata a stakeholders (ONGs parceiras) via Discord/email
3. **Execução do failover** (até 5 min)
   - `./scripts/dr-failover.sh` automatiza:
     - Promove RDS read replica em us-west-2 → primary
     - Provisiona node group EKS DR (scale 1→3 nodes)
     - Velero restore dos manifests
     - Atualiza secrets com novos endpoints
     - Aplica ArgoCD Applications no cluster DR
4. **Cutover de tráfego** (até 5 min)
   - DNS Route53 (futuro) ou comunicação manual de novo Ingress URL
   - Pods entram em Running
5. **Validação** (contínua)
   - Health checks dos 3 serviços
   - Throughput de doações monitorado
   - Latência P95 dentro do SLO

**Total: até 20 minutos worst-case. Target: 15 minutos.**

---

## 5. Procedimento de Failback

Após restauração da região primária:

1. Validar saúde de us-east-1 (mín. 24h estável)
2. Restabelecer replicação reversa (donation-db DR → primary)
3. Aguardar lag zero (~minutos)
4. Cutover reverso de DNS
5. Decomissionar pods DR (scale-to-zero)
6. Manter RDS DR como read replica permanente

---

## 6. Testes e Drills

| Tipo de teste | Frequência | Responsável | Métrica |
|---------------|-----------|-------------|---------|
| **DR drill automatizado** (GitHub Actions) | Mensal | SRE | RTO atingido? Validação E2E em ambiente isolado |
| **Failover real controlado** (Game Day) | Trimestral | SRE + Eng | Sucesso end-to-end, time response |
| **Velero restore test** | Mensal | SRE | Backup recente é restaurável? |

Documentar resultados em `docs/drills/YYYY-MM-DD-drill-report.md`.

---

## 7. Comunicação durante Incidente

| Stakeholder | Canal | Conteúdo |
|------------|-------|----------|
| Diretoria SolidaryTech | Email + WhatsApp | Resumo executivo, RTO esperado |
| ONGs parceiras | Status page público | Próximas atualizações a cada 15min |
| Doadores | Twitter/Instagram da SolidaryTech | "Em manutenção, suas doações estão seguras" |
| Time de Engenharia | Discord war-room | Comunicação técnica contínua |

---

## 8. Aprovações

| Papel | Responsável | Data |
|-------|------------|------|
| Owner do PCN | SRE Lead | 2026-05-29 |
| Aprovação Executiva | Diretoria SolidaryTech | (pendente) |
| Revisão Legal/LGPD | Compliance | (pendente) |

**Próxima revisão:** trimestral OU após qualquer incidente real / drill.
