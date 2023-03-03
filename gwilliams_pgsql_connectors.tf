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


  # Up-to-date ACL definitions
  # https://docs.confluent.io/cloud/current/connectors/service-account.html#source-connector-service-account
  confluent_cloud_connector_generic_acls = {
    "SinkConnector" = {
      # Set a DESCRIBE ACL to the cluster.
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "DESCRIBE" --cluster-scope
      "a" = {resource_type = "CLUSTER", resource_name = "kafka-cluster", pattern_type  = "LITERAL", operation = "DESCRIBE"},
    
      # Set a READ ACL to pageviews
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "READ" --topic "pageviews"
      "b" = {resource_type = "TOPIC", resource_name = "{TOPIC}", pattern_type  = "LITERAL", operation = "READ"},
    
      # Set a CREATE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "dlq-lcc-"
      "c" = {resource_type = "TOPIC", resource_name = "dlq-lcc-{CONNECTOR_ID}", pattern_type  = "LITERAL", operation = "CREATE"},
    
      # Set a WRITE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "dlq-lcc-"
      "d" = {resource_type = "TOPIC", resource_name = "dlq-lcc-{CONNECTOR_ID}", pattern_type  = "LITERAL",operation = "WRITE"},
    
      # Set a READ ACL to a consumer group with the following prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "READ"  --prefix --consumer-group "connect-lcc-"
      "e" = {resource_type = "GROUP", resource_name = "connect-lcc", pattern_type  = "PREFIXED", operation = "READ"},
    },
    "SourceConnector" = {
      # Set a DESCRIBE ACL to the cluster.
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "DESCRIBE" --cluster-scope
      "a" = {resource_type = "CLUSTER", resource_name = "kafka-cluster", pattern_type = "LITERAL", operation = "DESCRIBE"},

      # Set a WRITE ACL to passengers:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --topic "passengers"
      "b" = {resource_type = "TOPIC", resource_name = "{TOPIC}", pattern_type  = "LITERAL", operation = "WRITE"},
    }
  }

  confluent_cloud_connector_specific_acls = {

    # jdbc    
    "MicrosoftSqlServerSource" = merge(local.confluent_cloud_connector_generic_acls.SourceConnector, {
      # Add the following ACL entries for these source connectors:
      # Confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "<topic.prefix>"
      "1" = {resource_type = "TOPIC", resource_name = "{TOPIC_PREFIX}", pattern_type  = "PREFIXED", operation = "CREATE"},
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "<topic.prefix>"
      "2" = {resource_type = "TOPIC", resource_name = "{TOPIC_PREFIX}", pattern_type  = "PREFIXED", operation = "WRITE"},
    }),

    # debezium
    "SqlServerCdcSource" = merge(local.confluent_cloud_connector_generic_acls.SourceConnector,{
      # ACLs to create and write to table related topics prefixed with <database.server.name>:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "<database.server.name>"
      "1" = {resource_type = "TOPIC", resource_name = "{DATABASE_SERVER_NAME}", pattern_type  = "PREFIXED", operation = "CREATE"},
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "<database.server.name>"
      "2" = {resource_type = "TOPIC", resource_name = "{DATABASE_SERVER_NAME}", pattern_type  = "PREFIXED", operation = "WRITE"},

      # ACLs to describe configurations at the cluster scope level:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --cluster-scope --operation "DESCRIBE-CONFIGS"
      "3" = {resource_type = "CLUSTER", resource_name = "kafka-cluster", pattern_type  = "LITERAL", operation = "DESCRIBE_CONFIGS"},
    }),

    # s3
    "S3_SINK" = local.confluent_cloud_connector_generic_acls.SourceConnector
  }

  all_connectors_map = merge(local.connectors_prevent_destroy_false_map, local.connectors_prevent_destroy_true_map)

  token_replacements_map = merge({
    for k,v in local.all_connectors_map: 
      k => {
        # connector id
        "{CONNECTOR_ID}" = coalesce(try(confluent_connector.confluent_cloud_connectors_prevent_destroy_true[k].id, confluent_connector.confluent_cloud_connectors_prevent_destroy_false[k].id), "__ERROR__")
        
        # topic ???

        # topic.prefix
        "{TOPIC_PREFIX}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["topic.prefix"], "__MISSING__")
        # database.server.name
        "{DATABASE_SERVER_NAME}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["database.server.name"], "__MISSING__")
      }
  })
}

output "token_replacements_map" {
  value = local.token_replacements_map
}

output "all_connectors_map" {
  value = local.all_connectors_map
}

output "confluent_cloud_connector_config_sensitive_secret_names"{
  value = keys(try(data.aws_secretsmanager_secret_version.secrets, {}))
}


#
# Connectors 
#
resource "confluent_connector" "confluent_cloud_connectors_prevent_destroy_true" {
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

resource "confluent_connector" "confluent_cloud_connectors_prevent_destroy_false" {
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

# resource "confluent_kafka_acl" "gwilliams-sa-describe-cluster" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }
#   resource_type = "CLUSTER"
#   resource_name = "kafka-cluster"
#   pattern_type  = "LITERAL"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "DESCRIBE"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }
# }


# # ACL requirements for confluent connect:
# # https://docs.confluent.io/cloud/current/connectors/service-account.html#service-accounts
# # Set a DESCRIBE ACL to the cluster.
# # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "DESCRIBE" --cluster-scope
# resource "confluent_kafka_acl" "gwilliams-sa-describe-cluster" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }
#   resource_type = "CLUSTER"
#   resource_name = "kafka-cluster"
#   pattern_type  = "LITERAL"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "DESCRIBE"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }
# }

# # Set a READ ACL to $TOPIC (expanded to all topics to allow creation of arbitrary connectors)
# # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "READ" --topic "pageviews"
# resource "confluent_kafka_acl" "gwilliams-sa-read-all-topics" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }

#   resource_type = "TOPIC"
#   resource_name = "*"
#   pattern_type  = "LITERAL"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "READ"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }
# }



# # Set a CREATE ACL to the following topic prefix:
# # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "dlq-lcc-"
# resource "confluent_kafka_acl" "gwilliams-sa-create-dlq-lcc" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }

#   resource_type = "TOPIC"
#   resource_name = "dlq-lcc"
#   pattern_type  = "PREFIXED"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "CREATE"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }

# }

# # Set a WRITE ACL to the following topic prefix:
# # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "dlq-lcc-"
# resource "confluent_kafka_acl" "gwilliams-sa-write-dlq-lcc" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }

#   resource_type = "TOPIC"
#   resource_name = "dlq-lcc"
#   pattern_type  = "PREFIXED"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "WRITE"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }
# }

# # Set a READ ACL to a consumer group with the following prefix:
# # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "READ"  --prefix --consumer-group "connect-lcc-"
# resource "confluent_kafka_acl" "gwilliams-sa-read-dlq-lcc" {
#   kafka_cluster {
#     id = confluent_kafka_cluster.gwilliams-cluster.id
#   }

#   resource_type = "GROUP"
#   resource_name = "connect-lcc"
#   pattern_type  = "PREFIXED"
#   principal     = "User:${confluent_service_account.gwilliams_svc_acct.id}"
#   host          = "*"
#   operation     = "READ"
#   permission    = "ALLOW"
#   rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

#   credentials {
#     key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
#     secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
#   }
# }