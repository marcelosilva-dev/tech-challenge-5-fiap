# Roteiro do Vídeo de Demonstração — SolidaryTech FASE 5

> **Duração total:** até 20 minutos (limite do PDF)
> **Formato sugerido:** 1 apresentador principal + screen share + voice-over
> **Ferramenta de gravação:** OBS, Loom, Zoom (com auto-record), ou similar
> **Estrutura:** **5min Pitch Executivo + 13min Demo Técnica + 2min Encerramento**

---

## Setup antes de gravar

**Ter aberto em abas:**
1. Slide deck / docs/PCN.md (pitch)
2. GitHub repo: https://github.com/marcelosilva-dev/tech-challenge-5-fiap
3. GitHub Actions: https://github.com/marcelosilva-dev/tech-challenge-5-fiap/actions
4. ArgoCD UI (LoadBalancer URL)
5. Grafana dashboard `SolidaryTech Overview`
6. New Relic — Service Map do `solidarytech-cluster`
7. PagerDuty: https://app.pagerduty.com/incidents
8. Discord channel com alertas
9. Terminal 1 (kubectl ready)
10. Terminal 2 (curl ready para gerar tráfego)

**Garantir antes de gravar:**
- Infra de pé (`./scripts/setup-full.sh` rodou recentemente)
- Tráfego sintético recente para encher dashboards (rodar `for i in {1..50}; do curl ...`)
- New Relic recebeu traces nas últimas horas
- PagerDuty + Discord limpos (resolver incidents antigos)

---

## PARTE 1 — Pitch Executivo (00:00 — 05:00)

> **Objetivo:** vender a viabilidade do projeto pra "diretoria da SolidaryTech".
> Sem código, sem terminal. Apenas slides/docs + voice-over.

### [00:00 — 00:30] Abertura

**Tela:** Logo SolidaryTech / título "Tech Challenge FASE 5"

**Script:**
> "Olá, somos o grupo [NOMES] da FIAP Pós-Tech DevOps. Hoje apresentamos
> a plataforma SolidaryTech que conecta ONGs a doadores e voluntários
> em todo o Brasil. Nas próximas 20 minutos mostramos como construímos
> uma infraestrutura preparada pra escalar, sobreviver a desastres,
> e operar com custo controlado."

### [00:30 — 01:30] Contexto de negócio e desafio

**Tela:** Diagrama de visão geral (arquitetura simplificada)

**Script:**
> "A SolidaryTech ganhou destaque em rede nacional. Picos de doação
> imprevisíveis. A diretoria estabeleceu 4 garantias inegociáveis:
>
> 1. **Continuidade:** doações não podem parar mesmo se a nuvem cair
> 2. **FinOps:** cada centavo precisa ser tagueado e justificado
> 3. **Resposta preditiva:** incidentes antes de afetar o doador
> 4. **SLA claro** com ONGs parceiras
>
> Vamos mostrar como cada uma é endereçada."

### [01:30 — 03:00] Arquitetura — visão executiva

**Tela:** Diagrama `docs/PCN.md` (a ASCII art ou desenhar no Excalidraw)

**Script:**
> "3 microsserviços rodando em Amazon EKS:
> - **ngo-service** — cadastro de ONGs (Python/Flask)
> - **donation-service** — o Hot Path, processamento de doações (Go)
> - **volunteer-service** — voluntários (Python + DynamoDB)
>
> Tudo orquestrado por:
> - Terraform como única fonte de verdade da infra
> - GitHub Actions com testes, SAST, SCA e Trivy a cada commit
> - ArgoCD entregando mudanças automaticamente quando algo é mergeado em main
> - Prometheus + Loki + Grafana + OpenTelemetry coletando métricas, logs e traces
> - New Relic como APM externo para AIOps
>
> Cada componente foi escolhido por uma razão específica. Vamos aprofundar
> nas próximas seções."

### [03:00 — 04:00] Disaster Recovery — RTO/RPO

**Tela:** Tabela RTO/RPO do `docs/PCN.md`

**Script:**
> "Aceitamos os seguintes objetivos formais:
>
> - donation-service (Hot Path): **RTO 15 minutos, RPO 5 minutos**
> - volunteer-service: RTO 5 minutos, RPO segundos
> - ngo-service: RTO 4 horas, RPO 24 horas
>
> Como atingimos isso? Combinamos **DUAS estratégias do PDF**:
> - Opção A: Velero com backup cross-region pra us-west-2 — recupera de
>   corrupção lógica e ransomware
> - Opção B: Warm Standby Terraform em us-west-2 — para falha regional
>
> Custo desta postura DR: 62 centavos por dia. Comparado ao prejuízo de
> US$ 10 mil por hora em uma falha real, payback em menos de 4 minutos
> de incidente evitado."

