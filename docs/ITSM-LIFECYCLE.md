# Ciclo de Vida de Incidentes (ITSM) — SolidaryTech

> Atende ao requisito do Tech Challenge FASE 5, item 3 (ITSM/AIOps):
> "desenhe o fluxo de vida de um incidente da SolidaryTech (da detecção
> via AIOps/Alerta até o Post-Mortem e comunicação aos stakeholders)."

## Visão geral do fluxo

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                       │
│   [1] DETECÇÃO          ──→   [2] TRIAGEM        ──→  [3] MITIGAÇÃO   │
│                                                                       │
│   Prometheus rules            On-call avalia          Auto: workflow  │
│   New Relic AIOps             severidade real         self-healing    │
│   AWS Health Dashboard        Cria warroom Discord    Manual: runbook │
│        │                            │                       │         │
│        ▼                            ▼                       ▼         │
│   Alertmanager                 PagerDuty incidente    Cluster opera   │
│        │                            │                                 │
│        ├──→ PagerDuty (ITSM)        │                                 │
│        ├──→ Discord (ChatOps)       │                                 │
│        └──→ GH Actions self-heal    │                                 │
│                                     │                                 │
│                                     ▼                                 │
│   [4] COMUNICAÇÃO       ←──  [5] RESOLUÇÃO       ←──  [6] POST-MORTEM │
│                                                                       │
│   Status page externa         SLO + Error Budget       Doc blameless  │
│   Email diretoria             validacao                Action items   │
│   Discord time interno        APM Service Map sai     Schedule review │
│   Twitter / Instagram         do vermelho                             │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Fase 1: Detecção (0-2 min)

### Fontes de sinal (multi-camada)

| Fonte | Tipo | O que detecta |
|-------|------|---------------|
| **Prometheus PrometheusRules** | Métricas | Erros 5xx, latência P95, pod crash, recursos |
| **New Relic Applied Intelligence** | AIOps | Anomalias comportamentais (latência atípica para o horário, erros em padrões raros) |
| **AWS Health Dashboard** | Infra | Falha regional/AZ na AWS |
| **GitGuardian** | Security | Secret exposto em commit |
| **Velero Backup** | DR | Backup diário falhou (RPO em risco) |

### Roteamento (Alertmanager)

```
critical  →  PagerDuty (cria incidente) + Discord (visibilidade) + GitHub Actions (self-heal)
warning   →  Discord apenas
SLO burn  →  PagerDuty imediato + Discord + escala SRE
```

Config: [`gitops/monitoring/alerting/alertmanager-config.yaml.example`](../gitops/monitoring/alerting/alertmanager-config.yaml.example)

---

## Fase 2: Triagem (2-5 min)

**SRE on-call recebe page do PagerDuty.** Em 2min:

### Checklist rápido (runbook genérico)

1. **Confirmar via Grafana** — alerta é real ou false-positive?
2. **Verificar AWS Status Page** — incidente regional?
3. **Olhar New Relic Service Map** — qual componente é a causa raiz?
4. **Determinar severidade real:**
   - **SEV-1** (P1): Hot Path donation-service caído ou SLO em fast burn → escala todo o time
   - **SEV-2** (P2): Outro serviço caído ou erro >5% por >10min
   - **SEV-3** (P3): Degradação parcial / componente não-crítico
5. **Abrir war-room no Discord** (`#incident-YYYYMMDD-HHMM`)
6. **Acknowledge no PagerDuty** (relógio começa pro RTO)

### Decisão GO/NO-GO para Disaster Recovery
Se SEV-1 + impacto regional confirmado → ver [DR-STRATEGY.md](DR-STRATEGY.md) → executar `scripts/dr-failover.sh`.

---

## Fase 3: Mitigação (5-15 min)

### Automática — primeiro recurso

| Sintoma | Acionado por | Ação |
|---------|--------------|------|
| Pod em CrashLoop | Alertmanager → GitHub Actions `self-healing` | `kubectl rollout restart deployment/<svc>` |
| Pod NotReady > 5min | Idem | Idem |
| Falha de DNS resolution | (manual) | Verificar SG + restart pods afetados |

**Workflow:** [`.github/workflows/self-healing.yaml`](../.github/workflows/self-healing.yaml)

**Trigger manual** (DEMO ou emergência):
```bash
gh workflow run self-healing.yaml \
  -f service=donation-service \
  -f reason="Manual: latência alta detectada via Grafana"
```

