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
# SQL connection setup
#
variable "gwilliams_postgres_url" {
  description = "SQL DB Connection String"
  type        = string
  sensitive   = true
}

provider "sql" {
  alias = "gwilliams_sql"
  url = var.gwilliams_postgres_url
}


#
# SQL data extraction
#
data "sql_query" "gwilliams_sql_topics" {
  # its impossible to dynamically set the lifecycle.prevent_destroy meta argument with the DSL:
  # https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#literal-values-only
  #
  # If dynamic lifecycle tagging is required we can filter prevent_destroy=true vs prevent_destroy=false
  # and have each dataset be managed by a different terraform resource.
  query = "SELECT * FROM confluent_cloud.topics WHERE prevent_destroy = true"
  provider = sql.gwilliams_sql
}

data "sql_query" "gwilliams_sql_connectors" {
  # its impossible to dynamically set the lifecycle.prevent_destroy meta argument with the DSL:
  # https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#literal-values-only
  #
  # If dynamic lifecycle tagging is required we can filter prevent_destroy=true vs prevent_destroy=false
  # and have each dataset be managed by a different terraform resource.
  query = "SELECT * FROM confluent_cloud.connectors WHERE prevent_destroy = true"
  provider = sql.gwilliams_sql
}



locals {
  
  # topics
  # ------
  # trasform [key, partitions_count, config, prevent_destroy]
  # to {key => {key: 'foo', parititions_count: 5, config: '{"baz": "bas"}', prevent_destroy: true}}
  topics_map = { 
    for row in data.sql_query.gwilliams_sql_topics.result:
      row.key => row
  }

  # trasform [key, config_sensitive, config_nonsensitive, prevent_destroy]
  # to {key => {key: 'foo', config_sensitive: '{}', config_nonsensitive: '{}', prevent_destroy: true}}
  connectors_map = { 
    for row in data.sql_query.gwilliams_sql_topics.result:
      row.key => row
  }

  # default nonsensitive configs for all containers - could also be sourced from another table
  config_nonsensitive_defaults = {
    "kafka.service.account.id": confluent_service_account.gwilliams_svc_acct.id
  }

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
    id          = data.confluent_service_account.terraform_sa.id
    api_version = data.confluent_service_account.terraform_sa.api_version
    kind        = data.confluent_service_account.terraform_sa.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.gwilliams-cluster.id
    api_version = confluent_kafka_cluster.gwilliams-cluster.api_version
    kind        = confluent_kafka_cluster.gwilliams-cluster.kind

    environment {
      id = confluent_environment.shared-env.id
    }
  }

  lifecycle {
    prevent_destroy = true
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

#
# Dynamic topics from database
#
resource "confluent_kafka_topic" "gwilliams-topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.topics_map

  topic_name = each.key
  partitions_count = each.value.partitions_count
  
  # JSON column type is returned as string for the moment: https://github.com/paultyng/terraform-provider-sql/issues/6
  config = jsondecode(each.value.config)

  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

#
# Kafka Connect: Source Connector
#
resource "confluent_connector" "gwilliams-connectors" {
  environment {
    id = confluent_environment.shared-env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.connectors_map

  config_sensitive = decode_json(each.value.config_sensitive)
  config_nonsensitive = merge(local.config_nonsensitive_defaults, decode_json(each.value.config_nonsensitive))

  # depends_on = [
  #   confluent_kafka_acl.app-connector-describe-on-cluster,
  #   confluent_kafka_acl.app-connector-write-on-target-topic,
  #   confluent_kafka_acl.app-connector-create-on-data-preview-topics,
  #   confluent_kafka_acl.app-connector-write-on-data-preview-topics,
  # ]

  # lifecycle {
  #   prevent_destroy = true
  # }
}