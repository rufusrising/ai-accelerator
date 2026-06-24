# --------------------------------------------------------------------
# APIM policy fragments submodule.
#
# Loads all 50+ shared policy fragments from `../../policies/*.xml` and
# materializes the 4 dynamically-generated fragments that depend on the
# resolved LLM backend topology:
#
#   * set-backend-pools         - injects C# JObject pool entries
#   * get-available-models      - injects model deployment metadata
#   * metadata-config           - per-model pool/backend/api-version map
#   * set-backend-authorization - static (no substitution required)
#
# Mirrors:
#   bicep/infra/modules/apim/policy-fragments.bicep
#   bicep/infra/modules/apim/llm-policy-fragments.bicep
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
variable "enable_pii_redaction" { type = bool }
variable "enable_unified_ai_api" { type = bool }
variable "uami_client_id" { type = string }

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

# ============================================================
# AWS named-value placeholders so the set-backend-authorization
# fragment compiles even with no AWS backends.
# ============================================================

resource "azurerm_api_management_named_value" "aws_access_key" {
  name                = "aws-access-key"
  display_name        = "aws-access-key"
  resource_group_name = var.apim_resource_group_name
  api_management_name = var.apim_name
  secret              = true
  value               = "NOT_CONFIGURED"
}

resource "azurerm_api_management_named_value" "aws_secret_key" {
  name                = "aws-secret-key"
  display_name        = "aws-secret-key"
  resource_group_name = var.apim_resource_group_name
  api_management_name = var.apim_name
  secret              = true
  value               = "NOT_CONFIGURED"
}

resource "azurerm_api_management_named_value" "aws_region" {
  name                = "aws-region"
  display_name        = "aws-region"
  resource_group_name = var.apim_resource_group_name
  api_management_name = var.apim_name
  value               = "NOT_CONFIGURED"
}

resource "azurerm_api_management_named_value" "anthropic_version" {
  name                = "anthropic-version"
  display_name        = "anthropic-version"
  resource_group_name = var.apim_resource_group_name
  api_management_name = var.apim_name
  value               = "2023-06-01"
}

# ============================================================
# Static fragments (one-shot from policy XML files)
# ============================================================

locals {
  policies_dir = "${path.module}/../../policies"

  # Static fragments that the Bicep policy-fragments.bicep registers unconditionally.
  static_fragments = {
    "ai-usage"                  = "frag-ai-usage.xml"
    "raise-throttling-events"   = "frag-raise-throttling-events.xml"
    "pii-anonymization"         = "frag-pii-anonymization.xml"
    "pii-deanonymization"       = "frag-pii-deanonymization.xml"
    "security-handler"          = "frag-security-handler.xml"
    "strip-backend-headers"     = "frag-strip-backend-headers.xml"
    "set-target-backend-pool"   = "frag-set-target-backend-pool.xml"
    "set-llm-usage"             = "frag-set-llm-usage.xml"
    "set-llm-requested-model"   = "frag-set-llm-requested-model.xml"
    "validate-model-access"     = "frag-validate-model-access.xml"
    "responses-id-security"     = "frag-responses-id-security.xml"
    "responses-id-cache-store"  = "frag-responses-id-cache-store.xml"
    "set-backend-authorization" = "frag-set-backend-authorization.xml"
  }

  # PII-conditional fragments.
  pii_fragments = var.enable_pii_redaction ? {
    "pii-state-saving"         = "frag-pii-state-saving.xml"
    "ai-foundry-compatibility" = "frag-ai-foundry-compatibility.xml"
  } : {}

  # Unified-AI-conditional fragments.
  unified_fragments = var.enable_unified_ai_api ? {
    "central-cache-manager" = "frag-central-cache-manager.xml"
    "request-processor"     = "frag-request-processor.xml"
    "path-builder"          = "frag-path-builder.xml"
    "set-response-headers"  = "frag-set-response-headers.xml"
  } : {}

  all_static_fragments = merge(local.static_fragments, local.pii_fragments, local.unified_fragments)
}

resource "azurerm_api_management_policy_fragment" "static" {
  for_each          = local.all_static_fragments
  api_management_id = var.apim_id
  name              = each.key
  format            = "rawxml"
  description       = "Static fragment loaded from ${each.value}"
  value             = file("${local.policies_dir}/${each.value}")
}

# Resolve-model-alias gets the inline aliases placeholder removed.
resource "azurerm_api_management_policy_fragment" "resolve_model_alias" {
  api_management_id = var.apim_id
  name              = "resolve-model-alias"
  format            = "rawxml"
  description       = "Resolves model alias names to underlying models"
  value             = replace(file("${local.policies_dir}/frag-resolve-model-alias.xml"), "//{inlineAliasesCode}", "")
}

# ============================================================
# Dynamically generated fragments
# ============================================================