### Manual — runbooks por sintoma

#### Runbook 1: `DonationSLOFastBurn`

**Sintoma:** SLO de availability consumindo error budget em ritmo >14.4× (esgota em <2h).

**Passos:**
1. Confirmar via Grafana → SolidaryTech Overview → painel "Error Rate"
2. New Relic Service Map → identificar serviço com erro
3. `kubectl logs -n solidarytech -l app=donation-service --tail=100 | grep ERROR`
4. Verificar DB connectivity:
   ```bash
   kubectl exec -n solidarytech deployment/donation-service -- /bin/sh -c "..."
   ```
5. Se DB: ver [`docs/DR-STRATEGY.md`](DR-STRATEGY.md) sobre RDS
6. Se SQS: `aws sqs get-queue-attributes ...`
7. Última opção: `dr-failover.sh` (ver PCN)

#### Runbook 2: `HighErrorRate5xx`

**Sintoma:** Algum serviço com >5% de erros 5xx por 2min.

**Passos:**
1. Confirmar serviço afetado: `{{ $labels.service_name }}` no alerta
2. `kubectl logs -n solidarytech -l app=<service> --tail=100`
3. Verificar deploy recente: `kubectl rollout history deployment/<service>`
4. **Rollback se necessário:** `kubectl rollout undo deployment/<service>`
5. Se persistir: escalar SEV-2 → SEV-1

#### Runbook 3: `PodCrashLooping`

**Sintoma:** Container reinicia >3× em 15min.

**Passos:**
1. `kubectl describe pod <pod> -n solidarytech` → ver Events
2. `kubectl logs <pod> -n solidarytech --previous` → última saída antes do crash
3. Causas comuns:
   - OOM (memory limit baixo) → ajustar `limits` em `gitops/<svc>/deployment.yaml`
   - Dependência ausente (DB/SQS) → ver secrets
   - Health check muito agressivo → ajustar `livenessProbe`
4. Self-healing já tentou — se ainda crash, intervenção humana

---

## Fase 4: Resolução (15-30 min)

### Critérios de "resolvido"

1. **Métricas saudáveis no Grafana** por 5 min consecutivos
   - Error rate < 1%
   - Latência P95 < 300ms (donation-service)
   - 0 pods em CrashLoop
2. **SLO error budget** parou de consumir aceleradamente
3. **New Relic Service Map** todos componentes verdes
4. **Smoke test E2E:**
   ```bash
   curl http://$INGRESS/donations/health → 200
   curl -X POST .../donations -d '{...}' → 201
   ```

### Encerrar incidente

1. **Resolve no PagerDuty** (relógio para — calcula MTTR)
2. **Comunicar resolução** (Fase 4)
3. **Agendar post-mortem em 48h**

---

## Fase 5: Comunicação durante e pós-incidente

| Stakeholder | Canal | Frequência | Conteúdo |
|------------|-------|-----------|----------|
| Time eng (interno) | Discord `#incident-...` | Tempo real | Updates técnicos brutos, comandos rodados |
| Diretoria SolidaryTech | Email + WhatsApp | A cada 30min | Resumo executivo, RTO esperado, próximas ações |
| ONGs parceiras | Status page público (futuro) | A cada 15min | "Serviço degradado — equipe ciente — ETA X" |
| Doadores | Twitter/Instagram da SolidaryTech | 1× início + 1× resolução | Mensagem em PT-BR não-técnica |
| Compliance/Legal | Email | Pós-incidente | Se houve perda/exposição de dados |

### Template de comunicação executiva (durante)

```
Assunto: [INCIDENTE EM CURSO] SolidaryTech — donation-service degradado
Severidade: SEV-1
Início: 14:32 BRT
Status atual: Mitigação em andamento (self-healing executou)
Impacto: Doações com latência elevada (>2s) ou erro intermitente
ETA resolução: 15 minutos (RTO Hot Path)
Próximo update: em 15min ou na resolução, o que vier primeiro
War-room: Discord #incident-20260529-1432
```

---

## Fase 6: Post-Mortem (48h após resolução)

### Filosofia: **blameless**
Foco em **sistemas e processos**, não pessoas. Erros são oportunidades de aprendizado.

### Template

Salvar em `docs/postmortems/YYYY-MM-DD-incident-short-name.md`:

