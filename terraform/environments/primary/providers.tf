provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "Production"
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
      Repository  = "marcelosilva-dev/tech-challenge-5-fiap"
    }
  }
}
