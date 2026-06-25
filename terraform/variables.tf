# --------------------------------------------------------------------
# Root-module input variables.
#
# Defaults mirror the Bicep accelerator (`bicep/infra/main.bicep`). The
# module is designed for attaching the AI Hub Gateway accelerator on top
# of an existing Azure AI Foundry account/project, an existing VNet, and
# existing Private DNS zones (BYO networking).
# --------------------------------------------------------------------

# ============================================================
# Basic identity / naming
# ============================================================

variable "environment_name" {
  description = "Short environment identifier (e.g. dev, prod). Used in resource naming and tagging."
  type        = string
}

variable "location" {
  description = <<-EOT
    Default Azure region for provisioned resources. Used as a fallback when a
    per-resource override (e.g. var.cosmos_location, var.apic.location) is empty.

    The APIM service location is always FORCED to match var.network.vnet_location
    because APIM V2 SKUs require the integration subnet to be in the same region
    as the APIM service itself. Other resources can live in any region; their
    private endpoints will be placed in the VNet's region (var.network.vnet_location)
    regardless of where the resource lives.
  EOT
  type        = string
}

# -- Per-resource region overrides ---------------------------------------
# Leave blank to inherit var.location. Use these when the resource type
# isn't available in your VNet's region (e.g. API Center in eastus while
# your VNet is in eastus2). The private endpoint for the resource is still
# created in var.network.vnet_location.

variable "key_vault_location" {
  type    = string
  default = ""
}

variable "cosmos_location" {
  type    = string
  default = ""
}

variable "event_hub_location" {
  type    = string
  default = ""
}

variable "redis_location" {
  type    = string
  default = ""
}

variable "storage_location" {
  type    = string
  default = ""
}

variable "logic_app_location" {
  type    = string
  default = ""
}

variable "monitoring_location" {
  type    = string
  default = ""
}

variable "resource_group_name" {
  description = "Resource group that owns the gateway resources. Must already exist; the module does NOT create it."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    workload        = "ai-hub-gateway"
    SecurityControl = "Ignore"
  }
}

variable "name_prefix" {
  description = "Short prefix for resource names. Combined with a stable random suffix to keep names globally unique while being human-readable."
  type        = string
  default     = "aihub"
}

# ============================================================
# Existing AI Foundry (attach-only)
# ============================================================

variable "foundry" {
  description = <<-EOT
    Existing AI Foundry account(s) the gateway attaches to. The FIRST entry is the
    primary Foundry — its endpoint serves the APIM AI Gateway's content-safety and
    PII (Language Service) backends. Additional entries are treated as extra
    regional Foundry resources to host LLM model deployments only.

    Each entry:
      - account_name        : Foundry Cognitive Services account name (existing).
      - resource_group_name : RG of the Foundry account.
      - subscription_id     : (optional) defaults to the current subscription.
      - project_name        : (optional) Foundry project name for Foundry connections.
      - location            : (optional) used only for tagging deployed models.
  EOT
  type = list(object({
    account_name        = string
    resource_group_name = string
    subscription_id     = optional(string, "")
    project_name        = optional(string, "")
    location            = optional(string, "")
  }))
  validation {
    condition     = length(var.foundry) >= 1
    error_message = "At least one Foundry account must be supplied (the first is treated as the primary)."
  }
}

variable "foundry_model_deployments" {
  description = <<-EOT
    Model deployments to create on the existing Foundry accounts. Mirrors the
    Bicep `aiFoundryModelsConfig` shape. Set `foundry_index` to target a specific
    Foundry account (by index in `var.foundry`); omit to deploy to all.
  EOT
  type = list(object({
    name                  = string
    publisher             = string
    version               = string
    sku                   = optional(string, "GlobalStandard")
    capacity              = optional(number, 100)
    retirement_date       = optional(string, "")
    api_version           = optional(string, "")
    timeout               = optional(number, 0)
    inference_api_version = optional(string, "")
    foundry_index         = optional(number)
  }))
  default = []
}

variable "primary_foundry_embedding_model_name" {
  description = "Name of the text-embedding deployment in the primary Foundry. Wired into the embeddings backend used for APIM semantic cache."
  type        = string
  default     = "text-embedding-3-large"
}

# ============================================================
# BYO networking
# ============================================================

variable "network" {
  description = <<-EOT
    Existing networking inputs. Every subnet must be in the SAME VNet (or peered if not).

      vnet_id                       : Resource ID of the existing VNet.
      vnet_location                 : Azure region of the VNet. Required because every Private
                                      Endpoint MUST be created in the same region as its subnet —
                                      even when the target resource is in a different region.
      apim_subnet_id                : Subnet for APIM v2 stv2 (delegation not required for V2 SKUs but PE is placed in the PE subnet).
      private_endpoint_subnet_id    : Subnet that hosts every private endpoint.
      function_app_subnet_id        : Subnet (delegated to Microsoft.Web/serverFarms) for the Logic App Standard runtime.
      agent_subnet_id               : (optional) Subnet delegated to Microsoft.App/environments for Foundry agent network injection.
  EOT
  type = object({
    vnet_id                    = string
    vnet_location              = string
    apim_subnet_id             = string
    private_endpoint_subnet_id = string
    function_app_subnet_id     = string
    agent_subnet_id            = optional(string, "")
  })
}

