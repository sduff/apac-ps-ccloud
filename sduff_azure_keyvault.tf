# Example showing how to save API Key credentials to Azure Key Vault

### Confluent Cloud ###

# Create a service account
resource "confluent_service_account" "azure_keyvault_svc_acct" {
  display_name = "azure-keyvault-service-account"
  description  = "Azure Key Vault Example Service Account"
}

# Create an API key
resource "confluent_api_key" "azure_keyvault_svc_acct_api_key" {
  display_name = "azure-keyvault-service-account-api-key"
  description  = "API Key for the Azure Key Vault Example Service Account"
  owner {
    id          = confluent_service_account.azure_keyvault_svc_acct.id
    api_version = confluent_service_account.azure_keyvault_svc_acct.api_version
    kind        = confluent_service_account.azure_keyvault_svc_acct.kind
  }

  lifecycle {
    prevent_destroy = true
  }
}

### Azure ###

# Create a resource Group
resource "azurerm_resource_group" "rg" {
  name     = "apac-ps-confluent-cloud-rg"
  location = "australiasoutheast"
  tags = {
    owner_email = "sduff@confluent.io"
  }
}

# Create a KeyVault
data "azurerm_client_config" "current" {}
resource "azurerm_key_vault" "keyvault" {
  depends_on                  = [azurerm_resource_group.rg]
  name                        = "kv-apac-ps"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Get",
    ]

    secret_permissions = [
      "Get", "Backup", "Delete", "List", "Purge", "Recover", "Restore", "Set",
    ]

    storage_permissions = [
      "Get",
    ]
  }

  tags = {
    owner_email = "sduff@confluent.io"
  }
}

# Create a new secret and store in the keyvault
resource "azurerm_key_vault_secret" "azure_keyvault_svc_acct_api_key_secret" {
  name         = confluent_service_account.azure_keyvault_svc_acct.display_name
  value        = "${confluent_api_key.azure_keyvault_svc_acct_api_key.id}:${confluent_api_key.azure_keyvault_svc_acct_api_key.secret}"
  key_vault_id = azurerm_key_vault.keyvault.id
  depends_on   = [azurerm_key_vault.keyvault]
}
