variable "aws_region" {
  description = "Regiao AWS do ambiente primary."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo logico para nomear recursos."
  type        = string
  default     = "solidarytech"
}

variable "azs" {
  description = "Availability zones (2 minimo)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "lab_role_arn" {
  description = "ARN do LabRole da AWS Academy (usado para cluster e nodes)."
  type        = string
}

variable "db_username" {
  description = "Master username dos RDS."
  type        = string
  default     = "solidary"
}

variable "db_password" {
  description = "Master password dos RDS (NUNCA commitar — use terraform.tfvars local)."
  type        = string
  sensitive   = true
}

variable "node_desired_size" {
  description = "Quantidade desejada inicial de nodes (Sprint 5 ajustara via rightsizing)."
  type        = number
  default     = 3
}

variable "dynamodb_replica_regions" {
  description = "Regioes para replicas DynamoDB Global Tables (Sprint 6 DR). Ex: [\"us-west-2\"]."
  type        = list(string)
  default     = ["us-west-2"]
}
