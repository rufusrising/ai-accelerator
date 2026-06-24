# --------------------------------------------------------------------
# Cosmos DB (SQL API) usage store. Mirrors `bicep/infra/modules/cosmos-db/cosmos-db.bicep`.
# 5 containers:
#   - ai-usage-container        (partition /productName)
#   - model-pricing             (partition /model)
#   - streaming-export-config   (partition /type)
#   - pii-usage-container       (partition /type)
#   - llm-usage-container       (partition /productName)
#
# Native data-plane role assignment for the Logic App UAMI is performed
# by the root module so it can be deferred until the UAMI principal has
# replicated in AAD (matches Bicep ordering to avoid the transient
# "principal ID was not found in the AAD tenant" failure).
# --------------------------------------------------------------------

variable "account_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "throughput" {
  type    = number
  default = 400
}
variable "private_endpoint_subnet_id" { type = string }
variable "private_endpoint_name" { type = string }
variable "dns_zone_id" { type = string }
variable "consistency_level" {
  type    = string
  default = "Session"
}

variable "database_name" {
  type    = string
  default = "ai-usage-db"
}

variable "containers" {
  type = map(object({
    partition_key_path = string
  }))
  default = {
    "ai-usage-container"      = { partition_key_path = "/productName" }
    "model-pricing"           = { partition_key_path = "/model" }
    "streaming-export-config" = { partition_key_path = "/type" }
    "pii-usage-container"     = { partition_key_path = "/type" }
    "llm-usage-container"     = { partition_key_path = "/productName" }
  }
}

resource "azurerm_cosmosdb_account" "this" {
  name                = lower(var.account_name)
  location            = var.location
  resource_group_name = var.resource_group_name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  tags                = var.tags

  automatic_failover_enabled         = true
  public_network_access_enabled      = false
  access_key_metadata_writes_enabled = false

  consistency_policy {
    consistency_level = var.consistency_level
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "this" {
  name                = var.database_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
}

resource "azurerm_cosmosdb_sql_container" "containers" {
  for_each            = var.containers
  name                = each.key
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  database_name       = azurerm_cosmosdb_sql_database.this.name
  partition_key_paths = [each.value.partition_key_path]
  throughput          = var.throughput

  indexing_policy {
    indexing_mode = "consistent"
  }
}

resource "azurerm_private_endpoint" "cosmos" {
  name                = var.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.private_endpoint_name
    private_connection_resource_id = azurerm_cosmosdb_account.this.id
    is_manual_connection           = false
    subresource_names              = ["sql"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "account_id" { value = azurerm_cosmosdb_account.this.id }
output "account_name" { value = azurerm_cosmosdb_account.this.name }
output "database_name" { value = azurerm_cosmosdb_sql_database.this.name }
output "endpoint" { value = azurerm_cosmosdb_account.this.endpoint }
output "primary_connection_strings" {
  value     = azurerm_cosmosdb_account.this.primary_sql_connection_string
  sensitive = true
}

output "usage_container" { value = "ai-usage-container" }
output "pii_container" { value = "pii-usage-container" }
output "llm_usage_container" { value = "llm-usage-container" }
output "streaming_export_config_container" { value = "streaming-export-config" }
output "model_pricing_container" { value = "model-pricing" }
