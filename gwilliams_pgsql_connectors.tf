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

  all_connectors_map = merge(local.connectors_prevent_destroy_false_map, local.connectors_prevent_destroy_true_map)

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
    

      # DLQ patterns adjusted
      # https://confluent.slack.com/archives/C07FCMZ39/p1677902169060959

      # Set a CREATE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "dlq-lcc-"
      "c" = {bootstrap_only = true, resource_type = "TOPIC", resource_name = "dlq-lcc", pattern_type  = "PREFIXED", operation = "CREATE"},
    
      # Set a WRITE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "dlq-lcc-"
      "d" = {bootstrap_only = true, resource_type = "TOPIC", resource_name = "dlq-lcc", pattern_type  = "PREFIXED",operation = "WRITE"},
    
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
    "S3_SINK" = local.confluent_cloud_connector_generic_acls.SinkConnector
  }

  confluent_cloud_connector_generic_acls_post = {
    "SinkConnector" = {
       # Set a CREATE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "CREATE" --prefix --topic "dlq-lcc-"
      "x" = {resource_type = "TOPIC", resource_name = "dlq-{CONNECTOR_ID}", pattern_type  = "LITERAL", operation = "CREATE"},
    
      # Set a WRITE ACL to the following topic prefix:
      # confluent kafka acl create --allow --service-account "<service-account-id>" --operation "WRITE" --prefix --topic "dlq-lcc-"
      "y" = {resource_type = "TOPIC", resource_name = "dlq-{CONNECTOR_ID}", pattern_type  = "LITERAL",operation = "WRITE"},
    }
  }

  # ACLs that we can only create after traversing the connector
  confluent_cloud_connector_specific_acls_post = {
    "SqlServerCdcSource" = {}
    "MicrosoftSqlServerSource" = {}
    "S3_SINK" = local.confluent_cloud_connector_generic_acls_post.SinkConnector
  }

  token_replacements_map = merge({
    for k,v in local.all_connectors_map: 
      k => {       
        # topic - from separate db field. dont try to be smart, learn to be stupid
        "{TOPIC}" = local.all_connectors_map[k]["acl_topic_allow"]

        # topic.prefix
        "{TOPIC_PREFIX}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["topic.prefix"], "__MISSING__")

        # database.server.name
        "{DATABASE_SERVER_NAME}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["database.server.name"], "__MISSING__")
      }
  })

  token_replacements_post_map = merge({
    for k,v in local.all_connectors_map: 
      k => {
        # connector id
        "{CONNECTOR_ID}" = try(
          confluent_connector.confluent_cloud_connectors_prevent_destroy_true[k].id, 
          confluent_connector.confluent_cloud_connectors_prevent_destroy_false[k].id, 
          "__UNKNOWN__"
       )

        # these are not needed         
        # # topic - from separate db field. dont try to be smart, learn to be stupid
        # "{TOPIC}" = local.all_connectors_map[k]["acl_topic_allow"]

        # # topic.prefix
        # "{TOPIC_PREFIX}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["topic.prefix"], "__MISSING__")

        # # database.server.name
        # "{DATABASE_SERVER_NAME}" = try(jsondecode(local.all_connectors_map[k]["config_nonsensitive"])["database.server.name"], "__MISSING__")
      }
  })


  # rewrite ACLs that must exist BEFORE connector is traversed
  confluent_cloud_connector_instance_acls = merge([
    for k,v in local.all_connectors_map: {
      for id, rule in local.confluent_cloud_connector_specific_acls[jsondecode(v["config_nonsensitive"])["connector.class"]]:


        format("%s-%s", k, id) => merge(
          rule, 
          {"connector_name" = k},


          # override the resource name with token replacement
          {"resource_name_munged" = replace(
            rule.resource_name, 
            "/{([^}]+)}/", 
            lookup(
              local.token_replacements_map[k], 
              coalesce(regex("[^{]*(?P<token>{[^}]+})?[^}]*", rule.resource_name).token, "__MISSING__"),
              "__UNKNOWN__"
            )
          )},

          # extract the principal
          {"principal" = "User:${jsondecode(v["config_nonsensitive"])["kafka.service.account.id"]}"}
        )
        # the only way to prevent a terraform resource from being instantiated is to not declare it at all
      } if ! coalesce(rule.bootstrap_only, false) && local.all_connectors_map[k].status == "RUNNING"
  ]...)


  # rewrite ACLs that can only be created AFTER connector is traversed
  confluent_cloud_connector_instance_acls_post = merge([
    for k,v in local.all_connectors_map: {
      for id, rule in local.confluent_cloud_connector_specific_acls_post[jsondecode(v["config_nonsensitive"])["connector.class"]]:


        format("%s-%s", k, id) => merge(
          rule, 
          {"connector_name" = k},


          # override the resource name with token replacement
          {"resource_name_munged" = replace(
            rule.resource_name, 
            "/{([^}]+)}/", 
            lookup(
              local.token_replacements_post_map[k], 
              coalesce(regex("[^{]*(?P<token>{[^}]+})?[^}]*", rule.resource_name).token, "__MISSING__"),
              "__UNKNOWN__"
            )
          )},

          # extract the principal
          {"principal" = "User:${jsondecode(v["config_nonsensitive"])["kafka.service.account.id"]}"}
        )
      }
  ]...)
}

output "confluent_cloud_connector_specific_acls" {
  value = local.confluent_cloud_connector_specific_acls
}

output "confluent_cloud_connector_specific_acls_post" {
  value = local.confluent_cloud_connector_specific_acls_post
}

output "token_replacements_map" {
  value = local.token_replacements_map
}

output "token_replacements_post_map" {
  value = local.token_replacements_post_map
}

output "all_connectors_map" {
  value = local.all_connectors_map
}

output "confluent_cloud_connector_config_sensitive_secret_names"{
  value = keys(try(data.aws_secretsmanager_secret_version.secrets, {}))
}

output "confluent_cloud_connector_instance_acls" {
  value = local.confluent_cloud_connector_instance_acls
}

output "confluent_cloud_connector_instance_acls_post" {
  value = local.confluent_cloud_connector_instance_acls_post
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

  depends_on = [
    confluent_kafka_acl.connector_acls
  ]
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
  
  depends_on = [
    confluent_kafka_acl.connector_acls
  ]
}

resource "confluent_kafka_acl" "connector_acls" {
  for_each = local.confluent_cloud_connector_instance_acls
  
  resource_type = each.value.resource_type
  resource_name = each.value.resource_name_munged
  pattern_type  = each.value.pattern_type
  operation     = each.value.operation
  permission    = "ALLOW"
  
  principal     = each.value.principal
  host          = "*"
  
  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }
  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "connector_acls_post" {
  for_each = local.confluent_cloud_connector_instance_acls_post
  
  resource_type = each.value.resource_type
  resource_name = each.value.resource_name_munged
  pattern_type  = each.value.pattern_type
  operation     = each.value.operation
  permission    = "ALLOW"
  
  principal     = each.value.principal
  host          = "*"
  
  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }
  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }
}
