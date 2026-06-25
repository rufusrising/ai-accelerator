# --------------------------------------------------------------------
# APIM AI APIs submodule.
#
# Provisioned APIs (subject to feature flags):
#
#   1. azure-openai-api        (path "/openai") — inference-api Azure OpenAI shape
#   2. universal-llm-api       (path "/models") — OpenAI v1 shape
#   3. unified-ai-api          (path "/unified-ai") — wildcard
#   4. azure-ai-search-index-api (path "/search") — Index APIs only
#   5. document-intelligence-api + legacy
#   6. openai-realtime-ws-api  — WebSocket
#   7. weather-api + weather-mcp + microsoftLearnMCPServer  (MCP samples)
#
# LLM backends + multi-backend pools are created here so the resource
# dependency on named values (per-backend api-key NV) is explicit.
# Per the design decision API-key auth is used for APIM->Foundry, named
# values reference KV secret URIs (`auth_secret_kv_id`).
# --------------------------------------------------------------------

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "Azure/azapi" }
  }
}

variable "apim_id" { type = string }
variable "apim_name" { type = string }
variable "apim_resource_group_name" { type = string }
variable "apim_logger_id" { type = string }
variable "app_insights_logger_id" { type = string }
variable "policies_dir" { type = string }

variable "enable_entra_auth" { type = bool }
variable "enable_unified_ai_api" { type = bool }
variable "enable_ai_model_inference" { type = bool }
variable "enable_document_intelligence" { type = bool }
variable "enable_azure_ai_search" { type = bool }
variable "enable_openai_realtime" { type = bool }
variable "enable_mcp_samples" { type = bool }
variable "enable_embeddings_backend" { type = bool }
variable "uami_client_id" { type = string }
variable "foundry_api_key_named_value" { type = string }

variable "llm_backends" {
  type = list(object({
    backend_id        = string
    backend_type      = string
    endpoint          = string
    auth_type         = string
    auth_secret_kv_id = optional(string, "")
    auth_secret_value = optional(string, "")
    named_value_key   = optional(string, "")
    priority          = number
    weight            = number
    supported_models = list(object({
      name                  = string
      sku                   = optional(string, "Standard")
      capacity              = optional(number, 100)
      model_format          = optional(string, "OpenAI")
      model_version         = optional(string, "1")
      retirement_date       = optional(string, "")
      api_version           = optional(string, "")
      timeout               = optional(number, 120)
      inference_api_version = optional(string, "")
    }))
  }))
}

variable "llm_backend_pools" {
  type = list(object({
    pool_name    = string
    model_name   = string
    backend_type = string
    backends     = list(any)
  }))
}

variable "llm_backend_named_values" {
  type = map(object({
    secret_uri = optional(string, "")
    secret_val = optional(string, "")
  }))
}

variable "ai_search_instances" {
  type = list(object({
    name        = string
    url         = string
    description = optional(string, "")
  }))
  default = []
}

variable "primary_foundry_endpoint" { type = string }
variable "embeddings_backend_url" { type = string }

# ============================================================
# Per-backend API key named values (KV-backed when secret_uri set)
# ============================================================

resource "azurerm_api_management_named_value" "backend_api_keys" {
  for_each            = var.llm_backend_named_values
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  name                = each.key
  display_name        = each.key
  secret              = true

  dynamic "value_from_key_vault" {
    for_each = each.value.secret_uri == "" ? [] : [1]
    content {
      secret_id          = each.value.secret_uri
      identity_client_id = var.uami_client_id
    }
  }

  value = each.value.secret_uri == "" ? coalesce(each.value.secret_val, "NOT_CONFIGURED") : null
}

# ============================================================
# LLM backends (api-key-header, api-key-bearer, etc.)
# ============================================================

