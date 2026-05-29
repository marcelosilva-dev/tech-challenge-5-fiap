# DR environment (us-west-2) — Warm Standby skinny.
# Apenas o necessario para o donation-service (Hot Path) sobreviver a failover regional:
#   - VPC propria + EKS (1 node skeleton)
#   - RDS donation-db como Cross-Region Read Replica do primary
#   - SQS recriada (mensagens em voo se perdem, conforme PCN.md)
#
# NAO criado aqui (cobertos por outros mecanismos):
#   - ngo-db (Velero backup cobre — RPO 24h aceitavel)
#   - DynamoDB volunteers (Global Tables ja replica nativamente — config no primary)
#   - ECR (replicacao automatica via aws_ecr_replication_configuration no primary)

module "networking" {
  source = "../../modules/networking"

  project_name       = "${var.project_name}-dr"
  region             = var.aws_region
  azs                = var.azs
  single_nat_gateway = true # FinOps: 1 NAT em DR e suficiente
}

module "eks" {
  source = "../../modules/eks"

  project_name           = "${var.project_name}-dr"
  cluster_name           = "${var.project_name}-cluster-dr"
  cluster_role_arn       = var.lab_role_arn
  node_role_arn          = var.lab_role_arn
  private_subnet_ids     = module.networking.private_subnet_ids
  public_subnet_ids      = module.networking.public_subnet_ids
  node_security_group_id = module.networking.eks_nodes_sg_id

  # Skeleton: 1 node em DR posture. scripts/dr-failover.sh escala para 3.
  node_desired_size = var.node_desired_size
  node_min_size     = 1
  node_max_size     = 4
}

# -----------------------------------------------------------------------------
# RDS donation-db — Cross-Region Read Replica do primary
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "donation_dr" {
  name       = "${var.project_name}-dr-rds-subnet-group"
  subnet_ids = module.networking.private_subnet_ids

  tags = {
    Name = "${var.project_name}-dr-rds-subnet-group"
  }
}

resource "aws_db_instance" "donation_replica" {
  identifier             = "${var.project_name}-donation-db-dr"
  instance_class         = "db.t3.micro"
  replicate_source_db    = var.primary_donation_db_arn # ARN cross-region completo
  db_subnet_group_name   = aws_db_subnet_group.donation_dr.name
  vpc_security_group_ids = [module.networking.rds_postgres_sg_id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  storage_encrypted      = true
  apply_immediately      = true

  # Performance Insights tambem em DR (necessario para SRE/SLO mesmo no failover)
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = {
    Name      = "${var.project_name}-donation-db-dr"
    Component = "database"
    Service   = "donation"
    Role      = "cross-region-read-replica"
  }
}

# -----------------------------------------------------------------------------
# SQS — recriada em DR (mensagens em voo se perdem no failover, ver PCN.md)
# -----------------------------------------------------------------------------
module "messaging_dr" {
  source = "../../modules/messaging"

  project_name = "${var.project_name}-dr"
}
