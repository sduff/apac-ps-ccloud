data "sql_query" "tables" {
  query = "SHOW TABLES;"
}

locals {
  tables = toset([for each in data.sql_query.tables.result : each.table_name])
}

resource "confluent_kafka_topic" "template_topic" {
  for_each   = local.tables
  topic_name = each.value

  kafka_cluster {
    id = confluent_kafka_cluster.sduff-example-cluster.id
  }

  rest_endpoint = confluent_kafka_cluster.sduff-example-cluster.rest_endpoint

  credentials {
    key    = confluent_api_key.sduff-example-cluster-kafka-api-key.id
    secret = confluent_api_key.sduff-example-cluster-kafka-api-key.secret
  }

}
