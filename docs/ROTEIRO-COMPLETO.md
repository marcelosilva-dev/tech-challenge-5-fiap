# ROTEIRO COMPLETO — SolidaryTech (FASE 5)

> Passo-a-passo para subir a plataforma SolidaryTech do zero em uma conta AWS
> Academy (LabRole), incluindo todos os requisitos do Tech Challenge FASE 5
> (SRE + FinOps + ITSM/AIOps + DR cross-region).
>
> **Público-alvo:** integrante do grupo que fez o fork do repositório no
> GitHub e quer rodar tudo em conta AWS Academy própria, com o mínimo de
> intervenção manual.
>
> **Tempo total estimado:** ~45 min do `git clone` ao primeiro tráfego válido
> nas APIs (sendo ~35 min de espera de provisionamento AWS).

---

## Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Contas e tokens externos](#2-contas-e-tokens-externos)
3. [Limitações conhecidas do AWS Academy](#3-limitações-conhecidas-do-aws-academy)
4. [GitHub Secrets do fork](#4-github-secrets-do-fork)
5. [Part 1 — Credenciais AWS + Backend Terraform](#part-1--credenciais-aws--backend-terraform)
6. [Part 2 — Secrets externos ANTES do setup](#part-2--secrets-externos-antes-do-setup)
7. [Part 3 — Setup automatizado (setup-full.sh)](#part-3--setup-automatizado-setup-fullsh)
8. [Part 4 — New Relic APM](#part-4--new-relic-apm)
9. [Part 5 — Alertas (PagerDuty + Discord)](#part-5--alertas-pagerduty--discord)
10. [Part 6 — Self-Healing manual + automático](#part-6--self-healing)
11. [Part 7 — Grafana dashboards](#part-7--grafana-dashboards)
12. [Part 8 — Validação final + Smoke tests](#part-8--validação-final)
13. [Renovação de credenciais AWS Academy (4h)](#renovação-de-credenciais-aws-academy-4h)
14. [Destruição completa](#destruição-completa)
15. [Troubleshooting](#troubleshooting)

---

## 1. Pré-requisitos

### Ferramentas locais

| Ferramenta | Versão mínima | Instalação macOS |
|------------|---------------|------------------|
| AWS CLI v2 | 2.15+ | `brew install awscli` |
| Terraform | 1.6+ | `brew install terraform` |
| kubectl | 1.30+ | `brew install kubectl` |
| Helm | 3.12+ | `brew install helm` |
| Docker Desktop | 4.20+ (com buildx) | https://docker.com |
| jq | qualquer | `brew install jq` |
| git | 2.40+ | nativo do macOS |
| gh CLI | 2.40+ (opcional p/ self-healing) | `brew install gh` |

### Hardware

- 16 GB RAM (apenas para builds multi-arch local)
- 20 GB livre em disco para imagens Docker

---

## 2. Contas e tokens externos

| Conta | Necessária para | Plano sugerido |
|-------|-----------------|----------------|
| **AWS Academy** | Toda a infra | LabRole (4h por sessão) |
| **GitHub** (fork) | CI/CD + GitOps | Conta pessoal |
| **New Relic** | APM + Distributed Tracing | Free Tier (100GB/mês) |
| **PagerDuty** | ITSM / on-call | **Free Plan** — limite 1 Service + 1 Escalation Policy |
| **Discord** | Notificações de alertas | Server pessoal com webhook |

### Como obter cada credencial

#### New Relic License Key
1. Logar em https://one.newrelic.com
2. Perfil (canto sup. dir.) → **API Keys** → **Create a key** → tipo **INGEST - LICENSE**
3. Copiar o valor (começa com `NRAL-` ou similar)

#### PagerDuty Integration Key (Free Plan)
> **Atenção:** a trial de 14 dias do PagerDuty expira e os events viram silenciosamente 202 sem incidente. Use Free Plan desde o início:
>
> 1. Após criar a conta, vá em **Services** → apague qualquer Service extra
> 2. Em **Escalation Policies** → apague qualquer policy extra (limite Free = 1)
> 3. Settings → Billing → "Downgrade to Free" deve estar disponível agora
> 4. Criar **Service "SolidaryTech-Critical"** + integration **Events API V2** → copiar `Integration Key`

#### Discord Webhook
1. Server Settings → **Integrations** → **Webhooks** → **New Webhook**
2. Channel `#alerts` → Copy Webhook URL
3. Anote a URL — vai usar com sufixo `/slack` (Alertmanager envia em Slack-format)

#### GitHub Personal Access Token (opcional)
- Para self-healing automático via `repository_dispatch` (não usado por padrão; ver Part 6)
- Escopo `repo` em https://github.com/settings/tokens

---

## 3. Limitações conhecidas do AWS Academy

| Limitação | Impacto na arquitetura |
|-----------|-------------------------|
| Sessão expira em **4 horas** | Necessário renovar credenciais (ver seção dedicada) |
| Sem permissão para criar **IAM Roles** | Tudo usa `LabRole` (sem IRSA, sem OIDC) |
| **EBS PersistentVolumes** indisponíveis | Postgres em RDS, Prometheus/Loki em emptyDir |
| Apenas **us-east-1** + **us-west-2** habilitadas | Bom para DR cross-region |
| EKS limitado em **CNI ENIs por instance type** | Sizing crítico (próximo item) |
| Sem **Reserved Instances / Savings Plans** | Análise FinOps fica restrita a tagging + recomendações |

### Cluster sizing — por que 3 × t3.medium

Pods por nó (limite ENI × IPs do EKS CNI):

```
t3.medium → 3 ENI × (6 IPs - 1) + 2 (overhead) = 17 pods/nó
```

Carga de pods ao final do roteiro:
- 3 microsserviços × 2 réplicas = **6**
- kube-prometheus-stack (Prom + Grafana + Alertmanager + node-exporter × 3) = **~10**
- Loki + Promtail × 3 = **4**
- OTel Collector + ArgoCD + NGINX Ingress + DNS + db-init Jobs (transitórios) = **~15**

**Total estável ≈ 35 pods → 3 nós dão 51 slots (~70% headroom).**

Se usar 2 nós o cluster fica em **Pending** com `FailedScheduling: Too many pods`.

---

## 4. GitHub Secrets do fork

No **seu fork** (`https://github.com/<SEU_USER>/TC5-SolidaryTech`), abrir
**Settings → Secrets and variables → Actions** e cadastrar:

| Secret | Valor | Usado por |
|--------|-------|-----------|
| `AWS_ACCESS_KEY_ID` | Da sessão AWS Academy | CI workflows (push para ECR) |
| `AWS_SECRET_ACCESS_KEY` | Da sessão AWS Academy | CI workflows |
| `AWS_SESSION_TOKEN` | Da sessão AWS Academy | CI workflows |
| `AWS_REGION` | `us-east-1` | CI workflows |
| `DISCORD_WEBHOOK_URL` | URL do webhook (sem `/slack`) | `self-healing.yaml` |

> Como AWS Academy expira em 4 horas, esses 3 secrets de AWS precisam ser
> atualizados a cada sessão. Ver script `scripts/update-aws-credentials.sh`
> (atualiza apenas local; para GitHub use `gh secret set`).

---

## Part 1 — Credenciais AWS + Backend Terraform

```bash
# 1.1 Configurar credenciais AWS (copiar do AWS Academy → AWS Details)
aws configure set aws_access_key_id     <AWS_ACCESS_KEY_ID>     --profile default
aws configure set aws_secret_access_key <AWS_SECRET_ACCESS_KEY> --profile default
aws configure set aws_session_token     <AWS_SESSION_TOKEN>     --profile default
aws configure set region                us-east-1               --profile default

# 1.2 Validar
aws sts get-caller-identity
# Esperado: Account=<sua conta>, Arn termina em ":assumed-role/voclabs/..."

# 1.3 Bootstrap backend (S3 + DynamoDB lock) — UMA VEZ por conta
./scripts/bootstrap-backend.sh
# Cria: s3://tc5-solidarytech-tfstate-<ACCOUNT_ID> + DynamoDB table tflock
```

---

## Part 2 — Secrets externos ANTES do setup

O `setup-full.sh` espera que **dois** secrets externos já existam **no Git
do seu fork** (ignorados via `.gitignore`):

### 2.1 New Relic Secret

```bash
cp gitops/monitoring/newrelic-secret.yaml.example gitops/monitoring/newrelic-secret.yaml

# Editar e trocar <NEW_RELIC_LICENSE_KEY>
vim gitops/monitoring/newrelic-secret.yaml
```

### 2.2 Alertmanager Config

```bash
cp gitops/monitoring/alerting/alertmanager-config.yaml.example \
   gitops/monitoring/alerting/alertmanager-config.yaml

# Editar e trocar 2 placeholders:
#   <PAGERDUTY_INTEGRATION_KEY>  → da Service do PagerDuty
#   <DISCORD_WEBHOOK_URL>        → do webhook do Discord (sem /slack ao final)
vim gitops/monitoring/alerting/alertmanager-config.yaml
```

> **NÃO commit** estes 2 arquivos — `.gitignore` já protege. São aplicados
> diretamente em `kubectl apply` na Part 5.

### 2.3 (Opcional) `terraform.tfvars`

Você pode usar os defaults. Caso queira customizar:

```hcl
# terraform/environments/primary/terraform.tfvars
lab_role_arn  = "arn:aws:iam::<SUA_ACCOUNT_ID>:role/LabRole"
db_password   = "<senha forte>"
```

Não commitar (`.gitignore` cobre).

---

## Part 3 — Setup automatizado (setup-full.sh)

**Um único comando** orquestra os 13 passos do provisionamento.

```bash
./scripts/setup-full.sh
```

### O que ele faz (13 steps)

| Step | Ação | Tempo |
|------|------|-------|
| 0/13 | Verifica pré-requisitos (aws/terraform/kubectl/docker/git) | 5s |
| 1/13 | Garante backend remoto (S3 + DynamoDB lock) | 10s |
| 2/13 | `terraform init` + `plan` em `environments/primary/` | 1min |
| 3/13 | `terraform apply` — VPC + EKS + RDS × 2 + DynamoDB + SQS + ECR × 3 | **~22min** |
| 4/13 | `aws eks update-kubeconfig` | 5s |
| 5/13 | Build multi-arch + push das 3 imagens pro ECR | 5-8min |
| 6/13 | **Substitui placeholders** `<AWS_ACCOUNT_ID>` e `<GITHUB_USER>` nos manifests e faz `git commit + push` | 10s |
| 7/13 | Gera + aplica K8s Secrets (`scripts/generate-secrets.sh` + `apply-secrets.sh`) | 15s |
| 8/13 | Instala ArgoCD via Helm | 2min |
| 9/13 | Instala NGINX Ingress Controller + AWS NLB | 2min |
| 10/13 | Aplica `argocd/applications.yaml` — ArgoCD sincroniza tudo | 3min |
| 11/13 | Verifica New Relic secret (warn se ausente) | 5s |
| 12/13 | Instala Monitoring Stack (kube-prometheus-stack + Loki + Promtail + OTel) | 3min |
| 13/13 | Instala Velero (backup cross-region us-west-2) | 1min |

> **Importante — Step 6:** o script substitui `<AWS_ACCOUNT_ID>` pelo Account
> da sessão atual e `<GITHUB_USER>` pelo owner do `origin` do git, **comita
> automaticamente e dá push**. Em forks de outros membros, isso ocorre na
> conta deles sem intervenção. O `destroy-all.sh` faz o caminho inverso
> (restaura placeholders + commit + push) — mantém o repo limpo.

### Esperado ao final

```bash
kubectl get pods -A
# Todos os pods em Running, exceto db-init Jobs (Completed)

kubectl get application -n argocd
# 3 applications: Synced + Healthy

kubectl get ingress -n solidarytech
# 1 ingress com ADDRESS preenchido (DNS do NLB)
```

---

## Part 4 — New Relic APM

Após o setup completar, o OTel Collector já está exportando traces para o
New Relic. Para validar:

1. Em New Relic → **APM & Services** → deve aparecer `ngo-service`,
   `donation-service`, `volunteer-service`
2. Gerar tráfego:
   ```bash
   INGRESS=$(kubectl get ingress -n solidarytech app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   for i in {1..20}; do curl -s "http://$INGRESS/ngos" > /dev/null; done
   ```
3. New Relic → APM → `donation-service` → **Distributed tracing** mostra
   spans `POST /donations` → DB insert → SQS publish

---

## Part 5 — Alertas (PagerDuty + Discord)

Aplicar o secret Alertmanager (preparado na Part 2):

```bash
kubectl apply -f gitops/monitoring/alerting/alertmanager-config.yaml

# Forçar reload do Alertmanager
kubectl rollout restart statefulset alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring

# Aplicar regras Prometheus (SLO + golden signals)
kubectl apply -f gitops/monitoring/alerting/prometheus-rules.yaml
```

### Testar end-to-end

Subir error rate forçada (degraded mode no donation-service):

```bash
# Patch para simular erro (alterar variavel de env via deployment)
kubectl set env deployment/donation-service -n solidarytech FORCE_500=true

# Aguardar 2-5 min: alerta dispara → PagerDuty cria incidente + Discord notifica
# Reverter:
kubectl set env deployment/donation-service -n solidarytech FORCE_500-
```

> Não tem `FORCE_500` no service? Use `prometheus-rules.yaml` regra `Watchdog`
> que dispara sempre — ou seu alerta artificial preferido.

---

## Part 6 — Self-Healing

Workflow `.github/workflows/self-healing.yaml` faz rollout restart de um
service via:

### 6.1 Manual (via gh CLI)

```bash
gh workflow run self-healing.yaml \
  --field service=donation-service \
  --field reason="Teste manual de self-healing"
```

### 6.2 Manual (via UI)

GitHub → Actions → Self-Healing → Run workflow → escolher service.

### 6.3 Automatizado (opcional)

O Alertmanager **não** chama o workflow nativamente (payload incompatível).
Para automação completa, instale `alertmanager-webhook-server` ou similar
e troque o receiver `solidarytech-critical` no Alertmanager.

> No nosso ambiente, mantemos o disparo manual via `gh workflow run` —
> simples, audível, sem custo de middleware. Para demonstração no vídeo
> entregável, ver `docs/VIDEO-ROTEIRO.md`.

---

## Part 7 — Grafana dashboards

```bash
# Senha gerada automaticamente
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo ""

# URL pública
kubectl get svc -n monitoring prometheus-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Login `admin` + senha acima. Dashboards relevantes:
- **SolidaryTech Overview** (importado de `gitops/monitoring/grafana/dashboards/solidarytech-overview.json`)
- **Kubernetes / Compute Resources / Cluster** (built-in)
- **Loki Logs** (built-in)

---

## Part 8 — Validação final

```bash
# 1. Health checks via Ingress
INGRESS=$(kubectl get ingress -n solidarytech app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://$INGRESS/ngos"          # 200 + JSON com 2 ONGs seed
curl -s "http://$INGRESS/donations"     # 200 + lista vazia
curl -s "http://$INGRESS/volunteers"    # 200 + lista vazia

# 2. POST de teste (donation)
curl -s -X POST "http://$INGRESS/donations" \
  -H "Content-Type: application/json" \
  -d '{"ngo_id": 1, "amount": 50.00, "donor_name": "Teste"}'

# 3. Verificar SQS publicou o evento
aws sqs receive-message \
  --queue-url $(terraform -chdir=terraform/environments/primary output -raw donations_queue_url) \
  --region us-east-1

# 4. Verificar APM no New Relic — buscar trace do POST acima
```

---

## Renovação de credenciais AWS Academy (4h)

A cada nova sessão do Lab, copiar AWS Details e:

```bash
./scripts/update-aws-credentials.sh
# Solicita Access Key, Secret, Session Token interativamente
# Atualiza ~/.aws/credentials

# Renovar tambem no kubectl
aws eks update-kubeconfig --name solidarytech-cluster --region us-east-1

# Renovar secrets no GitHub Actions (caso vá usar CI no mesmo dia):
gh secret set AWS_ACCESS_KEY_ID     --body "<novo valor>"
gh secret set AWS_SECRET_ACCESS_KEY --body "<novo valor>"
gh secret set AWS_SESSION_TOKEN     --body "<novo valor>"
```

> Recursos AWS continuam rodando (RDS / EKS são serviços, não consomem
> sessão). Apenas o controle plane via CLI exige sessão ativa.

---

## Destruição completa

```bash
./scripts/destroy-all.sh
# Confirma com "yes"
# Tempo: ~15min
```

O script:
1. Drena LBs do K8s (services type=LoadBalancer) → libera ENIs
2. Limpa ENIs órfãs em NLBs/ALBs (resolve `DependencyViolation` no destroy)
3. Limpa Velero finalizers
4. `terraform destroy` em ambos os ambientes
5. **Restaura placeholders** `<AWS_ACCOUNT_ID>` e `<GITHUB_USER>` nos manifests + commit + push (mantém repo limpo)
6. Verificação final (VPC, EKS, RDS, ECR, NAT, EIP, LB == 0)

> **Custo se esquecer:** ~$8/dia (NAT × 2 + RDS × 2). Sempre destruir ao fim do dia.

---

## Troubleshooting

### Setup trava em "Waiting for ArgoCD Application to be Healthy"

ArgoCD pode demorar até 5 min para a primeira sync. Verificar:

```bash
kubectl get application -n argocd
kubectl describe application -n argocd solidarytech-donation
```

Se aparecer `OutOfSync` por hash incorreto:

```bash
# Manifestos foram modificados localmente mas não foram pushados
git status gitops/ argocd/
git push
```

### `db-init Job` em `BackoffLimitExceeded`

Significa DNS do RDS não resolvendo dos nodes (problema clássico da FASE 2/3
que **foi corrigido** atribuindo o cluster SG + node SG ao Launch Template).
Se voltar, verificar:

```bash
kubectl logs job/donation-db-init -n solidarytech
# Procurar "Aguardando DNS resolver"

# Validar SG do nó:
NODE_SG=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:eks:nodegroup-name,Values=*" \
  --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' --output text)
echo $NODE_SG  # Deve ter 2 SGs: o do node group + o cluster SG
```

Se houver só 1, refazer `terraform apply -target=module.eks`.

### Pods em `Pending: Too many pods`

Sizing errado — usar 3 × t3.medium (ver seção 3).

```bash
kubectl get nodes
# Esperado: 3 nodes Ready
```

### PagerDuty events retornam 202 mas não criam incidente

**Trial expirou silenciosamente.** Downgrade para Free Plan:

1. PagerDuty → Configuration → Services → apagar Services extras
2. Escalation Policies → apagar policies extras (manter 1)
3. Settings → Billing → "Downgrade to Free"
4. Recriar Service + Integration Key
5. `kubectl edit secret alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring` e atualizar
6. `kubectl rollout restart statefulset alertmanager-... -n monitoring`

### Imagens ECR não pulham — `denied: requested access to the resource is denied`

Sessão AWS expirou. Renovar e refazer login:

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
```

### Grafana sem dashboards

```bash
# Reimportar
kubectl create configmap grafana-dashboard-solidarytech \
  --from-file=solidarytech-overview.json=gitops/monitoring/grafana/dashboards/solidarytech-overview.json \
  -n monitoring --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml \
  | kubectl apply -f -
```

### `setup-full.sh` falhou no meio — como retomar

Idempotente: rodar de novo. Cada step verifica se o recurso já existe.

### `terraform destroy` trava em VPC

Sempre é dependência de ENI órfã (LB ou Lambda). O `destroy-all.sh` cuida
disso; se rodou `terraform destroy` direto, refazer via wrapper:

```bash
./scripts/destroy-all.sh
```

### Self-healing workflow não roda

Verificar Secrets no fork: `AWS_*` (3) + `DISCORD_WEBHOOK_URL`. Sem os
secrets, o workflow falha no `aws-actions/configure-aws-credentials`.

---

## Anexos

- **Arquitetura ASCII:** ver `docs/RELATORIO-ENTREGA.md` → seção 3
- **SLI/SLO formais:** ver `docs/SRE-SLO.md`
- **FinOps tags + forecast:** ver `docs/FINOPS-REPORT.md`
- **PCN / DR Strategy:** ver `docs/PCN.md` + `docs/DR-STRATEGY.md`
- **ITSM lifecycle + runbooks:** ver `docs/ITSM-LIFECYCLE.md`
- **Vídeo roteiro (20min):** ver `docs/VIDEO-ROTEIRO.md`

> Em caso de dúvida não coberta acima, abrir issue no fork ou contatar o
> grupo SolidaryTech (ver `RELATORIO-ENTREGA.md`).
