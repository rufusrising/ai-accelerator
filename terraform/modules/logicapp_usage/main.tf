# --------------------------------------------------------------------
# Usage processor stack: Storage Account (4 PEs) + Workflow Standard plan
# + Logic App Standard (functionapp,workflowapp) with VNet integration.
#
# The Logic App processes APIM EventHub usage events and writes per-product
# usage records to Cosmos. Authentication uses the supplied UAMI for
# Cosmos/EventHub/AppInsights data planes.
#
# Mirrors `bicep/infra/modules/logicapp/logicapp.bicep` and
# `bicep/infra/modules/functionapp/storageaccount.bicep`.
# --------------------------------------------------------------------

variable "storage_account_name" { type = string }
variable "logic_app_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "uami_id" { type = string }
variable "uami_principal_id" { type = string }

variable "function_app_subnet_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }

variable "storage_blob_dns_zone_id" { type = string }
variable "storage_file_dns_zone_id" { type = string }
variable "storage_table_dns_zone_id" { type = string }
variable "storage_queue_dns_zone_id" { type = string }

variable "storage_blob_pe_name" { type = string }
variable "storage_file_pe_name" { type = string }
variable "storage_table_pe_name" { type = string }
variable "storage_queue_pe_name" { type = string }

variable "sku_capacity" {
  type    = number
  default = 1
}

variable "logic_content_share_name" {
  type    = string
  default = "usage-logic-content"
}

variable "app_insights_connection_string" { type = string }
variable "app_insights_name" { type = string }
variable "apim_app_insights_name" { type = string }

variable "event_hub_namespace_name" { type = string }
variable "event_hub_name" { type = string }
variable "event_hub_pii_name" { type = string }

variable "cosmos_db_account_name" { type = string }
variable "cosmos_db_database_name" { type = string }
variable "cosmos_db_container_config" { type = string }
variable "cosmos_db_container_usage" { type = string }
variable "cosmos_db_container_pii" { type = string }
variable "cosmos_db_container_llm_usage" { type = string }

# ============================================================
# Storage Account
# ============================================================

resource "azurerm_storage_account" "this" {
  name                            = var.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # Required: Logic App Standard needs WEBSITE_CONTENTAZUREFILECONNECTIONSTRING.
  tags                            = var.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_share" "logic_content" {
  name               = var.logic_content_share_name
  storage_account_id = azurerm_storage_account.this.id
  quota              = 100
}

# Storage Blob Data Owner role for Logic App UAMI (Bicep grants this).
resource "azurerm_role_assignment" "uami_blob_owner" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = var.uami_principal_id
  principal_type       = "ServicePrincipal"
}

# ============================================================
# Private endpoints (blob, file, table, queue)
# ============================================================

locals {
  pe_map = {
    blob  = { name = var.storage_blob_pe_name, subresource = "blob", dns = var.storage_blob_dns_zone_id }
    file  = { name = var.storage_file_pe_name, subresource = "file", dns = var.storage_file_dns_zone_id }
    table = { name = var.storage_table_pe_name, subresource = "table", dns = var.storage_table_dns_zone_id }
    queue = { name = var.storage_queue_pe_name, subresource = "queue", dns = var.storage_queue_dns_zone_id }
  }
}

resource "azurerm_private_endpoint" "storage" {
  for_each            = local.pe_map
  name                = each.value.name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = each.value.name
    private_connection_resource_id = azurerm_storage_account.this.id
    is_manual_connection           = false
    subresource_names              = [each.value.subresource]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [each.value.dns]
  }
}

# ============================================================
# Workflow Standard plan + Logic App Standard
# ============================================================

resource "azurerm_service_plan" "this" {
  name                = "asp-${var.logic_app_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Windows"
  sku_name            = "WS1"
  worker_count        = var.sku_capacity
  tags                = var.tags
}

# Logic App Standard via azurerm_logic_app_standard (kind=functionapp,workflowapp).
resource "azurerm_logic_app_standard" "this" {
  name                       = var.logic_app_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  app_service_plan_id        = azurerm_service_plan.this.id
  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key
  virtual_network_subnet_id  = var.function_app_subnet_id
  tags                       = var.tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [var.uami_id]
  }

  site_config {
    vnet_route_all_enabled           = false
    ftps_state                       = "FtpsOnly"
    min_tls_version                  = "1.2"
    scm_min_tls_version              = "1.2"
    pre_warmed_instance_count        = 1
    elastic_instance_minimum         = 1
    runtime_scale_monitoring_enabled = true
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING    = var.app_insights_connection_string
    FUNCTIONS_EXTENSION_VERSION              = "~4"
    FUNCTIONS_WORKER_RUNTIME                 = "node"
    WEBSITE_NODE_DEFAULT_VERSION             = "~24"
    WEBSITE_CONTENTSHARE                     = azurerm_storage_share.logic_content.name
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = azurerm_storage_account.this.primary_connection_string
    WEBSITE_VNET_ROUTE_ALL                   = "0"
    WEBSITE_CONTENTOVERVNET                  = "1"
    APP_KIND                                 = "workflowapp"
    AzureFunctionsJobHost__extensionBundle   = "Microsoft.Azure.Functions.ExtensionBundle.Workflows"

    eventHub_fullyQualifiedNamespace = "${var.event_hub_namespace_name}.servicebus.windows.net"
    eventHub_name                    = var.event_hub_name
    eventHub_pii_name                = var.event_hub_pii_name

    CosmosDBAccount           = var.cosmos_db_account_name
    CosmosDBDatabase          = var.cosmos_db_database_name
    CosmosDBContainerConfig   = var.cosmos_db_container_config
    CosmosDBContainerUsage    = var.cosmos_db_container_usage
    CosmosDBContainerPII      = var.cosmos_db_container_pii
    CosmosDBContainerLLMUsage = var.cosmos_db_container_llm_usage

    AppInsights_ResourceGroup = var.resource_group_name
    AppInsights_Name          = var.apim_app_insights_name
  }
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# RG-scope EventHub Data Owner + Monitoring Reader for the Logic App SAMI.
# Matches `bicep/infra/modules/logicapp/logicapp.bicep` (scope = resourceGroup()).
resource "azurerm_role_assignment" "logic_eh_owner" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Azure Event Hubs Data Owner"
  principal_id         = azurerm_logic_app_standard.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "logic_monitoring_reader" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_logic_app_standard.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

output "logic_app_name" { value = azurerm_logic_app_standard.this.name }
output "logic_app_id" { value = azurerm_logic_app_standard.this.id }
output "logic_app_principal_id" { value = azurerm_logic_app_standard.this.identity[0].principal_id }
output "storage_account_name" { value = azurerm_storage_account.this.name }
