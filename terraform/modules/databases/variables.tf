variable "project_name" {
  description = "Prefixo para nomear recursos."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas onde os RDS serao colocados."
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "Security Group ID liberado para acessar PostgreSQL."
  type        = string
}

variable "postgres_version" {
  description = "Versao do PostgreSQL. Versoes disponiveis no us-east-1 (jan/2026): 16.10 a 16.14."
  type        = string
  default     = "16.10"
}

variable "instance_class" {
  description = "Classe de instancia RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage em GB."
  type        = number
  default     = 20
}

variable "backup_retention_period" {
  description = "Quantos dias manter backups automaticos."
  type        = number
  default     = 7
}

variable "multi_az" {
  description = "Habilitar Multi-AZ (FinOps: false para hackathon, true em prod real)."
  type        = bool
  default     = false
}

variable "db_username" {
  description = "Master username dos bancos."
  type        = string
  default     = "solidary"
}

variable "db_password" {
  description = "Master password dos bancos."
  type        = string
  sensitive   = true
}

variable "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB para voluntarios."
  type        = string
  default     = "SolidaryTechVolunteers"
}

variable "enable_dynamodb_global_table" {
  description = "Configura DynamoDB com PITR e stream para preparar para Global Tables no Sprint 6."
  type        = bool
  default     = true
}

variable "dynamodb_replica_regions" {
  description = "Regioes para Global Tables replicas (Sprint 6 DR). Vazio = sem replicacao cross-region."
  type        = list(string)
  default     = []
}