variable "create_dns_a_records" {
  description = <<-EOT
    Whether each private endpoint's privateDnsZoneGroup (the resource that writes the
    A record into the central DNS zone) is created by this module.

    true  (default) — module creates the group. Requires the deploying principal to
          hold `Private DNS Zone Contributor` on each zone in var.private_dns_zone_ids,
          even when the zones live in a different subscription.
    false           — module SKIPS the group. The PE still gets a NIC + IP, and the
          {fqdn, ip_addresses[]} pairs are surfaced via the `pe_dns_records` output
          so your central DNS-as-code pipeline can write the A records out-of-band.
  EOT
  type    = bool
  default = true
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    Existing Private DNS zone resource IDs. The VNet only needs to RESOLVE these zones
    (typically via Azure Firewall DNS proxy or a DNS Private Resolver in the hub) — the
    zones do NOT need to be linked to var.network.vnet_id directly. This matches the CAF
    centralized-DNS landing-zone pattern where DNS zones live in a connectivity sub.

    When create_dns_a_records=true, the deploying principal must hold Private DNS Zone
    Contributor on each zone (cross-sub RBAC is fine). When false, the zones can be in
    any sub regardless of your RBAC.
  EOT
  type = object({
    key_vault          = string               # privatelink.vaultcore.azure.net
    cosmos_db          = string               # privatelink.documents.azure.com
    event_hub          = string               # privatelink.servicebus.windows.net
    storage_blob       = string               # privatelink.blob.core.windows.net
    storage_file       = string               # privatelink.file.core.windows.net
    storage_table      = string               # privatelink.table.core.windows.net
    storage_queue      = string               # privatelink.queue.core.windows.net
    cognitive_services = string               # privatelink.cognitiveservices.azure.com
    openai             = string               # privatelink.openai.azure.com
    ai_services        = string               # privatelink.services.ai.azure.com
    apim_gateway       = string               # privatelink.azure-api.net
    redis_enterprise   = string               # privatelink.redis.azure.net
    azure_monitor      = optional(string, "") # privatelink.monitor.azure.com (only if use_azure_monitor_private_link_scope=true)
  })
}

# ============================================================
# Feature flags
# ============================================================

variable "features" {
  description = "Toggle major capabilities. Defaults match the upstream accelerator."
  type = object({
    enable_ai_model_inference            = optional(bool, true)
    enable_document_intelligence         = optional(bool, true)
    enable_azure_ai_search               = optional(bool, true)
    enable_pii_redaction                 = optional(bool, true)
    enable_openai_realtime               = optional(bool, true)
    enable_unified_ai_api                = optional(bool, true)
    enable_api_center                    = optional(bool, true)
    enable_managed_redis                 = optional(bool, true)
    enable_usage_pipeline                = optional(bool, true) # CosmosDB + Event Hub + Logic App processor
    enable_mcp_samples                   = optional(bool, true)
    enable_entra_auth                    = optional(bool, true)
    enable_jwt_auth                      = optional(bool, true)
    use_azure_monitor_private_link_scope = optional(bool, false)
    create_app_insights_dashboards       = optional(bool, false)
  })
  default = {}
}

variable "use_existing_log_analytics" {
  description = "When true, the monitoring submodule references an existing Log Analytics workspace instead of creating one."
  type        = bool
  default     = false
}

