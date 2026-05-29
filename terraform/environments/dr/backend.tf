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

  # Backend parcial: bucket sufixado com ACCOUNT_ID e provider via -backend-config.
  # State separado do primary mas mesmo bucket (acessivel cross-region).
  backend "s3" {
    key     = "environments/dr/terraform.tfstate"
    region  = "us-east-1" # bucket de state vive em us-east-1, infra DR em us-west-2
    encrypt = true
  }
}
