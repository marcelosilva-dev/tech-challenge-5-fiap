# Provider principal: regiao DR (us-west-2)
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SolidaryTech"
      Environment = "DR" # diferente de "Production" do primary p/ filtrar custos
      CostCenter  = "NGO-Core"
      ManagedBy   = "Terraform"
      Repository  = "rivachef/TC5-SolidaryTech"
    }
  }
}

# Provider secundario apontando para a regiao PRIMARY — necessario apenas para
# ler o ARN do RDS donation-db primary (source da replica cross-region).
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      Project    = "SolidaryTech"
      ManagedBy  = "Terraform"
      Repository = "rivachef/TC5-SolidaryTech"
    }
  }
}
