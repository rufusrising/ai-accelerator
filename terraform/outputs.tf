output "apim_name" {
  description = "Name of the deployed API Management service."
  value       = module.apim_core.name
}

output "apim_id" {
  description = "Resource ID of the API Management service."
  value       = module.apim_core.id
}

output "apim_gateway_url" {
  description = "Public gateway URL for the APIM instance."
  value       = module.apim_core.gateway_url
}

output "apim_uami_id" {
  description = "Resource ID of the APIM user-assigned managed identity."
  value       = azurerm_user_assigned_identity.apim.id
}

output "apim_uami_client_id" {
  description = "Client ID (appId) of the APIM user-assigned managed identity."
  value       = azurerm_user_assigned_identity.apim.client_id
}

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = module.key_vault.id
}

output "key_vault_uri" {
  description = "Key Vault DNS suffix."
  value       = module.key_vault.uri
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID."
  value       = module.monitoring.log_analytics_workspace_id
}

output "cosmos_db_account_name" {
  description = "Cosmos DB account name (null if usage pipeline disabled)."
  value       = try(module.cosmos_db[0].account_name, null)
}

output "event_hub_namespace_name" {
  description = "Event Hub namespace name (null if usage pipeline disabled)."
  value       = try(module.event_hub[0].namespace_name, null)
}

output "redis_hostname" {
  description = "Azure Managed Redis hostname (null if Redis disabled)."
  value       = try(module.redis[0].hostname, null)
}

output "foundry_attached_accounts" {
  description = "Existing Foundry accounts the gateway is attached to."
  value       = [for f in var.foundry : f.account_name]
}

output "llm_backends" {
  description = "Effective LLM backend list created in APIM."
  value = [
    for b in local.effective_llm_backends : {
      backend_id   = b.backend_id
      backend_type = b.backend_type
      endpoint     = b.endpoint
      auth_type    = b.auth_type
      models       = [for m in b.supported_models : m.name]
    }
  ]
}

output "llm_backend_pools" {
  description = "APIM backend pools created to load-balance multi-backend models."
  value       = [for p in local.llm_backend_pools : p.pool_name]
}

output "access_contract_products" {
  description = "Per-tenant APIM products created from var.access_contracts."
  value = flatten([
    for m in module.access_contracts : m.product_ids
  ])
}

output "pe_dns_records" {
  description = <<-EOT
    All private endpoint DNS records (FQDN + IPs) the module created. Use this when
    var.create_dns_a_records=false to feed your central DNS-as-code pipeline. Empty
    list elements are skipped resources (e.g. usage pipeline disabled).
  EOT
  value = {
    key_vault = module.key_vault.pe_dns_configs
    apim      = module.apim_core.pe_dns_configs
    cosmos    = try(module.cosmos_db[0].pe_dns_configs, [])
    event_hub = try(module.event_hub[0].pe_dns_configs, [])
    redis     = try(module.redis[0].pe_dns_configs, [])
    storage   = try(module.logic_app_usage[0].pe_dns_configs, {})
    # attach mode references existing Foundry accounts — PE for those is BYO,
    # so no pe_dns_configs to surface here. citadel mode exposes module.foundry.pe_dns_configs.
  }
}
