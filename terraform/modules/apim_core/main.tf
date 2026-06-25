# --------------------------------------------------------------------
# APIM core submodule.
#
# - APIM StandardV2/PremiumV2 (default) with SAMI + UAMI identities.
# - Private endpoint (group: Gateway) using the BYO DNS zone.
# - App Insights logger driven by a KV-backed named value (so the
#   connection string is never embedded in ARM history).
# - Azure Monitor logger.
# - Diagnostic settings -> Log Analytics ("AllLogs", "AllMetrics").
# - Core named values needed by all AI policy fragments:
#     uami-client-id, entra-auth, client-id, tenant-id, audience,
#     piiServiceUrl, piiServiceKey, contentSafetyServiceUrl,
#     JWT-* (4 values), aws-* placeholders (declared in apim_policies).
# - APIM Cache pointed at Azure Managed Redis when enabled.
# - APIM Backend for content-safety on the primary Foundry endpoint
#   (uses APIM UAMI -- this is an Azure Cognitive Services SAFETY call,
#    not a model inference call; the user requirement of api-key only
#    applies to model inference calls, the safety/PII backends remain
#    on managed identity which is the recommended pattern).
# - APIM Backend for foundry-embeddings when Redis semantic cache is on.
#
# Mirrors `bicep/infra/modules/apim/apim.bicep`.
# --------------------------------------------------------------------

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "Azure/azapi" }
  }
}

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "sku_name" {
  type    = string
  default = "StandardV2"
}

variable "sku_capacity" {
  type    = number
  default = 1
}

variable "publisher_name" { type = string }
variable "publisher_email" { type = string }
variable "zones" {
  type    = list(string)
  default = []
}

variable "apim_subnet_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "use_private_endpoint" {
  type    = bool
  default = true
}
variable "public_network_access_enabled" {
  type    = bool
  default = false
}
variable "pe_name" { type = string }
variable "dns_zone_id" { type = string }

# PE region. Defaults to var.location (which APIM itself uses); set explicitly
# when the apim subnet's VNet is in a different region from var.location. APIM V2
# subnet integration requires apim_subnet_id to be in the same region as APIM
# itself, so this should normally equal var.location — exposed for completeness.
variable "private_endpoint_location" {
  type    = string
  default = ""
}

variable "create_dns_a_records" {
  type    = bool
  default = true
}

variable "uami_id" { type = string }
variable "uami_client_id" { type = string }
variable "uami_principal_id" { type = string }

variable "app_insights_id" { type = string }
variable "app_insights_workspace_id" { type = string }
variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}

variable "key_vault_id" { type = string }
variable "key_vault_uri" { type = string }

variable "primary_foundry_endpoint" { type = string }

variable "entra_client_id" { type = string }
variable "entra_tenant_id" { type = string }
variable "entra_audience" { type = string }
variable "enable_entra_auth" {
  type    = bool
  default = true
}
variable "enable_jwt_auth" {
  type    = bool
  default = true
}
variable "enable_pii_redaction" {
  type    = bool
  default = true
}
variable "enable_redis_cache" {
  type    = bool
  default = true
}
variable "redis_connection_string" {
  type      = string
  default   = ""
  sensitive = true
}
variable "redis_cache_entity_name" {
  type    = string
  default = "redis-cache"
}
variable "enable_embeddings_backend" {
  type    = bool
  default = true
}
variable "embeddings_backend_url" {
  type    = string
  default = ""
}

variable "event_hub_endpoint" {
  type    = string
  default = ""
}
variable "enable_event_hub_loggers" {
  type    = bool
  default = false
}
variable "event_hub_name" {
  type    = string
  default = ""
}
variable "event_hub_pii_name" {
  type    = string
  default = ""
}

locals {
  is_v2_sku            = contains(["StandardV2", "PremiumV2"], var.sku_name)
  use_pe               = local.is_v2_sku && var.use_private_endpoint
  apim_min_api_version = local.is_v2_sku ? "2024-05-01" : "2021-08-01"
  effective_audience   = coalesce(var.entra_audience, "https://cognitiveservices.azure.com/.default")
  effective_client_id  = coalesce(var.entra_client_id, "not-configured")

  resolved_jwt_tenant_id = coalesce(var.entra_tenant_id, "not-configured")
  resolved_jwt_app_id    = coalesce(var.entra_client_id, "not-configured")
  jwt_issuer             = "https://login.microsoftonline.com/${local.resolved_jwt_tenant_id}/v2.0"
  jwt_openid_config_url  = "https://login.microsoftonline.com/${local.resolved_jwt_tenant_id}/v2.0/.well-known/openid-configuration"
}

# ============================================================
# APIM Service
# ============================================================

