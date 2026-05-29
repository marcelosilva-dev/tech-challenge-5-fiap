#!/bin/bash
###############################################################################
# destroy-all.sh
#
# Destruicao completa do ambiente primary com cleanup robusto de:
#   1. Recursos Kubernetes (LoadBalancers, Ingresses, namespaces) que
#      bloqueiam o terraform destroy via ENIs orfas
#   2. LoadBalancers AWS orfaos (Classic + ALB/NLB)
#   3. ENIs (Network Interfaces) orfas na VPC
#   4. Security Groups customizados
#   5. Por fim: terraform destroy
#
# IMPORTANTE: Nao deleta o backend (bucket S3 + DynamoDB lock). Para
# remove-los completamente, faca manualmente apos confirmar que ninguem
# mais usa.
#
# Uso:
#   export AWS_ACCESS_KEY_ID=...
#   ./scripts/destroy-all.sh [--auto-approve]
###############################################################################
set -e
set -o pipefail  # garante que erro em pipeline propaga (evita `| tee` mascarar exit code)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$PROJECT_DIR/terraform/environments/primary"
CLUSTER_NAME="solidarytech-cluster"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
VPC_NAME_TAG="solidarytech-vpc"

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
echo "  SolidaryTech - Destruicao completa"
echo "============================================"
echo ""

if [ -z "$AUTO_APPROVE" ]; then
    log_warn "Isso vai DESTRUIR TUDO no ambiente primary (us-east-1)."
    log_warn "EKS cluster, RDS, DynamoDB, SQS, VPC, etc. — irreversivel."
    read -rp "Digite 'destroy' para confirmar: " CONFIRM
    if [ "$CONFIRM" != "destroy" ]; then
        log_warn "Destroy cancelado pelo usuario."
        exit 0
    fi
fi

# ===== Step 0: AWS creds =====
log_info "[0/5] Verificando credenciais AWS..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log_error "Credenciais AWS invalidas ou expiradas."
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="tc5-solidarytech-tfstate-${ACCOUNT_ID}"
TABLE="tc5-solidarytech-tflock-${ACCOUNT_ID}"
log_ok "AWS Account: $ACCOUNT_ID"
log_ok "Backend:     s3://$BUCKET"
echo ""

