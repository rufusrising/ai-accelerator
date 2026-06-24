# --------------------------------------------------------------------
# Citadel full-greenfield module — variable surface.
#
# Defaults mirror `bicep/infra/main.bicep` + `main.parameters.dev.bicepparam`
# so that with a minimum set of inputs (env name, location, RG name) you
# get the full accelerator deployment.
# --------------------------------------------------------------------

# ============================================================
# Identity / naming
# ============================================================

variable "environment_name" {
  description = "Short environment identifier (e.g. dev, prod). Used in tagging."
  type        = string
}

variable "location" {
  description = "Primary Azure region. Must be on the Foundry-supported list (uaenorth, southafricanorth, westeurope, southcentralus, australiaeast, canadaeast, eastus, eastus2, francecentral, japaneast, northcentralus, swedencentral, switzerlandnorth, uksouth)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that owns every Citadel resource. Must already exist."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    workload        = "citadel-ai-hub"
    SecurityControl = "Ignore"
  }
}

variable "name_prefix" {
  description = "Short prefix combined with a stable random suffix for globally-unique resource names."
  type        = string
  default     = "citadel"
}

# ============================================================
# Networking (this module OWNS the VNet, subnets, DNS zones)
# ============================================================

variable "network" {
  description = "Greenfield VNet topology. Defaults mirror the Bicep accelerator's main.bicep."
  type = object({
    vnet_address_space             = optional(string, "10.170.0.0/24")
    apim_subnet_prefix             = optional(string, "10.170.0.0/26")
    private_endpoint_subnet_prefix = optional(string, "10.170.0.64/26")
    function_app_subnet_prefix     = optional(string, "10.170.0.128/26")
    agent_subnet_prefix            = optional(string, "10.170.0.192/26")
  })
  default = {}
}

# ============================================================
# Foundry (this module CREATES Foundry accounts + projects)
# ============================================================

variable "foundry_instances" {
  description = <<-EOT
    Foundry accounts to create. The FIRST entry is the primary — its endpoint
    is used by APIM as the content-safety + PII Language Service backend AND
    can host model deployments declared in foundry_model_deployments.

    Per-instance `network_injection_enabled` only takes effect when
    `features.enable_foundry_network_injection` is also true AND the agent
    subnet exists in the same region as the Foundry account.
  EOT
  type = list(object({
    name                       = string
    location                   = optional(string, "")
    custom_subdomain_name      = optional(string, "")
    default_project_name       = optional(string, "citadel-governance-project")
    network_injection_enabled  = optional(bool, false)
  }))

  validation {
    condition     = length(var.foundry_instances) >= 1
    error_message = "At least one Foundry instance is required (the first is treated as primary)."
  }
}

variable "foundry_model_deployments" {
  description = "Model deployments — same shape as the attach-mode module."
  type = list(object({
    name              = string
    publisher         = string
    version           = string
    sku               = optional(string, "GlobalStandard")
    capacity          = optional(number, 100)
    retirement_date   = optional(string, "")
    api_version       = optional(string, "")
    timeout           = optional(number, 0)
    inference_api_version = optional(string, "")
    foundry_index     = optional(number)
  }))
  default = []
}

variable "primary_foundry_embedding_model_name" {
  description = "Embedding deployment name on the primary Foundry used by APIM semantic cache."
  type        = string
  default     = "text-embedding-3-large"
}

variable "deployer_object_id" {
  description = "Object ID of the operator/CI identity — granted Azure AI Project Manager on each Foundry account."
  type        = string
  default     = ""
}

# ============================================================
# Feature flags
# ============================================================

variable "features" {
  description = "Toggle major capabilities. Defaults match the upstream accelerator."
  type = object({
    enable_ai_model_inference          = optional(bool, true)
    enable_document_intelligence       = optional(bool, true)
    enable_azure_ai_search             = optional(bool, true)
    enable_pii_redaction               = optional(bool, true)
    enable_openai_realtime             = optional(bool, true)
    enable_unified_ai_api              = optional(bool, true)
    enable_api_center                  = optional(bool, true)
    enable_managed_redis               = optional(bool, true)
    enable_usage_pipeline              = optional(bool, true)
    enable_mcp_samples                 = optional(bool, true)
    enable_entra_auth                  = optional(bool, true)
    enable_jwt_auth                    = optional(bool, true)
    enable_foundry_network_injection   = optional(bool, false)
    use_azure_monitor_private_link_scope = optional(bool, false)
    create_app_insights_dashboards     = optional(bool, false)
  })
  default = {}
}

