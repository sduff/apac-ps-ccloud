terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.28.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }

    sql = {
      source = "paultyng/sql"
      version = "0.5.0"
    }

  }
}

# Confluent Cloud API Key variables, stored in Terraform Cloud Variable Sets
variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API Key (also referred as Cloud API ID)"
  type        = string
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API Secret"
  type        = string
  sensitive   = true
}

# Confluent Terraform Provider
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

provider "azurerm" {
  features {}
}

provider "aws" {
}

provider "sql" {
  url = "postgresql://simon:i5OzSgisRBAGdlNGhbOpog@sduff-demo-01-4186.8nk.cockroachlabs.cloud:26257/defaultdb?sslmode=verify-full"
}


resource "confluent_environment" "shared-env" {
  display_name = "Terraform-Environment"
}

# Service Account to manage Confluent Cloud resources (OrgAdmin)
data "confluent_service_account" "terraform_sa" {
  display_name = "terraform_sa"
}

