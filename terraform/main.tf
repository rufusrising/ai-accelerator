# --------------------------------------------------------------------
# Root composition for the AI Hub Gateway Terraform module.
#
# Layering (top-down):
#   1. Identities + KV + Monitoring + EventHub + Cosmos + Redis + Storage
#   2. Foundry attach (model deployments + RBAC + Foundry-side connections)
#   3. APIM core service + diagnostics + logger + named values
#   4. APIM policy fragments + AI APIs
#   5. Access contracts (products + subscriptions) + APIC + Logic App processor
# --------------------------------------------------------------------

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# ============================================================
# Managed identities
# ============================================================

resource "azurerm_user_assigned_identity" "apim" {
  name                = local.names.apim_identity
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.effective_tags
}

resource "azurerm_user_assigned_identity" "logic_app" {
  count = local.features.enable_usage_pipeline == true ? 1 : 0

  name                = local.names.logic_app_identity
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.effective_tags
}

# Subscription-scope role assignments mirror `managed-identity-apim.bicep`.
# - Cognitive Services User: required for backend MI when bypassing APIM-side keys
# - Cognitive Services OpenAI User: same, for AzureOpenAI-scoped tokens
# - Event Hubs Data Sender: required by APIM ehUsageLogger
resource "azurerm_role_assignment" "apim_cog_user" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_user_assigned_identity.apim.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_cog_openai_user" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.apim.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_eh_sender" {
  scope                = data.azurerm_resource_group.rg.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_user_assigned_identity.apim.principal_id
  principal_type       = "ServicePrincipal"
}

# ============================================================
# Monitoring (Log Analytics + App Insights)
# ============================================================

module "monitoring" {
  source = "./modules/monitoring"

  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = coalesce(var.monitoring_location, var.location)
  tags                       = local.effective_tags
  log_analytics_name         = local.names.log_analytics
  apim_app_insights_name     = local.names.apim_appinsights
  func_app_insights_name     = local.names.func_appinsights
  foundry_app_insights_name  = local.names.foundry_appinsights
  use_existing_log_analytics = var.use_existing_log_analytics
  existing_log_analytics     = var.existing_log_analytics
}

# ============================================================
# Key Vault (RBAC-mode, private endpoint)
# ============================================================

module "key_vault" {
  source = "./modules/keyvault"

  name                       = local.names.key_vault
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = coalesce(var.key_vault_location, var.location)
  private_endpoint_location  = var.network.vnet_location
  create_dns_a_records       = var.create_dns_a_records
  tags                       = local.effective_tags
  tenant_id                  = coalesce(var.entra_tenant_id, data.azurerm_client_config.current.tenant_id)
  private_endpoint_subnet_id = var.network.private_endpoint_subnet_id
  private_endpoint_name      = local.names.kv_pe
  dns_zone_id                = var.private_dns_zone_ids.key_vault
  apim_uami_principal_id     = azurerm_user_assigned_identity.apim.principal_id
}

# ============================================================
# Event Hub (usage + pii streams)
# ============================================================

module "event_hub" {
  count  = local.features.enable_usage_pipeline == true ? 1 : 0
  source = "./modules/eventhub"

  name                       = local.names.event_hub_namespace
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = coalesce(var.event_hub_location, var.location)
  private_endpoint_location  = var.network.vnet_location
  create_dns_a_records       = var.create_dns_a_records
  tags                       = local.effective_tags
  sku                        = var.event_hub.sku
  capacity                   = var.event_hub.capacity
  auto_inflate_enabled       = var.event_hub.auto_inflate_enabled
  maximum_throughput_units   = var.event_hub.maximum_throughput_units
  message_retention_days     = var.event_hub.message_retention_days
  public_network_access      = var.event_hub.public_network_access
  enable_pii_hub             = local.features.enable_pii_redaction
  private_endpoint_subnet_id = var.network.private_endpoint_subnet_id
  private_endpoint_name      = local.names.eh_pe
  dns_zone_id                = var.private_dns_zone_ids.event_hub
}

# ============================================================
# Cosmos DB (usage store)
# ============================================================

module "cosmos_db" {
  count  = local.features.enable_usage_pipeline == true ? 1 : 0
  source = "./modules/cosmosdb"

