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


resource "confluent_kafka_topic" "gwilliams-topics" {
  kafka_cluster {
    id = confluent_kafka_cluster.gwilliams-cluster.id
  }

  for_each = local.topics_map

  topic_name = each.key
  # todo json from each.value

  rest_endpoint = confluent_kafka_cluster.gwilliams-cluster.rest_endpoint

  lifecycle {
    prevent_destroy = true
  }
}

