# =============================================================================
# Example of how to manage confluent cloud resources with PostgreSQL
# =============================================================================

#
# Confluent Cloud Topics
# ----------------------
#
# features:
#   * create topics 1:1 database rows
#   * topics are protected from deletion
#   * partitions, config specified in database
#   * partitions can be increased in db, some config settings can be changed in db (eg retentions.ms)
# caveats (as expected with confluent cloud):
#   * partitions can only be increased
#   * some config settings require topic be deleted and recreated - you can delete the topic in the cloud console to
#     force this to happen when you have `prevent_destroy=true` set in terraform

# 
variable "terraform_ci_aws_access_key" {
  description = "AWS access key for getting vault credentials"
  type        = string
  sensitive   = true
}

variable "terraform_ci_aws_secret_key" {
  description = "AWS secret key for getting vault credentials"
  type        = string
  sensitive   = true
}

#
# Secretsmanager access
#

provider "aws" {
  alias = "gwilliams_aws"
  region = "ap-southeast-2"
  access_key = var.terraform_ci_aws_access_key
  secret_key = var.terraform_ci_aws_secret_key
}

data "aws_secretsmanager_secret" "vault" {
  name = "vault" # As stored in the AWS Secrets Manager
  provider = aws.gwilliams_aws
}

data "aws_secretsmanager_secret_version" "vault" {
  secret_id = data.aws_secretsmanager_secret.vault.id
  provider = aws.gwilliams_aws
}

locals {
  vault_credentials = jsondecode(data.aws_secretsmanager_secret_version.vault.secret_string)
}

#
# Vault access
#
provider "vault" {
  address = local.vault_credentials.vault_url
  token = local.vault_credentials.vault_token
  ca_cert_file = "./gwilliams/vault.ca"
}

data "vault_kv_secret_v2" "confluent-cloud-postgresql" {
  mount = "secret"
  name  = "confluent-cloud-postgresql"
}

#
# SQL connection setup
#
provider "sql" {
  alias = "gwilliams_sql"
  url = data.vault_kv_secret_v2.confluent-cloud-postgresql.data.url
}


#
# Boilerplate cluster setup
#
resource "confluent_kafka_cluster" "gwilliams-cluster" {
  display_name = "gwilliams-pgsql-test"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "ap-southeast-2"
  
  # required for RBAC
  standard {}

  environment {
    id = confluent_environment.shared-env.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_api_key" "gwilliams-cluster-kafka-api-key" {
  display_name = "gwilliams-cluster-kafka-api-key"
  description  = "gwilliams Cluster Kafka API Key"
  owner {
    id          = confluent_service_account.gwilliams_svc_acct.id
    api_version = confluent_service_account.gwilliams_svc_acct.api_version
    kind        = confluent_service_account.gwilliams_svc_acct.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.gwilliams-cluster.id
    api_version = confluent_kafka_cluster.gwilliams-cluster.api_version
    kind        = confluent_kafka_cluster.gwilliams-cluster.kind

    environment {
      id = confluent_environment.shared-env.id
    }
  }

}

# Create Service Account
resource "confluent_service_account" "gwilliams_svc_acct" {
  display_name = "gwilliams-svc-acct"
  description  = "gwilliams service account for example purposes"
}

# Access to all my topics
resource "confluent_role_binding" "gwilliams_svc_acct-DeveloperWrite" {
 principal   = "User:${confluent_service_account.gwilliams_svc_acct.id}"
 role_name   = "DeveloperWrite"
 crn_pattern = "${confluent_kafka_cluster.gwilliams-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.gwilliams-cluster.id}/topic=*"
}

resource "confluent_role_binding" "gwilliams_svc_acct-DeveloperRead" {
 principal   = "User:${confluent_service_account.gwilliams_svc_acct.id}"
 role_name   = "DeveloperRead"
 crn_pattern = "${confluent_kafka_cluster.gwilliams-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.gwilliams-cluster.id}/topic=*"
}

resource "confluent_role_binding" "gwilliams_svc_acct-CloudClusterAdmin" {
  principal   = "User:${confluent_service_account.gwilliams_svc_acct.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.gwilliams-cluster.rbac_crn
}

resource "confluent_role_binding" "gwilliams_svc_acct-ResourceOwner" {
  principal   = "User:${confluent_service_account.gwilliams_svc_acct.id}"
  role_name   = "ResourceOwner"
  crn_pattern = "${confluent_kafka_cluster.gwilliams-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.gwilliams-cluster.id}/topic=*"
}