locals {
  backend_credentials_by_id = {
    for cfg in var.llm_backends : cfg.backend_id => jsondecode(
      cfg.auth_type == "managed-identity" ? jsonencode({
        managedIdentity = {
          clientId = var.uami_client_id
          resource = "https://cognitiveservices.azure.com"
        }
        header = {
          "x-ms-client-id" = [var.uami_client_id]
        }
      }) :
      cfg.auth_type == "api-key-bearer" ? jsonencode({
        header = {
          "Authorization" = ["{{${coalesce(cfg.named_value_key, "${cfg.backend_id}-key")}}}"]
        }
      }) :
      cfg.auth_type == "api-key-header" ? jsonencode({
        header = {
          "api-key" = ["{{${coalesce(cfg.named_value_key, "${cfg.backend_id}-key")}}}"]
        }
      }) :
      cfg.auth_type == "api-key-gemini" ? jsonencode({
        header = {
          "x-goog-api-key" = ["{{${coalesce(cfg.named_value_key, "${cfg.backend_id}-key")}}}"]
        }
      }) :
      cfg.auth_type == "api-key-anthropic" ? jsonencode({
        header = {
          "x-api-key"         = ["{{${coalesce(cfg.named_value_key, "${cfg.backend_id}-key")}}}"]
          "anthropic-version" = ["{{anthropic-version}}"]
        }
      }) :
      jsonencode({})
    )
  }
}

resource "azapi_resource" "llm_backend" {
  for_each  = { for cfg in var.llm_backends : cfg.backend_id => cfg }
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  parent_id = var.apim_id
  name      = each.value.backend_id

  body = {
    properties = {
      description = "LLM Backend: ${each.value.backend_type} - ${each.value.backend_id} - Supports: ${join(", ", [for m in each.value.supported_models : m.name])}"
      url         = each.value.endpoint
      protocol    = "http"
      credentials = local.backend_credentials_by_id[each.value.backend_id]
      circuitBreaker = {
        rules = [
          {
            name             = "${each.value.backend_id}-breaker-rule"
            tripDuration     = "PT1M"
            acceptRetryAfter = true
            failureCondition = {
              count        = 3
              interval     = "PT5M"
              errorReasons = ["Server errors"]
              statusCodeRanges = [
                { min = 429, max = 429 },
                { min = 500, max = 503 },
              ]
            }
          }
        ]
      }
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
    }
  }

  depends_on = [
    azurerm_api_management_named_value.backend_api_keys,
  ]

  schema_validation_enabled = false
}

# ============================================================
# Multi-backend pools (one APIM backend per pool with type=Pool)
# ============================================================

resource "azapi_resource" "llm_backend_pool" {
  for_each  = { for p in var.llm_backend_pools : p.pool_name => p }
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  parent_id = var.apim_id
  name      = each.value.pool_name

  body = {
    properties = {
      description = "Backend pool for model: ${each.value.model_name}"
      type        = "Pool"
      pool = {
        services = [for b in each.value.backends : {
          id       = "/backends/${b.backend_id}"
          priority = b.priority
          weight   = b.weight
        }]
      }
    }
  }

  depends_on = [
    azapi_resource.llm_backend,
  ]

  schema_validation_enabled = false
}

# ============================================================
# Inference-style AI APIs (Azure OpenAI + Universal LLM)
# ============================================================

locals {
  # Source-of-truth API specs (copied from accelerator).
  spec_azure_openai = file("${path.module}/../../api-specs/AIFoundryOpenAI.json")
  spec_universal    = file("${path.module}/../../api-specs/AIFoundryOpenAIV1.json")
  spec_wildcard     = file("${path.module}/../../api-specs/UnifiedAIWildcard.json")
  spec_ai_search    = file("${path.module}/../../api-specs/ai-search-index-2024-07-01-api-spec.json")
  spec_doc_intel    = file("${path.module}/../../api-specs/document-intelligence-2024-11-30-compressed.openapi.yaml")
  spec_weather      = file("${path.module}/../../api-specs/weather-openapi.json")

  policy_aoai                  = file("${var.policies_dir}/azure-open-ai-api-policy.xml")
  policy_universal             = file("${var.policies_dir}/universal-llm-api-policy-v2.xml")
  policy_unified               = file("${var.policies_dir}/unified-ai-api-policy.xml")
  policy_unified_prod          = file("${var.policies_dir}/unified-ai-product-subscription.xml")
  policy_ai_search_idx         = file("${var.policies_dir}/ai-search-index-api-policy.xml")
  policy_doc_intel             = file("${var.policies_dir}/doc-intelligence-api-policy.xml")
  policy_realtime              = file("${var.policies_dir}/openai-realtime-policy.xml")
  policy_weather               = file("${var.policies_dir}/sample-weather-policy.xml")
  policy_unified_deps          = file("${var.policies_dir}/unified-ai-api-deployments-policy.xml")
  policy_unified_dep_by_name   = file("${var.policies_dir}/unified-ai-api-deployment-by-name-policy.xml")
  policy_universal_deps        = file("${var.policies_dir}/universal-llm-api-deployments-policy.xml")
  policy_universal_dep_by_name = file("${var.policies_dir}/universal-llm-api-deployment-by-name-policy.xml")
}

