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


# [key, partitions_count, config, prevent_destroy] => {key => {key: 'foo', parititions_count: 5, config: '{"baz": "bas"}', prevent_destroy: true}}
locals {
  topics_map = { 
    for row in data.sql_query.gwilliams_sql_topics.result:
      row.key => row
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
  basic {}

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

