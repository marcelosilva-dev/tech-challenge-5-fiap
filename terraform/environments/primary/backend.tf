terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend parcial: bucket e dynamodb_table sao passados via
  # -backend-config no `terraform init` (sufixados com ACCOUNT_ID
  # para garantir unicidade global do bucket S3).
  # Ver scripts/setup-full.sh
  backend "s3" {
    key     = "environments/primary/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