# ===== Step 1: Cleanup K8s =====
log_info "[1/5] Limpando recursos Kubernetes que podem segurar ENIs..."

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1

    # Deletar Services tipo LoadBalancer
    log_info "Procurando Services LoadBalancer..."
    LB_SVCS=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('spec', {}).get('type') == 'LoadBalancer':
        print(f\"{item['metadata']['namespace']}/{item['metadata']['name']}\")
" 2>/dev/null || true)

    if [ -n "$LB_SVCS" ]; then
        for svc in $LB_SVCS; do
            NS=$(echo "$svc" | cut -d/ -f1)
            NAME=$(echo "$svc" | cut -d/ -f2)
            log_info "  Deletando svc $NS/$NAME"
            kubectl delete svc "$NAME" -n "$NS" --timeout=60s 2>/dev/null || true
        done
        log_info "Aguardando LBs serem removidos (ate 120s)..."
        for i in $(seq 1 24); do
            CNT=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers | length(@)' --output text 2>/dev/null || echo "0")
            CNT_CLASSIC=$(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions | length(@)' --output text 2>/dev/null || echo "0")
            TOTAL=$((CNT + CNT_CLASSIC))
            if [ "$TOTAL" -eq 0 ]; then
                log_ok "Todos LBs removidos"
                break
            fi
            echo "  ... $TOTAL LBs restantes (tentativa $i/24)"
            sleep 5
        done
    else
        log_ok "Nenhum Service LoadBalancer"
    fi

    # Deletar Ingress
    kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || true

    # Velero precisa de cleanup especial: finalizers em Backups/Restores podem
    # bloquear delete do namespace. Helm uninstall remove CRDs e finalizers.
    if kubectl get namespace velero > /dev/null 2>&1; then
        log_info "Limpando Velero (helm uninstall + remover finalizers)..."
        helm uninstall velero -n velero --timeout 60s 2>/dev/null || true
        # Forca delete de Backups/Restores presos por finalizer
        for resource in backups restores schedules backupstoragelocations volumesnapshotlocations; do
            kubectl get $resource.velero.io -n velero -o name 2>/dev/null | \
                xargs -r kubectl patch -n velero --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
    fi

    # Deletar namespaces customizados (pega monitoring, argocd, velero,
    # ingress-nginx, solidarytech — tudo que tem LBs ou ENIs)
    log_info "Deletando namespaces customizados..."
    CUSTOM_NS=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
        grep -v -E '^(default|kube-system|kube-public|kube-node-lease)$' || true)
    for ns in $CUSTOM_NS; do
        log_info "  Deletando ns $ns"
        kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
    done

    log_info "Aguardando 30s para ENIs liberarem..."
    sleep 30
else
    log_warn "Cluster $CLUSTER_NAME nao encontrado, pulando cleanup K8s"
fi
echo ""

# ===== Step 2: Cleanup LBs orfaos =====
log_info "[2/5] Limpando LoadBalancers orfaos..."

# Classic
for elb in $(aws elb describe-load-balancers --region "$REGION" --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text 2>/dev/null); do
    log_warn "  Deletando Classic ELB orfao: $elb"
    aws elb delete-load-balancer --load-balancer-name "$elb" --region "$REGION" 2>/dev/null || true
done

# v2 (ALB/NLB)
for arn in $(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null); do
    log_warn "  Deletando LB v2 orfao..."
    for lst in $(aws elbv2 describe-listeners --load-balancer-arn "$arn" --region "$REGION" --query 'Listeners[*].ListenerArn' --output text 2>/dev/null); do
        aws elbv2 delete-listener --listener-arn "$lst" --region "$REGION" 2>/dev/null || true
    done
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
done

# Target groups
for tg in $(aws elbv2 describe-target-groups --region "$REGION" --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null); do
    aws elbv2 delete-target-group --target-group-arn "$tg" --region "$REGION" 2>/dev/null || true
done

log_ok "LBs limpos"
echo ""

# ===== Step 3: Cleanup ENIs orfas =====
log_info "[3/5] Limpando ENIs orfas..."

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=$VPC_NAME_TAG" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    log_info "VPC: $VPC_ID"

    # ENIs status=available
    for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
        log_warn "  Deletando ENI available: $eni"
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
    done

    # ENIs in-use que nao sao do EKS — tentar detach + delete
    aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=in-use" \
        --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,AttachId:Attachment.AttachmentId}' \
        --output json 2>/dev/null | \
    python3 -c "
import json, sys
for eni in json.load(sys.stdin):
    print(f\"{eni['Id']}|{eni.get('AttachId', '')}\")" | \
    while IFS='|' read -r eni_id attach_id; do
        [ -z "$eni_id" ] && continue
        if [ -n "$attach_id" ]; then
            log_warn "  Detaching $eni_id"
            aws ec2 detach-network-interface --attachment-id "$attach_id" --force --region "$REGION" 2>/dev/null || true
            sleep 3
        fi
        log_warn "  Deletando $eni_id"
        aws ec2 delete-network-interface --network-interface-id "$eni_id" --region "$REGION" 2>/dev/null || true
    done
    log_ok "ENIs limpas"
else
    log_ok "VPC nao encontrada (ja deletada)"
fi
echo ""

# ===== Step 4: Terraform destroy =====
log_info "[4/5] Terraform destroy..."
cd "$ENV_DIR"

# Bug fix: terraform.tfvars pode nao existir (gitignored, removido entre apply
# e destroy). Sem ele, terraform pede input interativo e trava em background.
# Geramos placeholder minimo — o destroy nao usa db_password de fato.
if [ ! -f "terraform.tfvars" ]; then
    log_warn "terraform.tfvars ausente — gerando placeholder para destroy..."
    cat > terraform.tfvars <<EOF
lab_role_arn = "arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
db_password  = "placeholder_not_used_for_destroy"
EOF
    log_ok "terraform.tfvars placeholder criado"
fi

terraform init -input=false -reconfigure \
    -backend-config="bucket=${BUCKET}" \
    -backend-config="dynamodb_table=${TABLE}" \
    > /tmp/tf-init-destroy.log 2>&1

STATE_COUNT=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

if [ "$STATE_COUNT" -gt 0 ]; then
    log_info "Encontrados $STATE_COUNT recursos no state. Destroying..."
    # -input=false obrigatorio: sem TTY (background/CI), terraform travaria
    # pedindo qualquer variavel que falte. Falha rapido em vez de bloquear.
    terraform destroy -auto-approve -input=false -lock-timeout=120s
    log_ok "Destroy concluido"
else
    log_ok "State vazio, nada a destruir"
fi
echo ""

# ===== Step 5: Verificacao final =====
log_info "[5/5] Verificacao final do ambiente:"
echo ""
echo "  VPCs nao-default:   $(aws ec2 describe-vpcs --region $REGION --filters 'Name=is-default,Values=false' --query 'Vpcs | length(@)' --output text 2>/dev/null)"
echo "  EKS clusters:       $(aws eks list-clusters --region $REGION --query 'clusters | length(@)' --output text 2>/dev/null)"
echo "  RDS instances:      $(aws rds describe-db-instances --region $REGION --query 'DBInstances | length(@)' --output text 2>/dev/null)"
echo "  ECR repositories:   $(aws ecr describe-repositories --region $REGION --query 'repositories | length(@)' --output text 2>/dev/null)"
echo "  NAT Gateways:       $(aws ec2 describe-nat-gateways --region $REGION --filter 'Name=state,Values=available,pending' --query 'NatGateways | length(@)' --output text 2>/dev/null)"
echo "  Elastic IPs:        $(aws ec2 describe-addresses --region $REGION --query 'Addresses | length(@)' --output text 2>/dev/null)"
echo "  Load Balancers v2:  $(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers | length(@)' --output text 2>/dev/null)"
echo ""

log_ok "Destruicao finalizada"
echo ""

# Buckets preservados (custo desprezivel mas existem)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
log_info "Recursos PRESERVADOS (custo ~$0.20/mes, removiveis manualmente):"
echo "  - s3://tc5-solidarytech-tfstate-${ACCOUNT_ID}              (state Terraform — manter para re-deploy)"
echo "  - DynamoDB tc5-solidarytech-tflock-${ACCOUNT_ID}          (lock Terraform — manter)"
echo "  - s3://solidarytech-velero-backups-${ACCOUNT_ID}          (Velero backups us-west-2)"
echo ""

# Aviso sobre DR environment (se state nao-vazio em environments/dr)
DR_ENV_DIR="$PROJECT_DIR/terraform/environments/dr"
if [ -d "$DR_ENV_DIR/.terraform" ] || aws s3 ls "s3://tc5-solidarytech-tfstate-${ACCOUNT_ID}/environments/dr/" 2>/dev/null | grep -q tfstate; then
    log_warn "Ambiente DR (us-west-2) PODE TER recursos. Para destruir:"
    echo "    cd terraform/environments/dr && terraform destroy"
fi

echo ""
log_info "Para remover buckets/tables preservados manualmente:"
echo "    aws s3 rb s3://tc5-solidarytech-tfstate-${ACCOUNT_ID} --force"
echo "    aws s3 rb s3://solidarytech-velero-backups-${ACCOUNT_ID} --force --region us-west-2"
echo "    aws dynamodb delete-table --table-name tc5-solidarytech-tflock-${ACCOUNT_ID}"
