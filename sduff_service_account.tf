# Create a service account and give it RBAC

# Create Service Account
resource "confluent_service_account" "sduff-svc-acct" {
  display_name = "sduff-svc-acct"
  description  = "sduff service account for example purposes"
}

# Cluster and Topic defined in sduff_example_cluster_and_topic.tf

# Give Service Account Role Bindings

# Producer - DeveloperWrite
resource "confluent_role_binding" "sduff-example-topic-devread" {
  principal   = "User:${confluent_service_account.sduff-svc-acct.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.sduff-example-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.sduff-example-cluster.id}/topic=${confluent_kafka_topic.sduff-example-topic.topic_name}"
}

# Consumer - DeveloperRead to Topic
resource "confluent_role_binding" "sduff-example-topic-devwrite" {
  principal   = "User:${confluent_service_account.sduff-svc-acct.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.sduff-example-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.sduff-example-cluster.id}/topic=${confluent_kafka_topic.sduff-example-topic.topic_name}"
}

# Consumer - Consumer Group Write
resource "confluent_role_binding" "sduff-example-topic-devwrite-consumergroup" {
  principal   = "User:${confluent_service_account.sduff-svc-acct.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.sduff-example-cluster.rbac_crn}/kafka=${confluent_kafka_cluster.sduff-example-cluster.id}/group=*"
}

# Create an API Key for this service account
resource "confluent_api_key" "sduff-svc-acct-api-key" {
  display_name = "sduff-svc-acct-api-key"
  description  = "sduff Service Account API Key"
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

# Store the API Key in Azure secrets
# Refer to sduff_azure_keyvault.tf
resource "azurerm_key_vault_secret" "azure_keyvault_sduff_svc_acct_api_key_secret" {
  name         = confluent_service_account.sduff_svc_acct.display_name
  value        = "${confluent_api_key.sduff_svc_acct_api_key.id}:${confluent_api_key.sduff_svc_acct_api_key.secret}"
  key_vault_id = azurerm_key_vault.keyvault.id
  depends_on   = [azurerm_key_vault.keyvault]
}
