# --------------------------------------------------------------------
# Key Vault submodule
#   - RBAC-mode KV with private endpoint
#   - Grants the APIM user-assigned managed identity Key Vault Secrets User.
#     The system-assigned identity is granted access by the root module
#     AFTER APIM is created (chicken-and-egg avoidance, matches Bicep).
# --------------------------------------------------------------------

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }

variable "sku_name" {
  type    = string
  default = "standard"
}

variable "soft_delete_retention_days" {
  type    = number
  default = 90
}

variable "purge_protection_enabled" {
  type    = bool
  default = true
}

variable "private_endpoint_subnet_id" { type = string }
variable "private_endpoint_name" { type = string }
variable "dns_zone_id" { type = string }

variable "apim_uami_principal_id" {
  type    = string
  default = ""
}

resource "azurerm_key_vault" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = var.sku_name
  enable_rbac_authorization     = true
  purge_protection_enabled      = var.purge_protection_enabled
  soft_delete_retention_days    = var.soft_delete_retention_days
  public_network_access_enabled = false
  tags                          = var.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_endpoint" "kv" {
  name                = var.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.private_endpoint_name
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

resource "azurerm_role_assignment" "apim_uami_secrets_user" {
  count                = var.apim_uami_principal_id == "" ? 0 : 1
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.apim_uami_principal_id
  principal_type       = "ServicePrincipal"
}

output "id" { value = azurerm_key_vault.this.id }
output "name" { value = azurerm_key_vault.this.name }
output "uri" { value = azurerm_key_vault.this.vault_uri }