locals {
  # `set-backend-pools` C# JObject entries (one per model+backend_type)
  all_pools_for_code = concat(
    [for p in var.llm_backend_pools : {
      pool_name        = p.pool_name
      pool_type        = p.backend_type
      supported_models = [p.model_name]
    }],
    # Direct backends = backends serving a model with no multi-backend pool
    flatten([
      for cfg in var.llm_backends : [
        for m in cfg.supported_models :
        {
          pool_name        = cfg.backend_id
          pool_type        = cfg.backend_type
          supported_models = [m.name]
        }
        if length([for p in var.llm_backend_pools : p if p.model_name == m.name && p.backend_type == cfg.backend_type]) == 0
      ]
    ])
  )

  backend_pools_code = join("\n", [
    for idx, pool in local.all_pools_for_code :
    join("\n", [
      "// Pool: ${pool.pool_name} (Type: ${pool.pool_type})",
      "var pool_${idx} = new JObject()",
      "{",
      "    { \"poolName\", \"${pool.pool_name}\" },",
      "    { \"poolType\", \"${pool.pool_type}\" },",
      "    { \"supportedModels\", new JArray(${join(", ", [for m in pool.supported_models : "\"${m}\""])}) }",
      "};",
      "backendPools.Add(pool_${idx});",
      "",
    ])
  ])

  set_backend_pools_xml = replace(
    file("${local.policies_dir}/frag-set-backend-pools.xml"),
    "//{backendPoolsCode}",
    local.backend_pools_code
  )

  # Flat list of (backend, model) for get-available-models C# emit
  model_deployment_pairs = flatten([
    for cfg in var.llm_backends : [
      for m in cfg.supported_models : {
        backend_id   = cfg.backend_id
        backend_type = cfg.backend_type
        model        = m
      }
    ]
  ])

  model_deployments_code = join("\n\n", [
    for idx, pair in local.model_deployment_pairs : <<-CSHARP
// Model: ${pair.model.name} from backend: ${pair.backend_id}
var deployment_${idx} = new JObject()
{
    { "id", "${pair.backend_id}" },
    { "type", "${pair.backend_type}" },
    { "name", "${pair.model.name}" },
    { "sku", new JObject() { { "name", "${try(pair.model.sku, "Standard")}" }, { "capacity", ${try(pair.model.capacity, 100)} } } },
    { "properties", new JObject() {
        { "model", new JObject() { { "format", "${try(pair.model.model_format, "OpenAI")}" }, { "name", "${pair.model.name}" }, { "version", "${try(pair.model.model_version, "1")}" } } },
        { "capabilities", new JObject() { { "chatCompletion", "true" } } },
        { "provisioningState", "Succeeded" }${try(pair.model.retirement_date, "") != "" ? ",\n        { \"retirementDate\", \"${pair.model.retirement_date}\" }" : ""}
    }}
};
modelDeployments.Add(deployment_${idx});
CSHARP
  ])

  get_available_models_xml = replace(
    file("${local.policies_dir}/frag-get-available-models.xml"),
    "//{modelDeploymentsCode}",
    local.model_deployments_code
  )

  # metadata-config: for each unique model name pick first pool/backend that serves it
  seen_models_with_meta = distinct([for pair in local.model_deployment_pairs : pair.model.name])

  metadata_model_entries = join(",\n", [
    for name in local.seen_models_with_meta :
    join("", [
      "\t\t\t'", name, "': {\n",
      "\t\t\t\t'backend': '", coalesce(
        try([for p in local.all_pools_for_code : p.pool_name if contains(p.supported_models, name)][0], ""),
        ""
      ), "',\n",
      "\t\t\t\t'apiVersion': '", coalesce(try([for pair in local.model_deployment_pairs : pair.model.api_version if pair.model.name == name && try(pair.model.api_version, "") != ""][0], ""), "2024-02-15-preview"), "',\n",
      "\t\t\t\t'timeout': ", tostring(try([for pair in local.model_deployment_pairs : pair.model.timeout if pair.model.name == name][0], 120)),
      try([for pair in local.model_deployment_pairs : pair.model.inference_api_version if pair.model.name == name && try(pair.model.inference_api_version, "") != ""][0], "") != "" ?
      format(",\n\t\t\t\t'inferenceApiVersion': '%s'", [for pair in local.model_deployment_pairs : pair.model.inference_api_version if pair.model.name == name && try(pair.model.inference_api_version, "") != ""][0]) : "",
      "\n\t\t\t}"
    ])
  ])

  metadata_config_xml = replace(
    file("${local.policies_dir}/frag-metadata-config.xml"),
    "//{modelsConfigCode}",
    local.metadata_model_entries
  )
}

resource "azurerm_api_management_policy_fragment" "set_backend_pools" {
  api_management_id = var.apim_id
  name              = "set-backend-pools"
  format            = "rawxml"
  description       = "Dynamically generated backend pool configurations"
  value             = local.set_backend_pools_xml

  depends_on = [
    azurerm_api_management_policy_fragment.static,
  ]
}

resource "azurerm_api_management_policy_fragment" "get_available_models" {
  api_management_id = var.apim_id
  name              = "get-available-models"
  format            = "rawxml"
  description       = "Returns model deployments with capabilities"
  value             = local.get_available_models_xml

  depends_on = [
    azurerm_api_management_policy_fragment.static,
  ]
}

resource "azurerm_api_management_policy_fragment" "metadata_config" {
  api_management_id = var.apim_id
  name              = "metadata-config"
  format            = "rawxml"
  description       = "Per-model routing metadata for Unified AI API"
  value             = local.metadata_config_xml

  depends_on = [
    azurerm_api_management_policy_fragment.static,
  ]
}

output "static_fragment_names" {
  value = [for f in azurerm_api_management_policy_fragment.static : f.name]
}

output "dynamic_fragment_names" {
  value = [
    azurerm_api_management_policy_fragment.set_backend_pools.name,
    azurerm_api_management_policy_fragment.get_available_models.name,
    azurerm_api_management_policy_fragment.metadata_config.name,
    azurerm_api_management_policy_fragment.resolve_model_alias.name,
  ]
}