resource "azurerm_api_management_api" "azure_openai" {
  name                  = "azure-openai-api"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Azure OpenAI API"
  description           = "Azure OpenAI API to route requests to different LLM providers."
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = !var.enable_entra_auth

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  import {
    content_format = "openapi+json"
    content_value  = local.spec_azure_openai
  }
}

resource "azurerm_api_management_api_policy" "azure_openai" {
  api_name            = azurerm_api_management_api.azure_openai.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_aoai
}

resource "azurerm_api_management_api" "universal_llm" {
  name                  = "universal-llm-api"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Universal LLM API"
  description           = "Universal LLM API to route requests to different LLM providers."
  path                  = "models"
  protocols             = ["https"]
  subscription_required = !var.enable_entra_auth

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  import {
    content_format = "openapi+json"
    content_value  = local.spec_universal
  }
}

resource "azurerm_api_management_api_policy" "universal_llm" {
  api_name            = azurerm_api_management_api.universal_llm.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_universal
}

# ============================================================
# Unified AI Wildcard API
# ============================================================

resource "azapi_resource" "unified_ai" {
  count     = var.enable_unified_ai_api ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-06-01-preview"
  parent_id = var.apim_id
  name      = "unified-ai-api"

  body = {
    properties = {
      apiType     = "http"
      description = "Unified AI Gateway API - wildcard routing across providers."
      displayName = "Unified AI API"
      format      = "openapi+json"
      path        = "unified-ai"
      protocols   = ["https"]
      subscriptionKeyParameterNames = {
        header = "api-key"
        query  = "api-key"
      }
      subscriptionRequired = true
      type                 = "http"
      value                = local.spec_wildcard
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "unified_ai_policy" {
  count     = var.enable_unified_ai_api ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview"
  parent_id = azapi_resource.unified_ai[0].id
  name      = "policy"

  body = {
    properties = {
      format = "rawxml"
      value  = local.policy_unified
    }
  }
}

# Unified AI product (subscription-based).
resource "azurerm_api_management_product" "unified_ai" {
  count                 = var.enable_unified_ai_api ? 1 : 0
  product_id            = "unified-ai-product"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  display_name          = "Unified AI Gateway"
  description           = "Unified AI Gateway product."
  subscription_required = true
  approval_required     = false
  subscriptions_limit   = 10
  published             = true
}

resource "azurerm_api_management_product_policy" "unified_ai" {
  count               = var.enable_unified_ai_api ? 1 : 0
  product_id          = azurerm_api_management_product.unified_ai[0].product_id
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_unified_prod
}

resource "azurerm_api_management_product_api" "unified_ai" {
  count               = var.enable_unified_ai_api ? 1 : 0
  product_id          = azurerm_api_management_product.unified_ai[0].product_id
  api_name            = "unified-ai-api"
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name

  depends_on = [azapi_resource.unified_ai]
}

# Per-operation policies on /deployments + /deployment-by-name for the 3 LLM APIs.
resource "azapi_resource" "unified_deployments_op_policy" {
  count     = var.enable_unified_ai_api ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azapi_resource.unified_ai[0].id}/operations/deployments"
  name      = "policy"
  body = {
    properties = {
      format = "rawxml"
      value  = local.policy_unified_deps
    }
  }
}

resource "azapi_resource" "unified_deployment_by_name_op_policy" {
  count     = var.enable_unified_ai_api ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azapi_resource.unified_ai[0].id}/operations/deployment-by-name"
  name      = "policy"
  body = {
    properties = {
      format = "rawxml"
      value  = local.policy_unified_dep_by_name
    }
  }
}

# Universal LLM + Azure OpenAI per-operation policies (Foundry integration).
resource "azapi_resource" "universal_deployments_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.universal_llm.id}/operations/deployments"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_deps }
  }
}

