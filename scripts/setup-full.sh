#!/bin/bash
###############################################################################
# setup-full.sh
#
# Script master que orquestra o setup do ambiente SolidaryTech FASE 5.
# EVOLUTIVO: cresce a cada sprint do hackathon.
#
# Sprint 2 (atual): bootstrap backend + terraform apply + kubeconfig
# Sprint 3 (futuro): + build/push imagens ECR
# Sprint 4 (futuro): + ArgoCD + GitOps Applications + NGINX Ingress
# Sprint 5 (futuro): + Monitoring Stack (Prometheus + Loki + Grafana + OTel)
# Sprint 6 (futuro): + Velero + DR drill
#
# Uso:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_SESSION_TOKEN=...
#   ./scripts/setup-full.sh [--auto-approve]
###############################################################################
set -e
set -o pipefail  # garante que erro em pipeline propaga (evita `| tee` mascarar exit code)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$PROJECT_DIR/terraform/environments/primary"

AUTO_APPROVE=""
if [ "$1" = "--auto-approve" ]; then
    AUTO_APPROVE="-auto-approve"
fi

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
echo "  SolidaryTech - Setup Completo (Sprint 2)"
echo "============================================"
echo ""

###############################################################################
# Step 0: Verificacoes iniciais
###############################################################################
log_info "[0/5] Verificando pre-requisitos..."

# AWS creds (suporta env vars OU aws configure)
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
fi
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log_error "Credenciais AWS nao encontradas (nem em env vars, nem em aws configure)."
    exit 1
fi

if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log_error "Credenciais AWS invalidas ou expiradas."
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_ok "AWS Account: $ACCOUNT_ID"
log_ok "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:12}..."

# Ferramentas
for tool in terraform kubectl aws; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        log_error "Ferramenta nao encontrada: $tool"
        exit 1
    fi
done
log_ok "Ferramentas: terraform, kubectl, aws"

# terraform.tfvars — auto-gerar se nao existir
if [ ! -f "$ENV_DIR/terraform.tfvars" ]; then
    log_warn "terraform.tfvars nao encontrado. Gerando automaticamente..."
    cp "$ENV_DIR/terraform.tfvars.example" "$ENV_DIR/terraform.tfvars"

    # Substituir lab_role_arn com ACCOUNT_ID real (AWS Academy padrao)
    sed -i.bak "s|SEU_ACCOUNT_ID|${ACCOUNT_ID}|g" "$ENV_DIR/terraform.tfvars"
    rm -f "$ENV_DIR/terraform.tfvars.bak"

    # Gerar db_password aleatorio (24 chars alfanumericos)
    DB_PASS=$(openssl rand -base64 36 | tr -dc 'a-zA-Z0-9' | head -c 24)
    sed -i.bak "s|TROQUE_AQUI_DEV_PASSWORD|${DB_PASS}|g" "$ENV_DIR/terraform.tfvars"
    rm -f "$ENV_DIR/terraform.tfvars.bak"

    log_ok "terraform.tfvars gerado"
    log_warn "db_password aleatoria salva em terraform.tfvars (no .gitignore)"
    log_warn "Guarde uma copia se for compartilhar com o grupo!"
else
    log_ok "terraform.tfvars presente"
fi

echo ""

###############################################################################
# Step 1: Bootstrap backend
###############################################################################
log_info "[1/5] Garantindo backend remoto (S3 + DynamoDB lock)..."
"$SCRIPT_DIR/bootstrap-backend.sh" > /tmp/bootstrap.log 2>&1 \
    && log_ok "Backend OK" \
    || { log_error "Bootstrap falhou. Veja /tmp/bootstrap.log"; cat /tmp/bootstrap.log; exit 1; }

echo ""

###############################################################################
# Step 2: Terraform init + plan
###############################################################################
log_info "[2/5] Terraform init + plan..."
cd "$ENV_DIR"

# Backend config dinamico (bucket sufixado com ACCOUNT_ID — unicidade global)
BUCKET="tc5-solidarytech-tfstate-${ACCOUNT_ID}"
TABLE="tc5-solidarytech-tflock-${ACCOUNT_ID}"

terraform init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="dynamodb_table=${TABLE}" \
    > /tmp/tf-init.log 2>&1 \
    && log_ok "Init OK (backend: s3://${BUCKET})" \
    || { log_error "terraform init falhou. Veja /tmp/tf-init.log"; cat /tmp/tf-init.log; exit 1; }

terraform plan -out=tfplan.binary -input=false 2>&1 | tail -20
echo ""

###############################################################################
# Step 3: Apply (com confirmacao manual se nao auto-approve)
###############################################################################
log_info "[3/5] Terraform apply..."

if [ -z "$AUTO_APPROVE" ]; then
    echo ""
    log_warn "Revise o plano acima. Pronto para aplicar?"
    read -rp "Digite 'apply' para continuar (qualquer outra coisa cancela): " CONFIRM
    if [ "$CONFIRM" != "apply" ]; then
        log_warn "Apply cancelado pelo usuario."
        rm -f tfplan.binary
        exit 0
    fi
fi

log_info "Aplicando (pode levar ~15-20 minutos)..."
terraform apply -input=false tfplan.binary
rm -f tfplan.binary
log_ok "Apply concluido"

echo ""

###############################################################################
# Step 4: Configurar kubectl
###############################################################################
log_info "[4/5] Configurando kubectl..."

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null
log_ok "kubeconfig atualizado para cluster: $CLUSTER_NAME"

log_info "Validando acesso ao cluster..."
kubectl get nodes
echo ""

###############################################################################
# Step 5: Resumo
###############################################################################
log_info "[5/5] Outputs do ambiente:"
echo ""
terraform output
echo ""

echo "============================================"
log_ok "Setup Sprint 2 concluido com sucesso"
echo "============================================"
echo ""
echo "Proximos passos (futuro):"
echo "  Sprint 3: configurar pipelines CI/CD (GitHub Actions)"
echo "  Sprint 4: setup ArgoCD + manifests GitOps"
echo ""
echo "Para destruir tudo (economia de custo no fim do dia):"
echo "  ./scripts/destroy-all.sh"
echo ""
echo "Para atualizar credenciais AWS Academy (a cada 4h):"
echo "  ./scripts/update-aws-credentials.sh  (sera adicionado no Sprint 4)"
