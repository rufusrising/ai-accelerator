# --------------------------------------------------------------------
# Derived locals — naming, computed LLM backend list, DNS look-ups
# --------------------------------------------------------------------

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

locals {
  # Stable resource suffix — equivalent to `uniqueString` in Bicep.
  suffix = random_string.suffix.result

  # Convenience names mirroring the Bicep abbreviations.
  names = {
    apim_identity       = "id-apim-${var.name_prefix}-${local.suffix}"
    logic_app_identity  = "id-logicapp-${var.name_prefix}-${local.suffix}"
    apim                = "apim-${var.name_prefix}-${local.suffix}"
    apim_pe             = "pe-apim-${var.name_prefix}-${local.suffix}"
    log_analytics       = "log-${var.name_prefix}-${local.suffix}"
    apim_appinsights    = "appi-apim-${var.name_prefix}-${local.suffix}"
    func_appinsights    = "appi-func-${var.name_prefix}-${local.suffix}"
    foundry_appinsights = "appi-aif-${var.name_prefix}-${local.suffix}"
    key_vault           = substr(replace("kv-${var.name_prefix}-${local.suffix}", "_", ""), 0, 24)
    cosmos_db           = "cosmos-${var.name_prefix}-${local.suffix}"
    event_hub_namespace = "evhns-${var.name_prefix}-${local.suffix}"
    storage_account     = substr("st${replace(var.name_prefix, "-", "")}${local.suffix}", 0, 24)
    logic_app           = "logic-usage-${var.name_prefix}-${local.suffix}"
    redis               = "redis-${var.name_prefix}-${local.suffix}"
    api_center          = "apic-${var.name_prefix}-${local.suffix}"
    apim_pe_namespace   = "pe-apim-${local.suffix}"
    foundry_pe_base     = "pe-aif-${local.suffix}"
    kv_pe               = "pe-kv-${local.suffix}"
    cosmos_pe           = "pe-cosmos-${local.suffix}"
    eh_pe               = "pe-evh-${local.suffix}"
    redis_pe            = "pe-redis-${local.suffix}"
    storage_blob_pe     = "pe-st-blob-${local.suffix}"
    storage_file_pe     = "pe-st-file-${local.suffix}"
    storage_table_pe    = "pe-st-table-${local.suffix}"
    storage_queue_pe    = "pe-st-queue-${local.suffix}"
  }

  # Primary Foundry — first entry is authoritative for content-safety + PII URLs.
  primary_foundry_account_name   = var.foundry[0].account_name
  primary_foundry_endpoint       = "https://${local.primary_foundry_account_name}.cognitiveservices.azure.com/"
  primary_foundry_embeddings_url = "${local.primary_foundry_endpoint}openai/deployments/${var.primary_foundry_embedding_model_name}/embeddings"

  # Auto-generated Foundry-backed LLM backend list.
  #
  # Authentication: APIM uses its user-assigned managed identity (configured via
  # `credentials.managedIdentity` on the APIM Backend resource). The UAMI is
  # granted `Cognitive Services OpenAI User` + `Cognitive Services User` on each
  # Foundry account by the foundry_integration submodule, so token acquisition
  # happens natively at the APIM backend layer — no API keys, no policy-side
  # auth headers, no named-value plumbing.
  #
  # To override a specific Foundry-backed entry with api-key auth (or any other
  # auth_type), pass an entry in `var.llm_backends` with the same backend_id; the
  # user-supplied entry wins because it's concatenated AFTER the derived list.
  derived_foundry_backends = [
    for idx, f in var.foundry : {
      backend_id        = "${f.account_name}-${idx}"
      backend_type      = "ai-foundry"
      endpoint          = "https://${f.account_name}.cognitiveservices.azure.com/"
      auth_type         = "managed-identity"
      auth_secret_kv_id = ""
      auth_secret_value = ""
      named_value_key   = ""
      priority          = 1
      weight            = 100
      supported_models = [
        for m in [for x in var.foundry_model_deployments : x if try(x.foundry_index, null) == idx] : {
          name                  = m.name
          sku                   = m.sku
          capacity              = m.capacity
          model_format          = m.publisher
          model_version         = m.version
          retirement_date       = m.retirement_date
          api_version           = m.api_version
          timeout               = m.timeout
          inference_api_version = m.inference_api_version
        }
      ]
    }
  ]

  # Combined effective backend list (Foundry + user-provided externals).
  effective_llm_backends = concat(local.derived_foundry_backends, var.llm_backends)

  # Index backends by named-value key to deduplicate APIM named values.
  llm_backend_named_values = {
    for cfg in local.effective_llm_backends :
    coalesce(cfg.named_value_key, "${cfg.backend_id}-key") => {
      secret_uri = cfg.auth_secret_kv_id
      secret_val = cfg.auth_secret_value
    } if can(regex("^api-key", cfg.auth_type))
  }

  # Pool grouping — model + backend_type composite key. Mirrors llm-backend-pools.bicep.
  _model_backend_pairs = flatten([
    for cfg in local.effective_llm_backends : [
      for m in cfg.supported_models : {
        model        = m.name
        backend_type = cfg.backend_type
        backend_id   = cfg.backend_id
        priority     = cfg.priority
        weight       = cfg.weight
      }
    ]
  ])

  _grouped_pools = {
    for pair in local._model_backend_pairs :
    "${pair.model}||${pair.backend_type}" => pair...
  }

  # Pools = (model, backend_type) groups with >1 backend
  _pool_keys = [for k, v in local._grouped_pools : k if length(v) > 1]

  llm_backend_pools = [
    for k in local._pool_keys : {
      pool_name = format(
        "%s-%s-backend-pool",
        replace(replace(replace(replace(split("||", k)[0], ".", ""), ":", ""), "_", ""), "/", ""),
        replace(replace(replace(replace(split("||", k)[1], ".", ""), ":", ""), "_", ""), "/", "")
      )
      model_name   = split("||", k)[0]
      backend_type = split("||", k)[1]
      backends     = local._grouped_pools[k]
    }
  ]

  # Tag every resource the module owns.
  effective_tags = merge(var.tags, {
    "azd-env-name" = var.environment_name
  })

  features = var.features
}