  account_name               = local.names.cosmos_db
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = coalesce(var.cosmos_location, var.location)
  private_endpoint_location  = var.network.vnet_location
  create_dns_a_records       = var.create_dns_a_records
  tags                       = local.effective_tags
  throughput                 = var.cosmos_db_throughput
  private_endpoint_subnet_id = var.network.private_endpoint_subnet_id
  private_endpoint_name      = local.names.cosmos_pe
  dns_zone_id                = var.private_dns_zone_ids.cosmos_db
}

# Grant the Logic App UAMI Cosmos DB Built-in Data Contributor (native, data-plane).
# Split out so the principal has time to replicate in AAD — matches Bicep ordering.
resource "azapi_resource" "cosmos_sql_role_logic_app" {
  count     = local.features.enable_usage_pipeline == true ? 1 : 0
  type      = "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-02-15-preview"
  parent_id = module.cosmos_db[0].account_id
  name      = uuidv5("oid", "${module.cosmos_db[0].account_id}|${azurerm_user_assigned_identity.logic_app[0].principal_id}|00000000-0000-0000-0000-000000000002")

  body = {
    properties = {
      principalId      = azurerm_user_assigned_identity.logic_app[0].principal_id
      roleDefinitionId = "${module.cosmos_db[0].account_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
      scope            = module.cosmos_db[0].account_id
    }
  }

  depends_on = [
    azurerm_user_assigned_identity.logic_app,
    module.cosmos_db
  ]
}

# ============================================================
# Azure Managed Redis (semantic cache)
# ============================================================

module "redis" {
  count  = local.features.enable_managed_redis == true ? 1 : 0
  source = "./modules/redis"

  name                       = local.names.redis
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = coalesce(var.redis_location, var.location)
  private_endpoint_location  = var.network.vnet_location
  create_dns_a_records       = var.create_dns_a_records
  tags                       = local.effective_tags
  sku_name                   = var.redis.sku_name
  sku_capacity               = var.redis.sku_capacity
  minimum_tls_version        = var.redis.minimum_tls_version
  private_endpoint_subnet_id = var.network.private_endpoint_subnet_id
  private_endpoint_name      = local.names.redis_pe
  dns_zone_id                = var.private_dns_zone_ids.redis_enterprise
}

# ============================================================
# Foundry attach — model deployments + RBAC + API-key secret wiring
# ============================================================

module "foundry_integration" {
  source = "./modules/foundry_integration"

  foundry                  = var.foundry
  model_deployments        = var.foundry_model_deployments
  apim_uami_principal_id   = azurerm_user_assigned_identity.apim.principal_id
  primary_foundry_endpoint = local.primary_foundry_endpoint
}

# ============================================================
# Storage + Logic App usage processor
# ============================================================

module "logic_app_usage" {
  count  = local.features.enable_usage_pipeline == true ? 1 : 0
  source = "./modules/logicapp_usage"

  storage_account_name           = local.names.storage_account
  logic_app_name                 = local.names.logic_app
  resource_group_name            = data.azurerm_resource_group.rg.name
  # Logic App needs to be in the SAME region as its function_app_subnet
  # because the runtime VNet integration NIC must be co-located with the
  # delegated subnet. Storage account is co-located too. Only the PE
  # location can diverge (but in practice always equals the VNet region).
  location                       = coalesce(var.logic_app_location, var.storage_location, var.network.vnet_location)
  private_endpoint_location      = var.network.vnet_location
  create_dns_a_records           = var.create_dns_a_records
  tags                           = local.effective_tags
  uami_id                        = azurerm_user_assigned_identity.logic_app[0].id
  uami_principal_id              = azurerm_user_assigned_identity.logic_app[0].principal_id
  function_app_subnet_id         = var.network.function_app_subnet_id
  private_endpoint_subnet_id     = var.network.private_endpoint_subnet_id
  storage_blob_dns_zone_id       = var.private_dns_zone_ids.storage_blob
  storage_file_dns_zone_id       = var.private_dns_zone_ids.storage_file
  storage_table_dns_zone_id      = var.private_dns_zone_ids.storage_table
  storage_queue_dns_zone_id      = var.private_dns_zone_ids.storage_queue
  storage_blob_pe_name           = local.names.storage_blob_pe
  storage_file_pe_name           = local.names.storage_file_pe
  storage_table_pe_name          = local.names.storage_table_pe
  storage_queue_pe_name          = local.names.storage_queue_pe
  sku_capacity                   = var.logic_app_sku_capacity
  app_insights_connection_string = module.monitoring.func_app_insights_connection_string
  app_insights_name              = module.monitoring.func_app_insights_name
  apim_app_insights_name         = module.monitoring.apim_app_insights_name
  event_hub_namespace_name       = module.event_hub[0].namespace_name
  event_hub_name                 = module.event_hub[0].usage_hub_name
  event_hub_pii_name             = module.event_hub[0].pii_hub_name
  cosmos_db_account_name         = module.cosmos_db[0].account_name
  cosmos_db_database_name        = module.cosmos_db[0].database_name
  cosmos_db_container_config     = module.cosmos_db[0].streaming_export_config_container
  cosmos_db_container_usage      = module.cosmos_db[0].usage_container
  cosmos_db_container_pii        = module.cosmos_db[0].pii_container
  cosmos_db_container_llm_usage  = module.cosmos_db[0].llm_usage_container

