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
# SQL data extraction
#

# its impossible to dynamically set the lifecycle.prevent_destroy meta argument with the DSL:
# https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#literal-values-only
#
# If dynamic lifecycle tagging is required we can filter prevent_destroy=true vs prevent_destroy=false
# and have each dataset be managed by a different terraform resource.
data "sql_query" "gwilliams_sql_topics_prevent_destroy_true" {
  query = "SELECT * FROM confluent_cloud.topics WHERE prevent_destroy = true and managed = true"
  provider = sql.gwilliams_sql
}

data "sql_query" "gwilliams_sql_topics_prevent_destroy_false" {
  query = "SELECT * FROM confluent_cloud.topics WHERE prevent_destroy = false and managed = true"
  provider = sql.gwilliams_sql
}


locals {
  # transform [key, partitions_count, config, prevent_destroy]
  # to {key => {key: 'foo', parititions_count: 5, config: '{"baz": "bas"}', prevent_destroy: true}}
  topics_prevent_destroy_true_map = { 
    for row in data.sql_query.gwilliams_sql_topics_prevent_destroy_true.result:
      row.key => row
  }

  topics_prevent_destroy_false_map = { 
    for row in data.sql_query.gwilliams_sql_topics_prevent_destroy_false.result:
      row.key => row
  }
}


#
# Dynamic topics from database
#
resource "confluent_kafka_topic" "gwilliams-topics-prevent-destroy-true" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.topics_prevent_destroy_true_map
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

resource "confluent_kafka_topic" "gwilliams-topics-prevent-destroy-false" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.topics_prevent_destroy_false_map
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
    prevent_destroy = false
  }
}