resource "azurerm_api_management" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  publisher_name                = var.publisher_name
  publisher_email               = var.publisher_email
  sku_name                      = "${var.sku_name}_${var.sku_capacity}"
  zones                         = var.zones
  min_api_version               = local.apim_min_api_version
  public_network_access_enabled = local.is_v2_sku ? var.public_network_access_enabled : true
  tags                          = var.tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [var.uami_id]
  }

  dynamic "virtual_network_configuration" {
    for_each = local.is_v2_sku ? [1] : []
    content {
      subnet_id = var.apim_subnet_id
    }
  }

  virtual_network_type = local.is_v2_sku ? "External" : "None"

  # Security hardening — disables the deprecated cipher suites the Bicep
  # module disables via customProperties.
  security {
    backend_ssl30_enabled                             = false
    backend_tls10_enabled                             = false
    backend_tls11_enabled                             = false
    frontend_ssl30_enabled                            = false
    frontend_tls10_enabled                            = false
    frontend_tls11_enabled                            = false
    tls_ecdhe_rsa_with_aes256_cbc_sha_ciphers_enabled = false
    tls_ecdhe_rsa_with_aes128_cbc_sha_ciphers_enabled = false
    tls_rsa_with_aes128_gcm_sha256_ciphers_enabled    = false
    tls_rsa_with_aes256_cbc_sha256_ciphers_enabled    = false
    tls_rsa_with_aes128_cbc_sha256_ciphers_enabled    = false
    tls_rsa_with_aes256_cbc_sha_ciphers_enabled       = false
    tls_rsa_with_aes128_cbc_sha_ciphers_enabled       = false
    triple_des_ciphers_enabled                        = false
  }
}

# ============================================================
# Private endpoint (V2 SKUs only)
# ============================================================

resource "azurerm_private_endpoint" "apim" {
  count               = local.use_pe ? 1 : 0
  name                = var.pe_name
  location            = coalesce(var.private_endpoint_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.pe_name
    private_connection_resource_id = azurerm_api_management.this.id
    is_manual_connection           = false
    subresource_names              = ["Gateway"]
  }

  dynamic "private_dns_zone_group" {
    for_each = var.create_dns_a_records ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.dns_zone_id]
    }
  }
}

output "pe_dns_configs" {
  value = try(azurerm_private_endpoint.apim[0].custom_dns_configs, [])
}

# ============================================================
# App Insights connection string in KV
# ============================================================

resource "azurerm_key_vault_secret" "apim_appi_conn" {
  name         = "apim-appinsights-connection-string"
  value        = var.app_insights_connection_string
  key_vault_id = var.key_vault_id
  content_type = "text/plain"
}

# ============================================================
# Named values (core)
# ============================================================

resource "azurerm_api_management_named_value" "uami_client_id" {
  name                = "uami-client-id"
  display_name        = "uami-client-id"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true
  value               = var.uami_client_id
}

resource "azurerm_api_management_named_value" "entra_auth" {
  name                = "entra-auth"
  display_name        = "entra-auth"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = tostring(var.enable_entra_auth)
}

resource "azurerm_api_management_named_value" "client_id" {
  name                = "client-id"
  display_name        = "client-id"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true
  value               = local.effective_client_id
}

resource "azurerm_api_management_named_value" "tenant_id" {
  name                = "tenant-id"
  display_name        = "tenant-id"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true
  value               = coalesce(var.entra_tenant_id, "common")
}

resource "azurerm_api_management_named_value" "audience" {
  name                = "audience"
  display_name        = "audience"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true
  value               = local.effective_audience
}

resource "azurerm_api_management_named_value" "pii_service_url" {
  name                = "piiServiceUrl"
  display_name        = "piiServiceUrl"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.primary_foundry_endpoint
}

resource "azurerm_api_management_named_value" "pii_service_key" {
  name                = "piiServiceKey"
  display_name        = "piiServiceKey"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true
  value               = "replace-with-language-service-key-if-needed"
}

resource "azurerm_api_management_named_value" "content_safety_service_url" {
  name                = "contentSafetyServiceUrl"
  display_name        = "contentSafetyServiceUrl"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.primary_foundry_endpoint
}

# JWT named values (always created for unconditional fragment compile).
resource "azurerm_api_management_named_value" "jwt_tenant_id" {
  name                = "JWT-TenantId"
  display_name        = "JWT-TenantId"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.enable_jwt_auth ? local.resolved_jwt_tenant_id : "not-configured"
}

resource "azurerm_api_management_named_value" "jwt_app_id" {
  name                = "JWT-AppRegistrationId"
  display_name        = "JWT-AppRegistrationId"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.enable_jwt_auth ? local.resolved_jwt_app_id : "not-configured"
}

resource "azurerm_api_management_named_value" "jwt_issuer" {
  name                = "JWT-Issuer"
  display_name        = "JWT-Issuer"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.enable_jwt_auth ? local.jwt_issuer : "not-configured"
}

resource "azurerm_api_management_named_value" "jwt_openid_config" {
  name                = "JWT-OpenIdConfigUrl"
  display_name        = "JWT-OpenIdConfigUrl"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  value               = var.enable_jwt_auth ? local.jwt_openid_config_url : "not-configured"
}

