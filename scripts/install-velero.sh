#!/bin/bash
###############################################################################
# install-velero.sh
#
# Instala Velero no cluster primario para backups dos namespaces solidarytech
# e argocd, com BackupStorageLocation em bucket S3 em us-west-2 (cross-region
# para DR).
#
# Strategy (alinhado com DR-STRATEGY.md):
#   - Bucket S3: solidarytech-velero-backups-<ACCOUNT_ID> (us-west-2)
#   - Backup diario as 03:00 UTC, retencao 30 dias
#   - Namespaces incluidos: solidarytech, argocd
#   - PVCs: nao temos no momento (RDS/DynamoDB externos)
#
# AWS Academy: nao podemos criar IAM users dedicados; usamos as creds da
# sessao atual via secret cloud-credentials (mesmo padrao usado por outros
# K8s secrets).
###############################################################################
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="solidarytech-velero-backups-${ACCOUNT_ID}"
DR_REGION="us-west-2"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "============================================"
echo "  SolidaryTech - Velero Backup Installer"
echo "============================================"
echo ""

# -------------------------------------------------------
# 1. Bucket S3 cross-region (us-west-2)
# -------------------------------------------------------
log_info "[1/5] Criando bucket S3 em $DR_REGION..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    log_ok "Bucket ja existe"
else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$DR_REGION" \
        --create-bucket-configuration LocationConstraint="$DR_REGION"
    aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled 2>/dev/null || true
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' 2>/dev/null || true
    log_ok "Bucket criado: s3://$BUCKET_NAME"
fi

# -------------------------------------------------------
# 2. Secret com credenciais AWS (Academy: usa sessao atual)
# -------------------------------------------------------
log_info "[2/5] Verificando credenciais AWS..."
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
fi
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
fi
if [ -z "$AWS_SESSION_TOKEN" ]; then
    AWS_SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
fi

CREDS_FILE=$(mktemp)
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
aws_session_token = $AWS_SESSION_TOKEN
EOF

log_ok "credentials file pronto (sera secret cloud-credentials)"

# -------------------------------------------------------
# 3. Helm install Velero
# -------------------------------------------------------
log_info "[3/5] Instalando Velero via Helm..."
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts > /dev/null
helm repo update > /dev/null

helm upgrade --install velero vmware-tanzu/velero \
    --namespace velero \
    --create-namespace \
    --set "configuration.backupStorageLocation[0].name=aws-us-west-2" \
    --set "configuration.backupStorageLocation[0].provider=aws" \
    --set "configuration.backupStorageLocation[0].bucket=$BUCKET_NAME" \
    --set "configuration.backupStorageLocation[0].config.region=$DR_REGION" \
    --set "configuration.volumeSnapshotLocation[0].name=aws-us-west-2" \
    --set "configuration.volumeSnapshotLocation[0].provider=aws" \
    --set "configuration.volumeSnapshotLocation[0].config.region=$DR_REGION" \
    --set "initContainers[0].name=velero-plugin-for-aws" \
    --set "initContainers[0].image=velero/velero-plugin-for-aws:v1.10.0" \
    --set "initContainers[0].volumeMounts[0].mountPath=/target" \
    --set "initContainers[0].volumeMounts[0].name=plugins" \
    --set "credentials.useSecret=true" \
    --set-file "credentials.secretContents.cloud=$CREDS_FILE" \
    --wait --timeout 5m

rm -f "$CREDS_FILE"
log_ok "Velero instalado"

# -------------------------------------------------------
# 4. Schedule diario
# -------------------------------------------------------
log_info "[4/5] Configurando schedule de backup diario..."
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: solidarytech-daily
  namespace: velero
spec:
  schedule: "0 3 * * *"  # 03:00 UTC diario
  template:
    includedNamespaces:
      - solidarytech
      - argocd
    excludedResources:
      - events
      - events.events.k8s.io
    storageLocation: aws-us-west-2
    ttl: 720h  # 30 dias
EOF
log_ok "Schedule diario criado (TTL 30 dias)"

# -------------------------------------------------------
# 5. Validar
# -------------------------------------------------------
log_info "[5/5] Validando..."
kubectl wait --for=condition=available --timeout=120s deployment/velero -n velero
kubectl get backupstoragelocations.velero.io -n velero

echo ""
log_ok "Velero pronto"
echo ""
echo "Comandos uteis:"
echo "  Listar backups:   kubectl get backups -n velero"
echo "  Criar backup ad-hoc: kubectl create -f - <<EOF"
echo "    apiVersion: velero.io/v1"
echo "    kind: Backup"
echo "    metadata: { name: manual-\$(date +%s), namespace: velero }"
echo "    spec: { includedNamespaces: [solidarytech, argocd], ttl: 168h }"
echo "  EOF"
echo "  Restore:          kubectl create -f - (apiVersion velero.io/v1, kind: Restore)"
echo ""
log_warn "Lembrete: secret cloud-credentials expira em 4h (AWS Academy)."
echo "  Renovar com: ./scripts/update-velero-credentials.sh (em breve)"
