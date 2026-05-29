locals {
  databases = {
    ngo      = { db_name = "ngo_db", identifier = "${var.project_name}-ngo-db" }
    donation = { db_name = "donation_db", identifier = "${var.project_name}-donation-db" }
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  for_each = local.databases

  identifier             = each.value.identifier
  engine                 = "postgres"
  engine_version         = var.postgres_version
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = each.value.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id]
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # SRE: Performance Insights habilitado para apoiar dashboards/SLOs
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # DR: copia tags para snapshots (importante para inventario cross-region)
  copy_tags_to_snapshot = true

  # Hackathon: facilita destroy. Em producao real, ativar deletion_protection.
  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name      = each.value.identifier
    Component = "database"
    Service   = each.key
  }
}

resource "aws_dynamodb_table" "volunteers" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.enable_dynamodb_global_table
  }

  # Streams pre-requisito para Global Tables (Sprint 6 - DR)
  stream_enabled   = var.enable_dynamodb_global_table
  stream_view_type = var.enable_dynamodb_global_table ? "NEW_AND_OLD_IMAGES" : null

  server_side_encryption {
    enabled = true
  }

  # Sprint 6 DR: replicas cross-region via Global Tables v2 (nativo).
  # Vazio por default; setado para ["us-west-2"] no environment primary
  # quando o DR estiver ativo. Replicacao bidirecional multi-master ~segundos.
  dynamic "replica" {
    for_each = var.dynamodb_replica_regions
    content {
      region_name            = replica.value
      point_in_time_recovery = true
    }
  }

  tags = {
    Name      = var.dynamodb_table_name
    Component = "database"
    Service   = "volunteer"
  }

  # Replicas precisam de mudancas in-place no recurso, lifecycle previne
  # destroy acidental da tabela quando rotacionando regioes
  lifecycle {
    ignore_changes = [
      # Ignora drift em billing_mode caso seja ajustado fora do Terraform
      billing_mode,
    ]
  }
}
