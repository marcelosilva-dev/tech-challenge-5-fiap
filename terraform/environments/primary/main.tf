module "networking" {
  source = "../../modules/networking"

  project_name = var.project_name
  region       = var.aws_region
  azs          = var.azs
  # FinOps: single NAT no primary (suficiente para producao mid-scale). Em DR ja temos isolamento de regiao.
  single_nat_gateway = true
}

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
}

module "messaging" {
  source = "../../modules/messaging"

  project_name = var.project_name
}

module "databases" {
  source = "../../modules/databases"

  project_name          = var.project_name
  private_subnet_ids    = module.networking.private_subnet_ids
  rds_security_group_id = module.networking.rds_postgres_sg_id

  db_username = var.db_username
  db_password = var.db_password

  # primary nao precisa Multi-AZ no MVP — DR cross-region cobre.
  multi_az = false

  # Sprint 6 DR: replica DynamoDB volunteers em us-west-2 via Global Tables.
  # Vazio = sem replica (default); pode ser desabilitado se o ambiente DR
  # for completamente destruido.
  dynamodb_replica_regions = var.dynamodb_replica_regions
}

module "eks" {
  source = "../../modules/eks"

  project_name           = var.project_name
  cluster_name           = "${var.project_name}-cluster"
  cluster_role_arn       = var.lab_role_arn
  node_role_arn          = var.lab_role_arn
  private_subnet_ids     = module.networking.private_subnet_ids
  public_subnet_ids      = module.networking.public_subnet_ids
  node_security_group_id = module.networking.eks_nodes_sg_id

  node_desired_size = var.node_desired_size
}