```markdown
# Post-Mortem: <título curto>

**Data do incidente:** YYYY-MM-DD HH:MM BRT
**Duração total:** HHh MMmin
**Severidade:** SEV-?
**MTTR:** XXmin (target: 15min Hot Path)
**Owner:** @username

## Resumo executivo (2-3 frases)
...

## Impacto
- Doações perdidas estimadas: $X
- Tempo de degradação: HH:MM até HH:MM
- ONGs parceiras impactadas: N
- Comunicação enviada a stakeholders? ✓/✗

## Timeline
| Hora (BRT) | Evento | Quem |
|-----------|--------|------|
| 14:32 | PagerDuty page recebido | Alertmanager |
| 14:34 | SRE on-call acknowledges | @user |
| 14:36 | War-room aberta no Discord | @user |
| 14:38 | Self-healing workflow rodou (rollout restart) | GitHub Actions |
| 14:45 | Métricas voltam ao normal | - |
| 14:48 | Incidente resolvido | @user |

## Causa raiz (Five Whys)
1. **Por que** o donation-service teve erro 5xx?
   → Pool de conexões DB esgotado.
2. **Por que** o pool esgotou?
   → Aumento súbito de tráfego (campanha em rede nacional).
3. **Por que** o pool não escalou?
   → `max_connections=10` no SimpleConnectionPool, hardcoded.
4. **Por que** não havia auto-scaling do pool?
   → Decisão da FASE 2 mantida sem revisão.
5. **Por que** não detectamos antes?
   → Faltava alerta de "pool saturation" — apenas erro 5xx.

## O que funcionou bem ✓
- Alertmanager detectou em <1min
- Self-healing reduziu tempo manual
- Discord war-room agilizou coordenação

## O que poderia ser melhor ✗
- Auto-scaling do pool de conexões
- Alerta preditivo de saturação
- Runbook estava incompleto

## Action Items (commit em board de produto)
| ID | Item | Owner | Deadline | Status |
|----|------|-------|----------|--------|
| AI-1 | Aumentar pool DB para 50, com env var | @dev | YYYY-MM-DD | open |
| AI-2 | Adicionar PrometheusRule para pool saturation | @sre | YYYY-MM-DD | open |
| AI-3 | Atualizar runbook 2 (HighErrorRate) com check de pool | @sre | YYYY-MM-DD | open |
| AI-4 | New Relic Watchdog: confirmar regra ativa pra esse padrão | @sre | YYYY-MM-DD | open |

## Lições aprendidas
- Decisões da FASE 2 precisam ser revisitadas regularmente
- Self-healing é eficaz mas não substitui prevenção
- ...
```

### Revisão do post-mortem
- Discutir com time em weekly retrospective
- Compartilhar resumo com diretoria
- Public-share resumo (sem nomes) com ONGs parceiras para transparência

---

## Métricas do programa ITSM (review trimestral)

| Métrica | Target | Como medir |
|---------|--------|-----------|
| **MTTD** (Mean Time To Detect) | < 2 min | Tempo entre evento real e alerta no PagerDuty |
| **MTTA** (Mean Time To Acknowledge) | < 5 min | Tempo entre alerta e SRE acknowledge |
| **MTTR** (Mean Time To Recovery) | < 15 min (Hot Path) | Tempo entre alerta e resolved no PagerDuty |
| **Self-healing success rate** | > 70% | Workflows que resolveram sem escalar pra humano |
| **Incidents per month** | < 5 | Trending — alvo é decrescente |
| **Post-mortems completed within 7d** | 100% | Toda SEV-1 ou SEV-2 |
| **Action items closed within 30d** | > 80% | Track no board de produto |

---

## Ferramentas configuradas

| Ferramenta | Função | Custo (free tier) |
|-----------|--------|-------------------|
| Prometheus AlertManager | Roteamento | Open source |
| **PagerDuty** | ITSM, gestão de incidentes | Free 5 users |
| **Discord** | ChatOps, war-room | Free |
| **GitHub Actions** | Self-healing automation | Free 2k min/mês |
| **New Relic** | APM + AIOps (Applied Intelligence) | Free 100GB/mês |
| Grafana | Visualização de métricas/logs | Open source |

---

## Próximos passos / não cobertos nesta versão

- [ ] Status page público (Statuspage.io, Atlassian, ou self-hosted)
- [ ] Integração webhook → repository_dispatch nativa (precisa middleware)
- [ ] Runbook automation completa (StackStorm ou Rundeck)
- [ ] Chaos engineering (Chaos Mesh, Litmus) para drill periódico de incidentes
- [ ] On-call rotation formal no PagerDuty
