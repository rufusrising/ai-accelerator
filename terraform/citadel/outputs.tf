output "apim_name"        { value = module.apim_core.name }
output "apim_id"          { value = module.apim_core.id }
output "apim_gateway_url" { value = module.apim_core.gateway_url }

output "apim_uami_id"        { value = azurerm_user_assigned_identity.apim.id }
output "apim_uami_client_id" { value = azurerm_user_assigned_identity.apim.client_id }

output "key_vault_id"  { value = module.key_vault.id }
output "key_vault_uri" { value = module.key_vault.uri }

output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "vnet_id"             { value = module.networking.vnet_id }
output "apim_subnet_id"      { value = module.networking.apim_subnet_id }
output "agent_subnet_id"     { value = module.networking.agent_subnet_id }
output "private_dns_zone_ids" { value = module.networking.private_dns_zone_ids }

output "foundry_accounts" {
  value = module.foundry.foundry_account_names
}

output "foundry_endpoints" {
  value = module.foundry.foundry_endpoints
}

output "foundry_projects" {
  value = module.foundry.project_names
}

output "cosmos_db_account_name" {
  value = try(module.cosmos_db[0].account_name, null)
}

output "event_hub_namespace_name" {
  value = try(module.event_hub[0].namespace_name, null)
}

output "redis_hostname" {
  value = try(module.redis[0].hostname, null)
}

output "llm_backends" {
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
  value = [for p in local.llm_backend_pools : p.pool_name]
}

output "access_contract_products" {
  value = flatten([
    for m in module.access_contracts : m.product_ids
  ])
}