  depends_on = [
    module.cosmos_db,
    module.event_hub,
    azapi_resource.cosmos_sql_role_logic_app,
  ]
}

# ============================================================
# APIM core service
# ============================================================

module "apim_core" {
  source = "./modules/apim_core"

  name                = local.names.apim
  resource_group_name = data.azurerm_resource_group.rg.name
  # APIM V2 subnet integration requires APIM to be in the SAME region as the
  # apim subnet. Force the APIM location to the VNet's region — overriding
  # var.location if it differs — so misconfiguration is impossible.
  location                  = var.network.vnet_location
  private_endpoint_location = var.network.vnet_location
  create_dns_a_records      = var.create_dns_a_records
  tags                      = local.effective_tags
  sku_name                       = var.apim.sku_name
  sku_capacity                   = var.apim.sku_capacity
  publisher_name                 = var.apim.publisher_name
  publisher_email                = var.apim.publisher_email
  zones                          = var.apim.zones
  apim_subnet_id                 = var.network.apim_subnet_id
  private_endpoint_subnet_id     = var.network.private_endpoint_subnet_id
  use_private_endpoint           = var.apim.use_private_endpoint
  public_network_access_enabled  = var.apim.public_network_access
  pe_name                        = local.names.apim_pe
  dns_zone_id                    = var.private_dns_zone_ids.apim_gateway
  uami_id                        = azurerm_user_assigned_identity.apim.id
  uami_client_id                 = azurerm_user_assigned_identity.apim.client_id
  uami_principal_id              = azurerm_user_assigned_identity.apim.principal_id
  app_insights_id                = module.monitoring.apim_app_insights_id
  app_insights_workspace_id      = module.monitoring.log_analytics_workspace_id
  app_insights_connection_string = module.monitoring.apim_app_insights_connection_string
  key_vault_id                   = module.key_vault.id
  key_vault_uri                  = module.key_vault.uri
  primary_foundry_endpoint       = local.primary_foundry_endpoint
  entra_client_id                = var.entra_client_id
  entra_tenant_id                = coalesce(var.entra_tenant_id, data.azurerm_client_config.current.tenant_id)
  entra_audience                 = var.entra_audience
  enable_entra_auth              = local.features.enable_entra_auth
  enable_jwt_auth                = local.features.enable_jwt_auth
  enable_pii_redaction           = local.features.enable_pii_redaction
  enable_redis_cache             = local.features.enable_managed_redis
  redis_connection_string        = local.features.enable_managed_redis ? module.redis[0].connection_string : ""
  redis_cache_entity_name        = var.apim_redis_cache_name
  enable_embeddings_backend      = local.features.enable_managed_redis
  embeddings_backend_url         = local.primary_foundry_embeddings_url
  enable_event_hub_loggers       = local.features.enable_usage_pipeline
  event_hub_endpoint             = local.features.enable_usage_pipeline ? module.event_hub[0].endpoint : ""
  event_hub_name                 = local.features.enable_usage_pipeline ? module.event_hub[0].usage_hub_name : ""
  event_hub_pii_name             = local.features.enable_usage_pipeline ? module.event_hub[0].pii_hub_name : ""