# App Insights connection string named value sourced from KV via UAMI.
resource "azurerm_api_management_named_value" "appi_logger_credentials" {
  name                = "appinsights-logger-credentials"
  display_name        = "appinsights-logger-credentials"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  secret              = true

  value_from_key_vault {
    secret_id          = "${var.key_vault_uri}secrets/${azurerm_key_vault_secret.apim_appi_conn.name}"
    identity_client_id = var.uami_client_id
  }
}

# ============================================================
# Loggers (App Insights via NV + Azure Monitor)
# ============================================================

resource "azurerm_api_management_logger" "appi" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  resource_id         = var.app_insights_id
  buffered            = false
  description         = "Application Insights logger (KV-backed)"

  application_insights {
    connection_string = "{{${azurerm_api_management_named_value.appi_logger_credentials.name}}}"
  }

  depends_on = [
    azurerm_api_management_named_value.appi_logger_credentials,
  ]
}

# Azure Monitor logger — needed for inference-api Azure Monitor diagnostics.
resource "azapi_resource" "azuremonitor_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2024-10-01-preview"
  parent_id = azurerm_api_management.this.id
  name      = "azuremonitor"

  body = {
    properties = {
      loggerType  = "azureMonitor"
      isBuffered  = false
      description = "Azure Monitor logger for Log Analytics"
    }
  }
}

# Optional Event Hub usage loggers
resource "azapi_resource" "eh_usage_logger" {
  count     = var.enable_event_hub_loggers ? 1 : 0
  type      = "Microsoft.ApiManagement/service/loggers@2022-08-01"
  parent_id = azurerm_api_management.this.id
  name      = "usage-eventhub-logger"

  body = {
    properties = {
      loggerType  = "azureEventHub"
      description = "Event Hub logger for OpenAI usage metrics"
      credentials = {
        name             = var.event_hub_name
        endpointAddress  = replace(var.event_hub_endpoint, "https://", "")
        identityClientId = var.uami_client_id
      }
    }
  }
}

resource "azapi_resource" "eh_pii_logger" {
  count     = (var.enable_event_hub_loggers && var.enable_pii_redaction) ? 1 : 0
  type      = "Microsoft.ApiManagement/service/loggers@2022-08-01"
  parent_id = azurerm_api_management.this.id
  name      = "pii-usage-eventhub-logger"

  body = {
    properties = {
      loggerType  = "azureEventHub"
      description = "Event Hub logger for PII usage metrics and logs"
      credentials = {
        name             = var.event_hub_pii_name
        endpointAddress  = replace(var.event_hub_endpoint, "https://", "")
        identityClientId = var.uami_client_id
      }
    }
  }
}

# ============================================================
# Service-scope diagnostics (App Insights + AllMetrics)
# ============================================================

resource "azurerm_api_management_diagnostic" "appi" {
  identifier               = "applicationinsights"
  resource_group_name      = var.resource_group_name
  api_management_name      = azurerm_api_management.this.name
  api_management_logger_id = azurerm_api_management_logger.appi.id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"

  frontend_request { body_bytes = 0 }
  frontend_response { body_bytes = 0 }
  backend_request { body_bytes = 0 }
  backend_response { body_bytes = 0 }
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                           = "apimDiagnosticSettings"
  target_resource_id             = azurerm_api_management.this.id
  log_analytics_workspace_id     = var.app_insights_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "AllLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ============================================================
# APIM Cache pointed at Azure Managed Redis
# ============================================================

resource "azapi_resource" "redis_cache" {
  count     = var.enable_redis_cache ? 1 : 0
  type      = "Microsoft.ApiManagement/service/caches@2024-06-01-preview"
  parent_id = azurerm_api_management.this.id
  name      = var.redis_cache_entity_name

  body = {
    properties = {
      connectionString = var.redis_connection_string
      useFromLocation  = "default"
      description      = "Azure Managed Redis cache for APIM Semantic Cache"
    }
  }

  schema_validation_enabled = false
}

# ============================================================
# Content Safety backend (Foundry primary endpoint, MI-auth)
# ============================================================

resource "azurerm_api_management_backend" "content_safety" {
  name                = "content-safety-backend"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = var.primary_foundry_endpoint
  description         = "Content Safety Service Backend"

  credentials {
    header = {
      "x-ms-client-id" = var.uami_client_id
    }
  }

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# Foundry embeddings backend for APIM semantic cache.
resource "azurerm_api_management_backend" "embeddings" {
  count               = var.enable_embeddings_backend ? 1 : 0
  name                = "foundry-embeddings"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = var.embeddings_backend_url
  description         = "AI Foundry embeddings backend (APIM semantic cache)"

  credentials {
    header = {
      "x-ms-client-id" = var.uami_client_id
    }
  }

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# ============================================================
# Outputs
# ============================================================

output "id" { value = azurerm_api_management.this.id }
output "name" { value = azurerm_api_management.this.name }
output "gateway_url" { value = azurerm_api_management.this.gateway_url }
output "system_assigned_principal_id" {
  value = azurerm_api_management.this.identity[0].principal_id
}
output "app_insights_logger_id" { value = azurerm_api_management_logger.appi.id }
output "azuremonitor_logger_id" { value = azapi_resource.azuremonitor_logger.id }
