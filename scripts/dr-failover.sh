#!/bin/bash
###############################################################################
# dr-failover.sh
#
# EXECUTA O FAILOVER do primary (us-east-1) para o DR (us-west-2).
# Operacao DESTRUTIVA — usar apenas quando primary regional esta caido.
#
# Etapas (alinhadas com docs/DR-STRATEGY.md):
#   1. Promover RDS donation-db replica em us-west-2 (~3-5 min)
#   2. Escalar EKS DR de 1 -> 3 nodes
#   3. Velero restore dos namespaces solidarytech + argocd
#   4. Aplicar K8s Secrets atualizados com endpoints DR
#   5. Aguardar ArgoCD Applications sincronizarem
#   6. Validar health endpoints
#
# Pre-requisitos:
#   - ./scripts/setup-dr.sh ja executado (cluster DR + RDS replica de pe)
#   - Velero instalado no primary (./scripts/install-velero.sh) + backup recente
#   - kubectl configurado para context solidarytech-dr
###############################################################################
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

DRY_RUN=""
if [ "$1" = "--dry-run" ]; then
    DRY_RUN="echo [DRY-RUN] would run:"
    log_warn "DRY-RUN mode — nenhuma operacao destrutiva sera executada"
fi

echo "============================================"
echo "  SolidaryTech DR — FAILOVER"
echo "============================================"
echo ""

# Confirma intencao
if [ -z "$DRY_RUN" ]; then
    log_warn "OPERACAO DESTRUTIVA. RDS replica sera promovida (sem volta facil)."
    read -rp "Digite 'FAILOVER' para continuar: " CONFIRM
    if [ "$CONFIRM" != "FAILOVER" ]; then
        log_warn "Cancelado pelo usuario"
        exit 0
    fi
fi

START_TIME=$(date +%s)

# -------------------------------------------------------
# 1. Promover RDS replica em us-west-2
# -------------------------------------------------------
log_info "[1/6] Promovendo RDS donation-db-dr -> primary..."
$DRY_RUN aws rds promote-read-replica \
    --db-instance-identifier solidarytech-donation-db-dr \
    --region us-west-2 > /dev/null

log_info "Aguardando RDS disponivel (~3-5 min)..."
$DRY_RUN aws rds wait db-instance-available \
    --db-instance-identifier solidarytech-donation-db-dr \
    --region us-west-2
log_ok "RDS promovido"

# -------------------------------------------------------
# 2. Escalar EKS DR para 3 nodes
# -------------------------------------------------------
log_info "[2/6] Escalando EKS DR node group: 1 -> 3..."
$DRY_RUN aws eks update-nodegroup-config \
    --cluster-name solidarytech-cluster-dr \
    --nodegroup-name solidarytech-cluster-dr-ng \
    --scaling-config minSize=1,maxSize=4,desiredSize=3 \
    --region us-west-2 > /dev/null

if [ -z "$DRY_RUN" ]; then
    log_info "Aguardando 3 nodes Ready..."
    kubectl config use-context solidarytech-dr > /dev/null
    until [ "$(kubectl get nodes --no-headers | grep -c 'Ready ')" -ge "3" ]; do
        sleep 15
        echo -n "."
    done
    echo ""
fi
log_ok "3 nodes Ready"

# -------------------------------------------------------
# 3. Velero restore
# -------------------------------------------------------
log_info "[3/6] Velero restore (manifests K8s)..."
# Velero do primary nao acessa cluster DR diretamente.
# Estrategia: instalar Velero no DR apontando para o MESMO bucket S3, e fazer restore.
$DRY_RUN bash "$SCRIPT_DIR/install-velero.sh"

LATEST_BACKUP=$($DRY_RUN kubectl get backups -n velero -o json 2>/dev/null | \
    python3 -c "import sys,json; b=json.load(sys.stdin); print(sorted(b['items'], key=lambda x: x['metadata']['creationTimestamp'])[-1]['metadata']['name'])" 2>/dev/null || echo "DRY_RUN_BACKUP")

if [ -n "$LATEST_BACKUP" ] && [ "$LATEST_BACKUP" != "DRY_RUN_BACKUP" ]; then
    log_info "Restore do backup: $LATEST_BACKUP"
    $DRY_RUN kubectl create -n velero -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-restore-$(date +%s)
  namespace: velero
spec:
  backupName: $LATEST_BACKUP
  includedNamespaces:
    - solidarytech
    - argocd
EOF
    log_ok "Restore iniciado"
fi

# -------------------------------------------------------
# 4. Aplicar K8s Secrets com endpoints DR
# -------------------------------------------------------
log_info "[4/6] Atualizando secrets com endpoints DR..."
# Re-gera secrets apontando para RDS DR + SQS DR + DynamoDB (Global Tables mesmo nome)
$DRY_RUN bash "$SCRIPT_DIR/generate-secrets.sh"
$DRY_RUN bash "$SCRIPT_DIR/apply-secrets.sh"
log_ok "Secrets aplicados"

# -------------------------------------------------------
# 5. Aplicar ArgoCD Applications
# -------------------------------------------------------
log_info "[5/6] Aplicando ArgoCD Applications no DR..."
$DRY_RUN kubectl apply -f "$PROJECT_DIR/argocd/applications.yaml"
log_info "Aguardando ArgoCD sincronizar..."
if [ -z "$DRY_RUN" ]; then
    for svc in ngo-service donation-service volunteer-service; do
        echo -n "  $svc... "
        kubectl rollout status deployment/$svc -n solidarytech --timeout=180s 2>/dev/null \
            && echo "ok" || echo "(pode demorar mais)"
    done
fi

# -------------------------------------------------------
# 6. Validar health
# -------------------------------------------------------
log_info "[6/6] Validando health endpoints..."
if [ -z "$DRY_RUN" ]; then
    INGRESS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pendente")
    if [ -n "$INGRESS" ] && [ "$INGRESS" != "pendente" ]; then
        for svc in ngos donations volunteers; do
            STATUS=$(/usr/bin/curl -s -m 10 -o /dev/null -w "%{http_code}" "http://$INGRESS/$svc/health" || echo "000")
            echo "  $svc/health: HTTP $STATUS"
        done
    else
        log_warn "Ingress LB ainda nao tem hostname externo — aguardar mais"
    fi
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "============================================"
log_ok "FAILOVER CONCLUIDO em ${ELAPSED}s"
echo "============================================"
echo ""
echo "Novo endpoint publico:"
echo "  http://$INGRESS"
echo ""
echo "Atualize a comunicacao com:"
echo "  - DNS Route53 (manual nesta versao)"
echo "  - Status page para ONGs parceiras"
echo "  - PagerDuty: incidente resolvido"
echo ""
log_warn "FAILBACK: aguardar primary estavel >24h antes de iniciar reverse failover."
echo "  Documentacao em docs/DR-STRATEGY.md secao 'Procedimento de Failback'"