### [04:00 — 05:00] FinOps — visão executiva

**Tela:** `docs/FINOPS-REPORT.md` — tabela de forecast

**Script:**
> "Infraestrutura totalmente tagueada via Terraform `default_tags` — 5 tags
> obrigatórias em 100% dos recursos. AWS Cost Explorer filtrado por
> `Project=SolidaryTech` mostra tudo num único filtro.
>
> Custo mensal worst-case (always-on): US$ 235.
> Custo realista (uso dev com destroy diário): **US$ 74 — 70% de redução**.
>
> Identificamos uma otimização **imediata** com 99% de economia naquele
> endpoint: o volunteer-service usa DynamoDB Scan — vamos mostrar como o
> upgrade pra Query com GSI elimina o custo de varrer toda a tabela.
>
> Vamos pra demo técnica."

---

## PARTE 2 — Demo Técnica (05:00 — 18:00)

> **Objetivo:** evidenciar que **CADA componente está OPERANDO**, não apenas
> configurado. Foco do PDF: "não basta configurar; é preciso mostrar
> operando na prática".

### [05:00 — 06:30] Pipelines CI/CD com DevSecOps

**Tela:** GitHub Actions — workflow ci-donation-service.yaml

**Script + ações:**
1. **Abrir** https://github.com/marcelosilva-dev/tech-challenge-5-fiap/actions
2. **Mostrar** os 3 workflows passando verdes (ci-ngo, ci-donation, ci-volunteer)
3. **Clicar em um run recente** — mostrar os jobs:
   - `lint-test` — flake8/golangci-lint, pytest/go test, **bandit/gosec (SAST)**, **Trivy filesystem (SCA)**
   - `build-push` — docker build, **Trivy container scan**, push pro ECR
4. **Comentar:** "9 bugs reais descobertos durante o desenvolvimento por essa stack:
   - CVE-2024-45337 no golang.org/x/crypto detectado pelo Trivy → bump pra 0.35.0
   - 8 CVEs em stdlib Go 1.24 → bump pra Go 1.26
   - urllib3 CVE-2025-66418 → bump boto3
   - bandit B104 (binding 0.0.0.0) tratado com `# nosec` justificado"
5. **Mostrar** a parte "Update GitOps manifest" — sed atualiza `gitops/<svc>/deployment.yaml` com nova tag

### [06:30 — 08:00] Terraform — infra como código

**Tela:** Terminal + GitHub repo

**Script + ações:**
1. **Mostrar** `terraform/` no GitHub:
   - 5 módulos: networking, eks, databases, messaging, ecr
   - 2 environments: primary (us-east-1), dr (us-west-2)
2. **Terminal:** `cd terraform/environments/primary && terraform output | head -20`
   - Mostrar: cluster_endpoint, ngo_db_address, sqs_queue_url, ecr_repository_urls
3. **Mostrar tags FinOps** — abrir `providers.tf`:
   ```hcl
   default_tags {
     tags = {
       Project = "SolidaryTech"
       Environment = "Production"
       CostCenter = "NGO-Core"
       ManagedBy = "Terraform"
       Repository = "marcelosilva-dev/tech-challenge-5-fiap"
     }
   }
   ```
4. **Comentar:** "Propagam pra 100% dos 30+ recursos AWS criados. Veremos isso no Cost Explorer no fim."

### [08:00 — 10:00] ArgoCD — GitOps em ação

**Tela:** ArgoCD UI

**Script + ações:**
1. **Login no ArgoCD** com `admin` / pass do Secret
2. **Mostrar** as 4 Applications: `Synced + Healthy`
   - solidarytech-shared, ngo-service, donation-service, volunteer-service
3. **Clicar em `donation-service`** — mostrar:
   - O DAG visual de resources (Deployment → ReplicaSet → 3 Pods, Service, ConfigMap)
   - "Last Sync" recente
   - Botão "Sync" disponível (mas em auto-sync, não precisa apertar)
4. **Comentar:** "Cada push em `gitops/donation-service/deployment.yaml` (feito pelo CI ou manualmente) é detectado em <1min e sincronizado. Self-heal corrige drift se alguém alterar o cluster fora do git."

