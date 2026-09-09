terraform {
  required_version = ">= 1.13.0, < 1.17.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project_prefix
      Purpose   = "classroom-demo"
      ManagedBy = "terraform"
    }
  }
}
