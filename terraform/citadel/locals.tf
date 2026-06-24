resource "random_string" "suffix" {
  length  = 6
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = random_string.suffix.result

  names = {
    apim_identity        = "id-apim-${var.name_prefix}-${local.suffix}"
    logic_app_identity   = "id-logicapp-${var.name_prefix}-${local.suffix}"
    apim                 = "apim-${var.name_prefix}-${local.suffix}"
    apim_pe              = "pe-apim-${var.name_prefix}-${local.suffix}"
    log_analytics        = "log-${var.name_prefix}-${local.suffix}"
    apim_appinsights     = "appi-apim-${var.name_prefix}-${local.suffix}"
    func_appinsights     = "appi-func-${var.name_prefix}-${local.suffix}"
    foundry_appinsights  = "appi-aif-${var.name_prefix}-${local.suffix}"
    key_vault            = substr(replace("kv-${var.name_prefix}-${local.suffix}", "_", ""), 0, 24)
    cosmos_db            = "cosmos-${var.name_prefix}-${local.suffix}"
    event_hub_namespace  = "evhns-${var.name_prefix}-${local.suffix}"
    storage_account      = substr("st${replace(var.name_prefix, "-", "")}${local.suffix}", 0, 24)
    logic_app            = "logic-usage-${var.name_prefix}-${local.suffix}"
    redis                = "redis-${var.name_prefix}-${local.suffix}"
    api_center           = "apic-${var.name_prefix}-${local.suffix}"
    vnet                 = "vnet-${var.name_prefix}-${local.suffix}"
    kv_pe                = "pe-kv-${local.suffix}"
    cosmos_pe            = "pe-cosmos-${local.suffix}"
    eh_pe                = "pe-evh-${local.suffix}"
    redis_pe             = "pe-redis-${local.suffix}"
    storage_blob_pe      = "pe-st-blob-${local.suffix}"
    storage_file_pe      = "pe-st-file-${local.suffix}"
    storage_table_pe     = "pe-st-table-${local.suffix}"
    storage_queue_pe     = "pe-st-queue-${local.suffix}"
  }

  features = var.features
  is_v2_apim = contains(["StandardV2", "PremiumV2"], coalesce(var.apim.sku_name, "StandardV2"))

  # Build Foundry-backed LLM backends with managed-identity auth (default).
  # The APIM UAMI gets Cognitive Services OpenAI User on every Foundry account
  # via `module.foundry_full`, so token acquisition works at backend layer.
  derived_foundry_backends = [
    for idx, f in var.foundry_instances : {
      backend_id        = "${f.name}-${idx}"
      backend_type      = "ai-foundry"
      endpoint          = "https://${f.name}.cognitiveservices.azure.com/"
      auth_type         = "managed-identity"
      auth_secret_kv_id = ""
      auth_secret_value = ""
      named_value_key   = ""
      priority          = 1
      weight            = 100
      supported_models = [
        for m in [for x in var.foundry_model_deployments : x if try(x.foundry_index, null) == idx] : {
          name            = m.name
          sku             = m.sku
          capacity        = m.capacity
          model_format    = m.publisher
          model_version   = m.version
          retirement_date = m.retirement_date
          api_version     = m.api_version
          timeout         = m.timeout
          inference_api_version = m.inference_api_version
        }
      ]
    }
  ]

  effective_llm_backends = concat(local.derived_foundry_backends, var.llm_backends)

  llm_backend_named_values = {
    for cfg in local.effective_llm_backends :
    coalesce(cfg.named_value_key, "${cfg.backend_id}-key") => {
      secret_uri  = cfg.auth_secret_kv_id
      secret_val  = cfg.auth_secret_value
    } if can(regex("^api-key", cfg.auth_type))
  }

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

  primary_foundry_account_name   = var.foundry_instances[0].name
  primary_foundry_endpoint       = "https://${local.primary_foundry_account_name}.cognitiveservices.azure.com/"
  primary_foundry_embeddings_url = "${local.primary_foundry_endpoint}openai/deployments/${var.primary_foundry_embedding_model_name}/embeddings"

  effective_tags = merge(var.tags, {
    "azd-env-name" = var.environment_name
  })
}
