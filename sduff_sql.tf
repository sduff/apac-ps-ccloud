data "sql_query" "tables" {
  query = "SHOW TABLES;"
}

locals {
  tables = [data.sql_query.tables.result[0].table_name, data.sql_query.tables[1].table_name ]
}

resource "confluent_kafka_topic" "template_topic" {
  for_each   = toset(local.tables)
  topic_name = each.value

  kafka_cluster {
    id = confluent_kafka_cluster.sduff-example-cluster.id
  }

  rest_endpoint = confluent_kafka_cluster.sduff-example-cluster.rest_endpoint

  credentials {
    key    = confluent_api_key.sduff-example-cluster-kafka-api-key.id
    secret = confluent_api_key.sduff-example-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }

}
