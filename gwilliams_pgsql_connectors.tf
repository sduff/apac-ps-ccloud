# =============================================================================
# Example of how to manage confluent cloud resources with PostgreSQL
# =============================================================================

#
# Confluent Cloud Topics
# ----------------------
#
# features:
#   * create connectors 1:1 database rows
#   * config_nonsensitive specified in database
#   * config_sensitive read from secretserver


#
# SQL data extraction
#

# its impossible to dynamically set the lifecycle.prevent_destroy meta argument with the DSL:
# https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#literal-values-only
#
# If dynamic lifecycle tagging is required we can filter prevent_destroy=true vs prevent_destroy=false
# and have each dataset be managed by a different terraform resource.
data "sql_query" "gwilliams_sql_confluent_cloud_connectors_prevent_destroy_true" {
  query = "SELECT * FROM confluent_cloud.connectors WHERE prevent_destroy = true and managed = true"
  provider = sql.gwilliams_sql
}

data "sql_query" "gwilliams_sql_confluent_cloud_connectors_prevent_destroy_false" {
  query = "SELECT * FROM confluent_cloud.connectors WHERE prevent_destroy = false and managed = true"
  provider = sql.gwilliams_sql
}

#
# Secretsmanager secrets per connection
#
# This is used to populate the `config_sensitive` argument when defining a connector. There is no way in terraform
# for a data lookup to be "optional" https://github.com/hashicorp/terraform/issues/16380
#
# The closest we can come to this is to list all avaiable secrets in AWS that match our special tag and then read 
# only those into terraform. We can then coalesce an empty json object or the secret if present
#

# secrets MUST be named confluent_cloud_connector_config_sensitive/<key of connector>

# read the names of secrets in secretsmanager that are tagged with our special tag (confluent_cloud_connector_config_sensitive=true)
data "aws_secretsmanager_secrets" "secrets" {
  filter {
    name = "tag-key"
    values = ["confluent_cloud_connector_config_sensitive"]
  }
  filter {
    name   = "tag-value"
    values = [true]
  }
  provider = aws.gwilliams_aws
}


# read each secret in /secret/connector_config_sensitive
data "aws_secretsmanager_secret_version" "secrets" {
  for_each = data.aws_secretsmanager_secrets.secrets.names
  secret_id = each.key
  provider = aws.gwilliams_aws
}

locals {
  
  # transform [key, config_sensitive, config_nonsensitive, prevent_destroy]
  # to {key => {key: 'foo', config_sensitive: '{}', config_nonsensitive: '{}', prevent_destroy: true}}
  connectors_prevent_destroy_true_map = { 
    for row in data.sql_query.gwilliams_sql_confluent_cloud_connectors_prevent_destroy_true.result:
      row.key => row
  }

  connectors_prevent_destroy_false_map = { 
    for row in data.sql_query.gwilliams_sql_confluent_cloud_connectors_prevent_destroy_false.result:
      row.key => row
  }

  # transform {"connector_config_sensitive/MySqlCdcSourceConnector_0": {...}"}
  # to {MySqlCdcSourceConnector_0 => {...}}
  # eg remove connector_config_sensitive prefix
  connector_config_sensitive = {
    for k,v in data.aws_secretsmanager_secret_version.secrets:
      trimprefix(k, "confluent_cloud_connector_config_sensitive/") => jsondecode(v.secret_string)
  }
}

output "confluent_cloud_connector_config_sensitive_secret_names"{
  value = keys(try(data.aws_secretsmanager_secret_version.secrets, {}))
}


#
# Connectors 
#
resource "confluent_connector" "confluent_cloud_topics_prevent_destroy_true" {
  environment {
    id = confluent_environment.shared-env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.connectors_prevent_destroy_true_map

  config_sensitive = try(local.connector_config_sensitive[each.key], {})
  config_nonsensitive = jsondecode(each.value.config_nonsensitive)

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_connector" "confluent_cloud_topics_prevent_destroy_false" {
  environment {
    id = confluent_environment.shared-env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.connectors_prevent_destroy_false_map

  config_sensitive = try(local.connector_config_sensitive[each.key], {})
  config_nonsensitive = jsondecode(each.value.config_nonsensitive)

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_kafka_acl" "gwilliams-sa-write-all-topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  resource_type = "TOPIC"
  resource_name = "*"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_acl" "gwilliams-sa-create-all-topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  resource_type = "TOPIC"
  resource_name = "*"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
  host          = "*"
  operation     = "CREATE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}