  depends_on = [
    module.key_vault,
    module.monitoring,
  ]
}

# APIM system-assigned identity needs KV Secrets/Certificate User AFTER APIM exists.
resource "azurerm_role_assignment" "apim_system_kv_secrets_user" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.apim_core.system_assigned_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_system_kv_certificate_user" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = module.apim_core.system_assigned_principal_id
  principal_type       = "ServicePrincipal"
}

# ============================================================
# APIM policy fragments (all 50+ fragments + Foundry-aware
# substitutions for set-backend-pools / get-available-models / metadata-config)
# ============================================================

module "apim_policies" {
  source = "./modules/apim_policies"

  apim_id                  = module.apim_core.id
  apim_name                = module.apim_core.name
  apim_resource_group_name = data.azurerm_resource_group.rg.name
  enable_pii_redaction     = local.features.enable_pii_redaction
  enable_unified_ai_api    = local.features.enable_unified_ai_api
  uami_client_id           = azurerm_user_assigned_identity.apim.client_id
  llm_backends             = local.effective_llm_backends
  llm_backend_pools        = local.llm_backend_pools

  depends_on = [
    module.apim_core,
  ]
}

# ============================================================
# APIM AI APIs (Azure OpenAI / Universal LLM / Unified AI / AI Search /
# Document Intelligence / Realtime / MCP samples) and LLM backends/pools
# ============================================================

module "apim_apis" {
  source = "./modules/apim_apis"

  apim_id                      = module.apim_core.id
  apim_name                    = module.apim_core.name
  apim_resource_group_name     = data.azurerm_resource_group.rg.name
  apim_logger_id               = module.apim_core.azuremonitor_logger_id
  app_insights_logger_id       = module.apim_core.app_insights_logger_id
  policies_dir                 = "${path.module}/policies"
  enable_entra_auth            = local.features.enable_entra_auth
  enable_unified_ai_api        = local.features.enable_unified_ai_api
  enable_ai_model_inference    = local.features.enable_ai_model_inference
  enable_document_intelligence = local.features.enable_document_intelligence
  enable_azure_ai_search       = local.features.enable_azure_ai_search
  enable_openai_realtime       = local.features.enable_openai_realtime
  enable_mcp_samples           = local.features.enable_mcp_samples
  uami_client_id               = azurerm_user_assigned_identity.apim.client_id
  foundry_api_key_named_value  = "foundry-api-key"
  llm_backends                 = local.effective_llm_backends
  llm_backend_pools            = local.llm_backend_pools
  llm_backend_named_values     = local.llm_backend_named_values
  ai_search_instances          = var.ai_search_instances
  primary_foundry_endpoint     = local.primary_foundry_endpoint
  embeddings_backend_url       = local.primary_foundry_embeddings_url
  enable_embeddings_backend    = local.features.enable_managed_redis

  depends_on = [
    module.apim_policies,
  ]
}

# ============================================================
# API Center (optional)
# ============================================================

module "apic" {
  count  = local.features.enable_api_center == true ? 1 : 0
  source = "./modules/apic"

  name                = local.names.api_center
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = coalesce(var.apic.location, var.location)
  sku                 = var.apic.sku
  tags                = local.effective_tags
}

# ============================================================
# Per-tenant Access Contracts (products + subscriptions + KV secrets +
# optional Foundry connections)
# ============================================================

module "access_contracts" {
  count  = length(var.access_contracts)
  source = "./modules/products"

  apim_id                  = module.apim_core.id
  apim_name                = module.apim_core.name
  apim_resource_group_name = data.azurerm_resource_group.rg.name
  apim_gateway_url         = module.apim_core.gateway_url
  use_case                 = var.access_contracts[count.index].use_case
  services                 = var.access_contracts[count.index].services
  product_terms            = try(var.access_contracts[count.index].product_terms, "")
  write_kv_secrets         = try(var.access_contracts[count.index].write_kv_secrets, true)
  key_vault_id             = module.key_vault.id
  foundry_connection       = try(var.access_contracts[count.index].foundry_connection, null)

  depends_on = [
    module.apim_apis,
  ]
}