### [10:00 — 12:30] Observabilidade + APM

**Tela:** Grafana dashboard SolidaryTech Overview

**Script + ações:**
1. **Abrir** Grafana → Dashboards → SolidaryTech Overview
2. **Mostrar** os painéis:
   - HTTP Request Rate by Service
   - HTTP Error Rate (5xx) por Service
   - P95/P99 Latency
   - CPU/Memory usage por pod
   - Logs em tempo real (Loki)
3. **Terminal:** gerar tráfego:
   ```bash
   for i in {1..100}; do
     curl -s -X POST http://$INGRESS/donations/donations \
       -H "Content-Type: application/json" \
       -d "{\"ngo_id\":1,\"amount\":${i}.00,\"donor_name\":\"Demo$i\"}" > /dev/null
   done
   ```
4. **Voltar ao Grafana** — métricas atualizando ao vivo
5. **Trocar pra New Relic** → Services → `donation-service`:
   - **Service Map** — mostrar o grafo: donation → RDS + SQS, ngo → RDS, volunteer → DynamoDB
   - **Distributed Traces** — clicar em um trace de POST /donations:
     - Span: HTTP request → DB insert → SQS publish (visualização "waterfall")
6. **Comentar:** "Cada request é correlacionada com seu trace, logs e métricas. MTTR cai drasticamente quando você vê **exatamente** onde o tempo foi gasto."

### [12:30 — 14:30] SRE — SLOs e Error Budget

**Tela:** Grafana com painéis SLO

**Script + ações:**
1. **Abrir docs/SRE-SLO.md** no GitHub e mostrar:
   - 2 SLIs definidos (Availability + Latência P95)
   - SLOs: 99.9% disponibilidade + P95 < 300ms
   - Error Budget: 43min/mês
2. **PrometheusRules** — abrir `gitops/monitoring/alerting/prometheus-rules.yaml`:
   - `DonationSLOFastBurn` — burn rate 14.4× → page
   - `DonationLatencyP95High` — P95 > 300ms por 5min
3. **Demonstrar self-healing:**
   ```bash
   gh workflow run self-healing.yaml -f service=donation-service \
     -f reason="Demo do vídeo — gravação"
   ```
4. **Trocar pra Discord** — mostrar mensagens chegando:
   - "🛠️ Self-Healing INICIADO"
   - 30-40s depois "✅ Self-Healing CONCLUIDO"
5. **Comentar:** "Sem essa automação, recovery manual demoraria 5-10min. Com self-healing, 43 segundos comprovados (mostrar workflow run #26662680566). Isso reduz MTTR em mais de 80% naquela classe de incidente."

### [14:30 — 16:00] ITSM — fluxo de incidente

**Tela:** PagerDuty + Discord side-by-side