resource "azapi_resource" "universal_deployment_by_name_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.universal_llm.id}/operations/deployment-by-name"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_dep_by_name }
  }
}

resource "azapi_resource" "universal_listmodels_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.universal_llm.id}/operations/listModels"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_deps }
  }
}

resource "azapi_resource" "universal_retrievemodel_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.universal_llm.id}/operations/retrieveModel"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_dep_by_name }
  }
}

resource "azapi_resource" "aoai_deployments_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.azure_openai.id}/operations/deployments"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_deps }
  }
}

resource "azapi_resource" "aoai_deployment_by_name_op_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azurerm_api_management_api.azure_openai.id}/operations/deployment-by-name"
  name      = "policy"
  body = {
    properties = { format = "rawxml", value = local.policy_universal_dep_by_name }
  }
}

# ============================================================
# AI Search Index API + per-instance backends
# ============================================================

resource "azurerm_api_management_api" "ai_search_index" {
  count                 = var.enable_azure_ai_search ? 1 : 0
  name                  = "azure-ai-search-index-api"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Azure AI Search Index API (index services)"
  description           = "Azure AI Search Index Client APIs"
  path                  = "search"
  protocols             = ["https"]
  subscription_required = !var.enable_entra_auth

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  import {
    content_format = "openapi+json"
    content_value  = local.spec_ai_search
  }
}

resource "azurerm_api_management_api_policy" "ai_search_index" {
  count               = var.enable_azure_ai_search ? 1 : 0
  api_name            = azurerm_api_management_api.ai_search_index[0].name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_ai_search_idx
}

