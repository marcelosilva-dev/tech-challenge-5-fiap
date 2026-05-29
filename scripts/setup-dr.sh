#!/bin/bash
###############################################################################
# setup-dr.sh
#
# Provisiona o ambiente DR em us-west-2 (Warm Standby skeleton).
# Idempotente — pode rodar quantas vezes for necessario.
#
# Recursos criados (~10-15 min):
#   - VPC em us-west-2 com mesmo layout do primary
#   - EKS cluster solidarytech-cluster-dr (1 node skeleton)
#   - RDS donation-db-dr (Cross-Region Read Replica do primary)
#   - SQS solidary-donations (recriada — vazia)
#
# Pre-requisitos:
#   - Primary ja provisionado (./scripts/setup-full.sh)
#   - AWS credentials validas (Academy)
###############################################################################
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DR_DIR="$PROJECT_DIR/terraform/environments/dr"
PRIMARY_DIR="$PROJECT_DIR/terraform/environments/primary"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "============================================"
echo "  SolidaryTech DR — Setup us-west-2"
echo "============================================"
echo ""

# AWS auth check
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log_warn "AWS credentials invalidas/expiradas"
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_ok "AWS Account: $ACCOUNT_ID"

# Backend (mesmo bucket do primary, key path environments/dr/)
BUCKET="tc5-solidarytech-tfstate-${ACCOUNT_ID}"
TABLE="tc5-solidarytech-tflock-${ACCOUNT_ID}"

# Auto-gerar tfvars se ausente
cd "$DR_DIR"
if [ ! -f terraform.tfvars ]; then
    log_info "Gerando terraform.tfvars com valores do primary..."

    # Descobrir ARN do RDS primary
    PRIMARY_DB_ARN="arn:aws:rds:us-east-1:${ACCOUNT_ID}:db:solidarytech-donation-db"

    cat > terraform.tfvars <<EOF
aws_region              = "us-west-2"
primary_region          = "us-east-1"
project_name            = "solidarytech"
lab_role_arn            = "arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
primary_donation_db_arn = "$PRIMARY_DB_ARN"
primary_account_id      = "$ACCOUNT_ID"
node_desired_size       = 1
EOF
    log_ok "terraform.tfvars gerado"
fi

# Terraform init/apply
log_info "Terraform init (backend us-east-1, infra us-west-2)..."
terraform init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="dynamodb_table=${TABLE}" \
    > /tmp/tf-dr-init.log 2>&1

log_info "Terraform apply (~10-15 min)..."
terraform apply -auto-approve -input=false 2>&1 | tee /tmp/tf-dr-apply.log | tail -3

# Configurar kubectl para o cluster DR
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region us-west-2 --alias solidarytech-dr > /dev/null
log_ok "kubeconfig context 'solidarytech-dr' criado"

echo ""
echo "============================================"
log_ok "DR provisionado (estado: STANDBY)"
echo "============================================"
echo ""
echo "Recursos criados em us-west-2:"
terraform output
echo ""
echo "Para FAILOVER (promover replica + escalar nodes + restore):"
echo "  ./scripts/dr-failover.sh"
echo ""
echo "Para destruir DR (manter primary intacto):"
echo "  cd terraform/environments/dr && terraform destroy"