**Script + ações:**
1. **Abrir docs/ITSM-LIFECYCLE.md** — mostrar o diagrama de 6 fases
2. **Simular um incidente** — enviar alerta sintético via Alertmanager:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093 &
   curl -X POST http://localhost:9093/api/v2/alerts -d '[{
     "labels": {"alertname": "DemoIncident", "severity": "critical", "service": "donation-service"},
     "annotations": {"summary": "Demo do video — incidente sintético"}
   }]'
   ```
3. **Aguardar ~40s** e mostrar:
   - **PagerDuty:** novo incident criado
   - **Discord:** mensagem CRITICAL chegou no canal
4. **Apontar runbook:** docs/ITSM-LIFECYCLE.md tem 3 runbooks + post-mortem template
5. **Comentar:** "Ciclo completo: Prometheus detecta → Alertmanager roteia → PagerDuty cria incidente formal e Discord notifica time → SRE on-call acionado → mitigação via self-healing ou runbook manual → post-mortem em 48h."

### [16:00 — 17:30] Disaster Recovery — Backup/DR em ação

**Tela:** Terminal + AWS Console

**Script + ações:**
1. **Mostrar Velero rodando:**
   ```bash
   kubectl get backups -n velero
   kubectl get backup solidarytech-daily-XXXXX -n velero -o yaml | grep -E "phase|itemsBackedUp"
   ```
   - `Completed itemsBackedUp: 543`
2. **Mostrar DynamoDB Global Tables:**
   ```bash
   aws dynamodb describe-table --table-name SolidaryTechVolunteers \
     --query 'Table.Replicas'
   ```
   - Replica us-west-2: ACTIVE
3. **Mostrar Terraform DR pronto:**
   - Abrir `terraform/environments/dr/main.tf`
   - "Aqui está o ambiente espelho. 1 comando — `./scripts/setup-dr.sh` — provisiona EKS, RDS replica e SQS em us-west-2 em ~15 minutos."
4. **Mostrar `scripts/dr-failover.sh`:**
   - "6 etapas automatizadas: promove RDS replica, escala EKS de 1 pra 3 nodes, Velero restore, ArgoCD sync, validação de health endpoints. Operação de **15 minutos** para failover completo."
5. **Mostrar workflow do DR drill:**
   - `.github/workflows/dr-drill.yaml`
   - "Roda **mensalmente** sem afetar produção — provisiona o ambiente DR num cluster isolado, valida, e destrói. Mantém confiança no procedimento."

### [17:30 — 18:00] FinOps — evidência visual

**Tela:** AWS Cost Explorer

**Script + ações:**
1. **Abrir Cost Explorer** → filtrar por **tag: Project = SolidaryTech**
2. **Group by:** tag:Component → ver breakdown (network, compute, database)
3. **Comentar:**
   - "Forecast confirmado: ~US$235/mês always-on, ~US$74/mês com destroy diário"
   - "Maior otimização: DynamoDB Scan → GSI no volunteer-service. Detalhado em docs/FINOPS-REPORT.md"

---

## PARTE 3 — Encerramento (18:00 — 20:00)

### [18:00 — 19:00] Resumo dos 5 frentes

**Tela:** Tabela final (slide ou doc)

**Script:**
> "Para fechar, recapitulando os 5 requisitos do desafio:
>
> **0. Fundação DevOps:** Docker multi-stage com distroless, Terraform modular,
> GitHub Actions com 4 camadas de DevSecOps, ArgoCD GitOps, e observabilidade
> com OTel + New Relic — TUDO operando.
>
> **1. SRE:** SLI/SLO/SLA formais para donation-service. Error Budget calculado
> e alertado em fast burn. MTTR comprovado em 43 segundos via self-healing.
>
> **2. FinOps:** Tags em 100% dos recursos. Forecast com cenários. Otimização
> imediata identificada com 99% de economia.
>
> **3. ITSM/AIOps:** New Relic AIOps habilitado. Fluxo completo desenhado
> em 6 fases. PagerDuty + Discord + Self-Healing demonstrados.
>
> **4. Multicloud/Segurança/DR:** PCN executivo com RTO/RPO formais.
> AMBAS as opções do PDF implementadas — Velero (Opção A) E Warm Standby
> (Opção B). DR drill automatizado mensal."

### [19:00 — 19:30] Lições aprendidas

**Script:**
> "Durante a jornada, descobrimos e resolvemos mais de 20 bugs reais
> documentados nos commits do repositório — desde CVEs em dependências
> Go até deadlock de sync-wave no ArgoCD. Cada um virou conhecimento
> capturado pra próxima fase do projeto.
>
> O que aprendemos: **automação não substitui pensamento crítico** —
> automação **amplifica** o pensamento crítico quando aplicada com
> rigor de revisão."

### [19:30 — 20:00] Call-to-action

**Script:**
> "A plataforma SolidaryTech está pronta pra escalar. Toda a infra,
> automação e observabilidade descrita aqui hoje serve qualquer outra
> ONG digital — basta clonar o repositório.
>
> Obrigado! Repositório completo em github.com/marcelosilva-dev/tech-challenge-5-fiap."

---

## Checklist de gravação

- [ ] Áudio limpo (microfone próximo, sem eco)
- [ ] Tela em alta resolução (1920×1080 mínimo)
- [ ] Cursor visível e movimento intencional
- [ ] Sem notificações pessoais aparecendo
- [ ] Cronômetro visível ou pausas pra não estourar 20min
- [ ] Volume médio (sem música de fundo)
- [ ] Cada seção termina com transição clara

## Cortes possíveis se ultrapassar 20 minutos

1. Cortar parte do New Relic Distributed Tracing (manter só Service Map)
2. Cortar visualização do AWS Cost Explorer (mostrar só na conclusão como número)
3. Encurtar pitch executivo de 5min pra 3min (focar só nos 4 garantias)

## Cortes obrigatórios se ultrapassar 22 minutos

Vídeo precisa ter **no máximo 20min** conforme PDF. Se ficar maior, refilmar
mais conciso. PDF é explícito: "Vídeo de Demonstração (até 20 min)".
