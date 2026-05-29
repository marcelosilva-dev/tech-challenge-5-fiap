#!/bin/bash
###############################################################################
# generate-secrets.sh
#
# Gera K8s Secrets a partir do `terraform output` do ambiente primary.
# Cada microsservico recebe seu Secret proprio com:
#   - DATABASE_URL (RDS endpoint completo, com user/pass do tfvars)
#   - AWS creds (necessario para SDK boto3/aws-sdk-go acessar SQS/DynamoDB,
#     ja que AWS Academy bloqueia IRSA via OIDC provider)
#
# Os arquivos sao gerados em scripts/_generated/ (no .gitignore).
# Padrao stringData (Kubernetes converte para base64 automaticamente).
#
# Uso:
#   ./scripts/generate-secrets.sh
#   ./scripts/apply-secrets.sh
###############################################################################
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$PROJECT_DIR/terraform/environments/primary"
OUT_DIR="$SCRIPT_DIR/_generated"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# AWS creds (env vars OU aws configure)
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
fi
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
fi
if [ -z "$AWS_SESSION_TOKEN" ]; then
    AWS_SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log_err "Credenciais AWS nao encontradas."
    exit 1
fi

# Outputs do terraform
log_info "Lendo terraform outputs..."
cd "$ENV_DIR"

NGO_DB_ADDRESS=$(terraform output -raw ngo_db_address)
DONATION_DB_ADDRESS=$(terraform output -raw donation_db_address)
SQS_QUEUE_URL=$(terraform output -raw sqs_queue_url)
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)

# DB creds do tfvars com fallback para defaults (evita set -e matar o
# script se tfvars minimo — ex: gerado pelo destroy-all.sh)
DB_USERNAME=$(grep '^db_username' terraform.tfvars 2>/dev/null | cut -d'"' -f2)
DB_USERNAME=${DB_USERNAME:-solidary}
DB_PASSWORD=$(grep '^db_password' terraform.tfvars 2>/dev/null | cut -d'"' -f2)
if [ -z "$DB_PASSWORD" ]; then
    log_err "db_password ausente em terraform.tfvars"
    exit 1
fi

log_ok "Outputs lidos:"
echo "  NGO DB:       $NGO_DB_ADDRESS"
echo "  Donation DB:  $DONATION_DB_ADDRESS"
echo "  SQS:          $SQS_QUEUE_URL"
echo "  DynamoDB:     $DYNAMODB_TABLE"

# Gerar arquivos
mkdir -p "$OUT_DIR"

# ===== ngo-service-secret =====
cat > "$OUT_DIR/ngo-service-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ngo-service-secret
  namespace: solidarytech
type: Opaque
stringData:
  DATABASE_URL: "postgres://${DB_USERNAME}:${DB_PASSWORD}@${NGO_DB_ADDRESS%:5432}:5432/ngo_db?sslmode=require"
EOF

# ===== donation-service-secret =====
cat > "$OUT_DIR/donation-service-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: donation-service-secret
  namespace: solidarytech
type: Opaque
stringData:
  DATABASE_URL: "postgres://${DB_USERNAME}:${DB_PASSWORD}@${DONATION_DB_ADDRESS%:5432}:5432/donation_db?sslmode=require"
  AWS_SQS_URL: "${SQS_QUEUE_URL}"
  AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
  AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
  AWS_SESSION_TOKEN: "${AWS_SESSION_TOKEN}"
EOF

# ===== volunteer-service-secret =====
cat > "$OUT_DIR/volunteer-service-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: volunteer-service-secret
  namespace: solidarytech
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
  AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
  AWS_SESSION_TOKEN: "${AWS_SESSION_TOKEN}"
EOF

log_ok "Secrets gerados em: $OUT_DIR"
log_info "Aplicar com: ./scripts/apply-secrets.sh"
