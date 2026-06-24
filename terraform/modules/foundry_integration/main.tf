# --------------------------------------------------------------------
# Foundry integration submodule (ATTACH MODE — existing Foundry accounts)
#
# Responsibilities:
#   1. Reference existing Foundry Cognitive Services accounts (data source).
#   2. Create model deployments (cognitive_deployment) per `model_deployments`
#      var, scoped to the specified Foundry entry (foundry_index).
#   3. Grant the APIM user-assigned managed identity Cognitive Services User
#      on each Foundry account scope. This is required so that if the
#      operator switches a specific LLM backend from api-key auth to
#      managed-identity auth later, no extra plumbing is needed.
#
# IMPORTANT — design constraint from the user:
#   APIM->Foundry traffic uses API keys (NOT managed identity). That wiring
#   is performed in apim_apis (named values + backend credentials.header).
#   The MI role assignment here is defence-in-depth / future-proofing.
# --------------------------------------------------------------------

variable "foundry" {
  type = list(object({
    account_name        = string
    resource_group_name = string
    subscription_id     = optional(string, "")
    project_name        = optional(string, "")
    location            = optional(string, "")
  }))
}

variable "model_deployments" {
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

variable "apim_uami_principal_id" { type = string }
variable "primary_foundry_endpoint" { type = string }

# Existing Foundry accounts (one data source per entry).
data "azurerm_cognitive_account" "foundry" {
  count               = length(var.foundry)
  name                = var.foundry[count.index].account_name
  resource_group_name = var.foundry[count.index].resource_group_name
}

# Grant APIM UAMI Cognitive Services OpenAI User on each Foundry account.
# Idempotent (UUIDv5-based naming via Terraform's deterministic generation).
resource "azurerm_role_assignment" "apim_cog_openai_user" {
  count                = length(var.foundry)
  scope                = data.azurerm_cognitive_account.foundry[count.index].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = var.apim_uami_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_cog_user" {
  count                = length(var.foundry)
  scope                = data.azurerm_cognitive_account.foundry[count.index].id
  role_definition_name = "Cognitive Services User"
  principal_id         = var.apim_uami_principal_id
  principal_type       = "ServicePrincipal"
}

# Flatten deployments × target indexes so we can use a single for_each.
locals {
  deployments_expanded = flatten([
    for m in var.model_deployments :
    m.foundry_index == null ?
    [for i in range(length(var.foundry)) : merge(m, { _idx = i })] :
    [merge(m, { _idx = m.foundry_index })]
  ])

  deployments_keyed = {
    for d in local.deployments_expanded :
    "${d._idx}-${d.name}" => d
  }
}

resource "azurerm_cognitive_deployment" "models" {
  for_each             = local.deployments_keyed
  name                 = each.value.name
  cognitive_account_id = data.azurerm_cognitive_account.foundry[each.value._idx].id

  model {
    format  = each.value.publisher
    name    = each.value.name
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }

  rai_policy_name = "Microsoft.DefaultV2"
}

output "foundry_account_ids" {
  value = [for f in data.azurerm_cognitive_account.foundry : f.id]
}

output "foundry_endpoints" {
  value = [for f in data.azurerm_cognitive_account.foundry : f.endpoint]
}

output "model_deployment_names" {
  value = [for k, d in azurerm_cognitive_deployment.models : d.name]
}
