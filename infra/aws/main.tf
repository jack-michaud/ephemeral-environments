# Ephemeral Environments - AWS Infrastructure
# Main Terraform configuration

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to use S3 backend for state
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "ephemeral-environments/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ephemeral-environments"
      ManagedBy   = "terraform"
      Environment = "production"
    }
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Random suffix for unique resource names
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "ephemeral-env"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
}
