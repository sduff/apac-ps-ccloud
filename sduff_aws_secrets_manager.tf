# Example showing how to save API Key credentials to AWS Secrets Manager

### Confluent Cloud ###

# Create a service account
resource "confluent_service_account" "aws_secrets_manager_svc_acct" {
  display_name = "aws-secrets-manager-service-account"
  description  = "AWS Secrets Manager Example Service Account"
}

# Create an API key
resource "confluent_api_key" "aws_secrets_manager_svc_acct_api_key" {
  display_name = "aws-secrets-manager-service-account-api-key"
  description  = "API Key for the AWS Secrets Manager Example Service Account"
  owner {
    id          = confluent_service_account.aws_secrets_manager_svc_acct.id
    api_version = confluent_service_account.aws_secrets_manager_svc_acct.api_version
    kind        = confluent_service_account.aws_secrets_manager_svc_acct.kind
  }

  lifecycle {
    prevent_destroy = true
  }
}

### AWS ###

# Create a Secrets Manager Secret
resource "aws_secretsmanager_secret" "aws_secrets_manager" {
  name = confluent_service_account.aws_secrets_manager_svc_acct.display_name
}

# Creating a AWS secret
resource "aws_secretsmanager_secret_version" "aws_secrets_manager_svc_acct_api_key_secret" {
  secret_id     = aws_secretsmanager_secret.aws_secrets_manager.id
  secret_string = "${confluent_api_key.aws_secrets_manager_svc_acct_api_key.id}:${confluent_api_key.aws_secrets_manager_svc_acct_api_key.secret}"
}
