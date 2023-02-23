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
data "sql_query" "gwilliams_sql_connectors" {
  # its impossible to dynamically set the lifecycle.prevent_destroy meta argument with the DSL:
  # https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#literal-values-only
  #
  # If dynamic lifecycle tagging is required we can filter prevent_destroy=true vs prevent_destroy=false
  # and have each dataset be managed by a different terraform resource.
  query = "SELECT * FROM confluent_cloud.connectors WHERE prevent_destroy = true and managed = true"
  provider = sql.gwilliams_sql
}



locals {
  
  # transform [key, config_sensitive, config_nonsensitive, prevent_destroy]
  # to {key => {key: 'foo', config_sensitive: '{}', config_nonsensitive: '{}', prevent_destroy: true}}
  connectors_map = { 
    for row in data.sql_query.gwilliams_sql_connectors.result:
      row.key => row
  }
}


#
# Connectors 
#
resource "confluent_connector" "gwilliams-connectors" {
  environment {
    id = confluent_environment.shared-env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.connectors_map

  config_sensitive = jsondecode(each.value.config_sensitive)
  config_nonsensitive = jsondecode(each.value.config_nonsensitive)

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