resource "azurerm_api_management_backend" "ai_search" {
  for_each            = { for i in var.ai_search_instances : i.name => i }
  name                = each.value.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  protocol            = "http"
  url                 = each.value.url
  description         = coalesce(each.value.description, "AI Search backend")

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# ============================================================
# Document Intelligence (modern + legacy paths)
# ============================================================

resource "azurerm_api_management_api" "doc_intel" {
  count                 = var.enable_document_intelligence ? 1 : 0
  name                  = "document-intelligence-api"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Document Intelligence API"
  description           = "Uses (/documentintelligence) URL path. Extracts content from documents."
  path                  = "documentintelligence"
  protocols             = ["https"]
  subscription_required = !var.enable_entra_auth

  import {
    content_format = "openapi"
    content_value  = local.spec_doc_intel
  }
}

resource "azurerm_api_management_api_policy" "doc_intel" {
  count               = var.enable_document_intelligence ? 1 : 0
  api_name            = azurerm_api_management_api.doc_intel[0].name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_doc_intel
}

resource "azurerm_api_management_api" "doc_intel_legacy" {
  count                 = var.enable_document_intelligence ? 1 : 0
  name                  = "document-intelligence-api-legacy"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Document Intelligence API (Legacy)"
  description           = "Uses (/formrecognizer) URL path."
  path                  = "formrecognizer"
  protocols             = ["https"]
  subscription_required = !var.enable_entra_auth

  import {
    content_format = "openapi"
    content_value  = local.spec_doc_intel
  }
}

resource "azurerm_api_management_api_policy" "doc_intel_legacy" {
  count               = var.enable_document_intelligence ? 1 : 0
  api_name            = azurerm_api_management_api.doc_intel_legacy[0].name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_doc_intel
}

# ============================================================
# OpenAI Realtime (WebSocket)
# ============================================================

resource "azapi_resource" "realtime_api" {
  count     = var.enable_openai_realtime ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-06-01-preview"
  parent_id = var.apim_id
  name      = "openai-realtime-ws-api"

  body = {
    properties = {
      apiType              = "websocket"
      displayName          = "Azure OpenAI Realtime API"
      description          = "Access Azure OpenAI Realtime API for real-time voice and text conversion."
      path                 = "openai/realtime"
      type                 = "websocket"
      protocols            = ["wss"]
      serviceUrl           = "wss://to-be-replaced-by-policy"
      subscriptionRequired = !var.enable_entra_auth
      subscriptionKeyParameterNames = {
        header = "api-key"
        query  = "api-key"
      }
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "realtime_api_handshake_policy" {
  count     = var.enable_openai_realtime ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview"
  parent_id = "${azapi_resource.realtime_api[0].id}/operations/onHandshake"
  name      = "policy"

  body = {
    properties = {
      format = "rawxml"
      value  = local.policy_realtime
    }
  }
}

# ============================================================
# MCP samples
# ============================================================

resource "azurerm_api_management_api" "weather" {
  count                 = var.enable_mcp_samples ? 1 : 0
  name                  = "weather-api"
  resource_group_name   = var.apim_resource_group_name
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = "Weather API"
  description           = "Weather API for getting dynamic weather information."
  path                  = "weather"
  protocols             = ["https"]
  subscription_required = false

  import {
    content_format = "openapi+json"
    content_value  = local.spec_weather
  }
}

resource "azurerm_api_management_api_policy" "weather" {
  count               = var.enable_mcp_samples ? 1 : 0
  api_name            = azurerm_api_management_api.weather[0].name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = local.policy_weather
}

# MCP sample: weather-mcp exposed via mcp-from-api flow.
resource "azapi_resource" "weather_mcp" {
  count     = var.enable_mcp_samples ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-06-01-preview"
  parent_id = var.apim_id
  name      = "weather-mcp"

  body = {
    properties = {
      type                 = "mcp"
      displayName          = "Weather MCP Development"
      description          = "MCP server for weather data operations (Development)"
      path                 = "weather-mcp"
      protocols            = ["https"]
      subscriptionRequired = false
      mcpPropperties = {
        transportType = "streamable"
      }
    }
  }

  schema_validation_enabled = false

  depends_on = [azurerm_api_management_api.weather]
}

# Microsoft Learn MCP — existing remote server registered as backend + MCP API
resource "azurerm_api_management_backend" "ms_learn_mcp" {
  count               = var.enable_mcp_samples ? 1 : 0
  name                = "ms-learn-mcp-server"
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  protocol            = "http"
  url                 = "https://learn.microsoft.com/api/mcp"
  description         = "Microsoft Learn MCP Server"
}

resource "azapi_resource" "ms_learn_mcp_api" {
  count     = var.enable_mcp_samples ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-06-01-preview"
  parent_id = var.apim_id
  name      = "ms-learn-mcp"

  body = {
    properties = {
      type                 = "mcp"
      displayName          = "Microsoft Learn MCP"
      description          = "Microsoft Learn MCP Server"
      path                 = "ms-learn-mcp"
      protocols            = ["https"]
      subscriptionRequired = false
      backendId            = "ms-learn-mcp-server"
      mcpPropperties = {
        transportType = "streamable"
      }
    }
  }

  schema_validation_enabled = false

  depends_on = [azurerm_api_management_backend.ms_learn_mcp]
}

output "apis" {
  value = {
    azure_openai          = azurerm_api_management_api.azure_openai.name
    universal_llm         = azurerm_api_management_api.universal_llm.name
    unified_ai            = try(azapi_resource.unified_ai[0].name, "")
    ai_search_index       = try(azurerm_api_management_api.ai_search_index[0].name, "")
    document_intelligence = try(azurerm_api_management_api.doc_intel[0].name, "")
    document_intel_legacy = try(azurerm_api_management_api.doc_intel_legacy[0].name, "")
    realtime              = try(azapi_resource.realtime_api[0].name, "")
    weather               = try(azurerm_api_management_api.weather[0].name, "")
    weather_mcp           = try(azapi_resource.weather_mcp[0].name, "")
    ms_learn_mcp          = try(azapi_resource.ms_learn_mcp_api[0].name, "")
  }
}

output "llm_backend_ids" {
  value = [for b in azapi_resource.llm_backend : b.name]
}

output "llm_backend_pool_names" {
  value = [for p in azapi_resource.llm_backend_pool : p.name]
}
