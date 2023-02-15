# Configure a Schema Registry for this environment

# Create a Schema Registry API Key for the Service Account
resource "confluent_api_key" "terraform_sa_schema_registry_api_key" {
  display_name = "terraform_sa_schema_registry_api_key"
  description  = "Schema Registry API Key that is owned by 'terraform-sa' service account"
  owner {
    id          = data.confluent_service_account.terraform_sa.id
    api_version = data.confluent_service_account.terraform_sa.api_version
    kind        = data.confluent_service_account.terraform_sa.kind
  }

  managed_resource {
    id          = confluent_schema_registry_cluster.schema_registry.id
    api_version = confluent_schema_registry_cluster.schema_registry.api_version
    kind        = confluent_schema_registry_cluster.schema_registry.kind
    environment {
      id = confluent_environment.shared-env.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Configure where the schema registry will be configured
data "confluent_schema_registry_region" "sr_region" {
  cloud   = "AWS"
  region  = "ap-southeast-2"
  package = "ESSENTIALS"
}

# Additional Schema Registry Cluster Configuration
resource "confluent_schema_registry_cluster_config" "sr_config" {
  compatibility_level = "FULL"

  schema_registry_cluster {
    id = confluent_schema_registry_cluster.schema_registry.id
  }

  rest_endpoint = confluent_schema_registry_cluster.schema_registry.rest_endpoint

  credentials {
    key    = confluent_api_key.terraform_sa_schema_registry_api_key.id
    secret = confluent_api_key.terraform_sa_schema_registry_api_key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Schema Registry Resource
resource "confluent_schema_registry_cluster" "schema_registry" {
  environment {
    id = confluent_environment.shared-env.id
  }

  package = data.confluent_schema_registry_region.sr_region.package

  region {
    id = data.confluent_schema_registry_region.sr_region.id
  }

  lifecycle {
    prevent_destroy = true
  }
}
