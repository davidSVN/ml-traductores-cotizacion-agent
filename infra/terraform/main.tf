# ============================================================================
# Provider AWS + backend remoto del state.
# ============================================================================
# El backend S3 + DynamoDB lock se crean MANUALMENTE antes del primer
# `terraform init` (huevo y gallina). Ver infra/README.md.
# ============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State remoto: el archivo terraform.tfstate (que contiene IDs y, peor,
  # secretos como passwords si los hubiera) vive cifrado en S3, no local.
  # DynamoDB hace de lock para que dos personas no apliquen cambios a la vez.
  backend "s3" {
    bucket         = "ml-traductores-tfstate"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ml-traductores-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Tags que se aplican a TODOS los recursos automáticamente.
  # Útil para filtrar costos en Cost Explorer y para auditoría.
  default_tags {
    tags = {
      Project   = "ml-traductores-agent"
      ManagedBy = "terraform"
      Env       = "prod"
    }
  }
}