variable "use_existing_log_analytics" {
  type    = bool
  default = false
}

variable "existing_log_analytics" {
  type = object({
    name                = string
    resource_group_name = string
    subscription_id     = optional(string, "")
  })
  default = {
    name                = ""
    resource_group_name = ""
  }
}

# ============================================================
# APIM + LLM backends
# ============================================================

variable "apim" {
  description = "APIM configuration. Defaults to StandardV2 with a private endpoint."
  type = object({
    sku_name              = optional(string, "StandardV2")
    sku_capacity          = optional(number, 1)
    publisher_name        = optional(string, "Citadel AI Hub")
    publisher_email       = optional(string, "noreply@example.com")
    public_network_access = optional(bool, false)
    use_private_endpoint  = optional(bool, true)
    zones                 = optional(list(string), [])
  })
  default = {}
}

variable "apim_redis_cache_name" {
  type    = string
  default = "redis-cache"
}

variable "llm_backends" {
  description = "Additional external LLM backends (Bedrock, Anthropic, etc.). See attach-mode module for the schema."
  type = list(object({
    backend_id     = string
    backend_type   = string
    endpoint       = string
    auth_type      = optional(string, "api-key-header")
    auth_secret_kv_id = optional(string, "")
    auth_secret_value = optional(string, "")
    named_value_key   = optional(string, "")
    priority       = optional(number, 1)
    weight         = optional(number, 100)
    supported_models = list(object({
      name            = string
      sku             = optional(string, "Standard")
      capacity        = optional(number, 100)
      model_format    = optional(string, "OpenAI")
      model_version   = optional(string, "1")
      retirement_date = optional(string, "")
      api_version     = optional(string, "")
      timeout         = optional(number, 120)
      inference_api_version = optional(string, "")
    }))
  }))
  default = []
}

variable "ai_search_instances" {
  type = list(object({
    name        = string
    url         = string
    description = optional(string, "")
  }))
  default = []
}

# ============================================================
# Entra ID
# ============================================================

variable "entra_tenant_id" {
  type    = string
  default = ""
}

variable "entra_client_id" {
  type    = string
  default = ""
}

variable "entra_audience" {
  type    = string
  default = ""
}

# ============================================================
# Compute / capacity
# ============================================================

variable "redis" {
  type = object({
    sku_name            = optional(string, "Balanced_B10")
    sku_capacity        = optional(number, 2)
    minimum_tls_version = optional(string, "1.2")
  })
  default = {}
}

variable "cosmos_db_throughput" {
  type    = number
  default = 400
}

variable "event_hub" {
  type = object({
    sku                       = optional(string, "Standard")
    capacity                  = optional(number, 1)
    auto_inflate_enabled      = optional(bool, true)
    maximum_throughput_units  = optional(number, 20)
    message_retention_days    = optional(number, 7)
    public_network_access     = optional(bool, true)
  })
  default = {}
}

variable "logic_app_sku_capacity" {
  type    = number
  default = 1
}

# ============================================================
# APIC
# ============================================================

variable "apic" {
  type = object({
    sku      = optional(string, "Free")
    location = optional(string, "")
  })
  default = {}
}

# ============================================================
# Per-tenant access contracts (citadel)
# ============================================================

variable "access_contracts" {
  type = list(object({
    use_case = object({
      business_unit = string
      use_case_name = string
      environment   = string
    })
    services = list(object({
      code                   = string
      api_names              = list(string)
      product_policy_xml_path = optional(string, "")
      endpoint_secret_name   = optional(string, "")
      api_key_secret_name    = optional(string, "")
    }))
    product_terms = optional(string, "")
    write_kv_secrets = optional(bool, true)
    foundry_connection = optional(object({
      account_name        = string
      resource_group_name = string
      project_name        = string
      connection_prefix   = optional(string, "")
      shared_to_all       = optional(bool, false)
    }))
  }))
  default = []
}