variable "existing_log_analytics" {
  description = "Existing Log Analytics workspace coordinates (used only when use_existing_log_analytics=true)."
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
# APIM
# ============================================================

variable "apim" {
  description = "API Management configuration. Module defaults to StandardV2 with a private endpoint."
  type = object({
    sku_name              = optional(string, "StandardV2") # StandardV2 | PremiumV2 | Premium | Developer
    sku_capacity          = optional(number, 1)
    publisher_name        = optional(string, "AI Hub Gateway")
    publisher_email       = optional(string, "noreply@example.com")
    public_network_access = optional(bool, false) # V2 SKUs only
    use_private_endpoint  = optional(bool, true)  # V2 SKUs only
    zones                 = optional(list(string), [])
  })
  default = {}
}

variable "apim_redis_cache_name" {
  description = "APIM cache entity name registered against the Azure Managed Redis instance."
  type        = string
  default     = "redis-cache"
}

# ============================================================
# LLM backends
# ============================================================

variable "llm_backends" {
  description = <<-EOT
    Additional or override LLM backends. By default the module derives one backend per
    Foundry entry in `var.foundry` and uses **API-key auth** (per the design requirement
    that APIM->Foundry traffic uses API keys, NOT managed identity). You can supplement
    with external LLM providers here (Bedrock, Gemini, Anthropic, OpenAI, etc.).

    auth_type:
      - "api-key-bearer"  : Authorization header,  value template = "Bearer <secret>"
      - "api-key-header"  : api-key header
      - "api-key-gemini"  : x-goog-api-key
      - "api-key-anthropic": x-api-key + anthropic-version
      - "managed-identity": APIM UAMI -> backend
      - "aws-sigv4"       : Bedrock SigV4 (policy-side)
      - "none"            : no credentials at backend
  EOT
  type = list(object({
    backend_id        = string
    backend_type      = string
    endpoint          = string
    auth_type         = optional(string, "api-key-header")
    auth_secret_kv_id = optional(string, "") # Key Vault Secret resource ID (uri)
    auth_secret_value = optional(string, "") # inline (testing only)
    named_value_key   = optional(string, "") # APIM named-value key (defaults to <backend_id>-key)
    priority          = optional(number, 1)
    weight            = optional(number, 100)
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
  default = []
}

variable "foundry_api_key_secret_uri" {
  description = <<-EOT
    DEPRECATED / OPTIONAL. The module now defaults to **managed-identity** auth for
    APIM->Foundry calls (the APIM user-assigned managed identity has Cognitive
    Services OpenAI User on each Foundry account, so APIM acquires tokens
    natively at the backend layer — no api-key required).

    This input is retained ONLY for the case where you want to add EXTRA, non-Foundry
    LLM backends via `var.llm_backends` that use the same KV secret. The default
    Foundry backends ignore it.
  EOT
  type        = string
  default     = ""
}

# ============================================================
# AI Search backends (optional)
# ============================================================

variable "ai_search_instances" {
  description = "Optional AI Search backends exposed through APIM."
  type = list(object({
    name        = string
    url         = string
    description = optional(string, "")
  }))
  default = []
}

# ============================================================
# Entra ID / JWT
# ============================================================

variable "entra_tenant_id" {
  description = "Tenant ID used by JWT-validate policies and APIM named values."
  type        = string
  default     = ""
}

variable "entra_client_id" {
  description = "App registration client ID used by Entra ID auth policies."
  type        = string
  default     = ""
}

variable "entra_audience" {
  description = "Expected JWT audience."
  type        = string
  default     = ""
}

# ============================================================
# Compute / capacity
# ============================================================

variable "redis" {
  description = "Azure Managed Redis (Microsoft.Cache/redisEnterprise) settings."
  type = object({
    sku_name            = optional(string, "Balanced_B10")
    sku_capacity        = optional(number, 2)
    minimum_tls_version = optional(string, "1.2")
  })
  default = {}
}

variable "cosmos_db_throughput" {
  description = "Manual RU/s for the usage Cosmos DB containers."
  type        = number
  default     = 400
}

variable "event_hub" {
  description = "Event Hub namespace settings."
  type = object({
    sku                      = optional(string, "Standard")
    capacity                 = optional(number, 1)
    auto_inflate_enabled     = optional(bool, true)
    maximum_throughput_units = optional(number, 20)
    message_retention_days   = optional(number, 7)
    public_network_access    = optional(bool, true) # needed during provisioning for V2 APIM SKUs
  })
  default = {}
}

variable "logic_app_sku_capacity" {
  description = "Workflow Standard plan capacity units for the usage processor Logic App."
  type        = number
  default     = 1
}

# ============================================================
# APIC
# ============================================================

variable "apic" {
  description = "API Center settings."
  type = object({
    sku      = optional(string, "Free")
    location = optional(string, "") # leave blank to use var.location
  })
  default = {}
}

# ============================================================
# Per-tenant access contracts (citadel)
# ============================================================

variable "access_contracts" {
  description = <<-EOT
    Per-tenant / per-business-unit access contracts. Each entry creates one or more APIM
    products + subscriptions (and optional Foundry connections). Mirrors the
    `citadel-access-contracts` Bicep module.

    Each entry:
      use_case    : { business_unit, use_case_name, environment }
      services    : list of { code, api_names[], product_policy_xml?, foundry_connection? }
      foundry     : optional { account_name, resource_group_name, project_name } for connections.
  EOT
  type = list(object({
    use_case = object({
      business_unit = string
      use_case_name = string
      environment   = string
    })
    services = list(object({
      code                    = string
      api_names               = list(string)
      product_policy_xml_path = optional(string, "")
      endpoint_secret_name    = optional(string, "")
      api_key_secret_name     = optional(string, "")
    }))
    product_terms    = optional(string, "")
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
