# Create a standard cluster
resource "confluent_kafka_cluster" "sduff-example-cluster" {
  display_name = "sduff-std-cluster"

  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "ap-southeast-2"
  standard {}

  environment {
    id = confluent_environment.shared-env.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Kafka API Key
# This does not need to be stored in the KeyVault as it is only used in
# Terraform for configuring the Kafka cluster
resource "confluent_api_key" "sduff-svc-acct-example-cluster-kafka-api-key" {
  display_name = "sduff-svc-acct-example-cluster-kafka-api-key"
  description  = "sduff Service Account Example Cluster Kafka API Key"
  owner {
    id          = confluent_service_account.sduff-svc-acct.id
    api_version = confluent_service_account.sduff-svc-acct.api_version
    kind        = confluent_service_account.sduff-svc-acct.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.sduff-example-cluster.id
    api_version = confluent_kafka_cluster.sduff-example-cluster.api_version
    kind        = confluent_kafka_cluster.sduff-example-cluster.kind

    environment {
      id = confluent_environment.shared-env.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Create a topic in this cluster
resource "confluent_kafka_topic" "sduff-std-cluster-topic-ironman" {
  kafka_cluster {
    id = confluent_kafka_cluster.sduff-std-cluster.id
  }

  topic_name    = "sduff-ironman"
  rest_endpoint = confluent_kafka_cluster.sduff-std-cluster.rest_endpoint
  credentials {
    key    = confluent_api_key.sduff-svc-acct-example-cluster-kafka-api-key.id
    secret = confluent_api_key.sduff-svc-acct-example-cluster-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}
