variable "gwilliams_postgres_url" {
  description = "SQL DB Connection String"
  type        = string
  sensitive   = true
}

provider "sql" {
  alias = "gwilliams_sql"
  url = var.gwilliams_postgres_url
}

data "sql_query" "gwilliams_sql_topics" {
  query = "SELECT name FROM topics"
  provider = sql.gwilliams_sql
}

locals {
  topics_map = { 
    for row in data.sql_query.gwilliams_sql_topics.result:
    row.name => row
  }

}

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


resource "confluent_kafka_topic" "gwilliams-topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.topics_map

  topic_name = each.key
  # todo json from each.value

  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.gwilliams-cluster-kafka-api-key.id
    secret = confluent_api_key.gwilliams-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

