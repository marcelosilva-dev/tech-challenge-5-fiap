#!/bin/bash
###############################################################################
# bootstrap-backend.sh
#
# Cria os recursos AWS necessarios para o backend remoto do Terraform.
# IDEMPOTENTE: pode ser executado multiplas vezes sem efeito colateral.
#
# Recursos criados (1x para todo o projeto, compartilhado entre primary e DR):
#   - Bucket S3:     tc5-solidarytech-terraform-state (versionado, criptografado)
#   - Tabela DDB:    tc5-solidarytech-terraform-lock (PAY_PER_REQUEST)
#
# Uso: ./scripts/bootstrap-backend.sh
###############################################################################
set -e
set -o pipefail

# Nomes sao sufixados com ACCOUNT_ID porque:
#   - Bucket S3 e GLOBAL entre todas as contas AWS do mundo
#   - Cada grupo da FIAP teria conflito se usasse nome fixo
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "ERRO: Nao foi possivel obter AWS Account ID. Configure credenciais primeiro." >&2
    exit 1
fi

BUCKET="tc5-solidarytech-tfstate-${ACCOUNT_ID}"
TABLE="tc5-solidarytech-tflock-${ACCOUNT_ID}"
REGION="us-east-1"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "============================================"
echo "  Bootstrap Terraform Backend - SolidaryTech"
echo "============================================"
echo ""

log_ok "AWS Account: $ACCOUNT_ID"
log_ok "Bucket:      $BUCKET"
log_ok "Lock table:  $TABLE"

# ===== Bucket S3 =====
log_info "Verificando bucket S3 '$BUCKET'..."
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    log_ok "Bucket ja existe"
else
    log_info "Criando bucket..."
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    log_ok "Bucket criado"
fi

log_info "Habilitando versionamento..."
aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled 2>/dev/null \
    && log_ok "Versionamento habilitado" \
    || log_warn "Versionamento ja estava habilitado ou sem permissao"

log_info "Habilitando encryption (AES256)..."
aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    2>/dev/null \
    && log_ok "Encryption habilitada" \
    || log_warn "Encryption ja estava habilitada ou sem permissao"

log_info "Bloqueando public access..."
aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    2>/dev/null \
    && log_ok "Public access bloqueado" \
    || log_warn "Sem permissao para bloquear public access"

# ===== Tabela DynamoDB =====
log_info "Verificando tabela DynamoDB '$TABLE'..."
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" > /dev/null 2>&1; then
    log_ok "Tabela ja existe"
else
    log_info "Criando tabela..."
    aws dynamodb create-table \
        --table-name "$TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION" \
        --tags Key=Project,Value=SolidaryTech Key=Environment,Value=Shared \
               Key=CostCenter,Value=NGO-Core Key=ManagedBy,Value=bootstrap \
        > /dev/null
    log_info "Aguardando tabela ficar ACTIVE..."
    aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
    log_ok "Tabela criada"
fi

echo ""
echo "============================================"
log_ok "Backend pronto"
echo "============================================"
echo ""
echo "Bucket:  s3://$BUCKET"
echo "Tabela:  $TABLE"
echo "Regiao:  $REGION"
echo ""
echo "Proximo passo: ./scripts/setup-full.sh"
