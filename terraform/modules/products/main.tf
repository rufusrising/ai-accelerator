# --------------------------------------------------------------------
# Citadel-style access contracts submodule.
#
# Per service entry, this creates:
#   - APIM product       <code>-<bu>-<usecase>-<env>
#   - Product API links  (member APIs from service.api_names)
#   - Product policy     (default minimal or user-supplied XML)
#   - Subscription       <code>-<bu>-<usecase>-<env>-SUB-01
#   - 2 x KV secrets     <endpoint_secret_name>, <api_key_secret_name>
#   - Optional Foundry connection on the supplied Foundry project
#
# Mirrors `bicep/infra/citadel-access-contracts/main.bicep`.
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
variable "apim_gateway_url" { type = string }

variable "use_case" {
  type = object({
    business_unit = string
    use_case_name = string
    environment   = string
  })
}

variable "services" {
  type = list(object({
    code                    = string
    api_names               = list(string)
    product_policy_xml_path = optional(string, "")
    endpoint_secret_name    = optional(string, "")
    api_key_secret_name     = optional(string, "")
  }))
}

variable "product_terms" {
  type    = string
  default = ""
}

variable "write_kv_secrets" {
  type    = bool
  default = true
}

variable "key_vault_id" { type = string }

variable "foundry_connection" {
  type = object({
    account_name        = string
    resource_group_name = string
    project_name        = string
    connection_prefix   = optional(string, "")
    shared_to_all       = optional(bool, false)
  })
  default = null
}

locals {
  product_postfix = "${var.use_case.business_unit}-${var.use_case.use_case_name}-${var.use_case.environment}"

  default_policy_xml = <<-XML
    <policies>
      <inbound>
        <base />
        <rate-limit calls="60" renewal-period="60" />
        <check-header name="Ocp-Apim-Subscription-Key" failed-check-httpcode="401" failed-check-error-message="Subscription key required" />
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML

  services_by_code = { for s in var.services : s.code => s }

  foundry_connection_prefix = var.foundry_connection != null ? coalesce(var.foundry_connection.connection_prefix, "Hub-${local.product_postfix}") : ""
}

# ============================================================
# Products + Subscriptions
# ============================================================

resource "azurerm_api_management_product" "this" {
  for_each              = local.services_by_code
  product_id            = "${each.value.code}-${local.product_postfix}"
  api_management_name   = var.apim_name
  resource_group_name   = var.apim_resource_group_name
  display_name          = "${each.value.code} ${var.use_case.business_unit} ${var.use_case.use_case_name} ${var.use_case.environment}"
  description           = "AI Gateway product for ${each.value.code} - ${var.use_case.use_case_name}"
  terms                 = var.product_terms
  subscription_required = true
  approval_required     = false
  subscriptions_limit   = 10
  published             = true
}

resource "azurerm_api_management_product_policy" "this" {
  for_each            = local.services_by_code
  product_id          = azurerm_api_management_product.this[each.key].product_id
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  xml_content         = each.value.product_policy_xml_path == "" ? local.default_policy_xml : file(each.value.product_policy_xml_path)
}

# Flatten (service, api) pairs for product/api linkages.
locals {
  product_api_pairs = flatten([
    for code, s in local.services_by_code : [
      for api in s.api_names : {
        key      = "${code}::${api}"
        code     = code
        api_name = api
      }
    ]
  ])
}

resource "azurerm_api_management_product_api" "this" {
  for_each            = { for p in local.product_api_pairs : p.key => p }
  product_id          = azurerm_api_management_product.this[each.value.code].product_id
  api_name            = each.value.api_name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
}

resource "azurerm_api_management_subscription" "this" {
  for_each            = local.services_by_code
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  product_id          = azurerm_api_management_product.this[each.key].id
  display_name        = "${each.value.code}-${local.product_postfix}-SUB-01"
  subscription_id     = "${each.value.code}-${local.product_postfix}-SUB-01"
  state               = "active"
}

# Look up the first API in each service to construct endpoint URLs.
data "azurerm_api_management_api" "first" {
  for_each            = local.services_by_code
  name                = each.value.api_names[0]
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group_name
  revision            = "1"
}

# ============================================================
# Key Vault secrets per service (endpoint + api key)
# ============================================================

locals {
  kv_secret_pairs = var.write_kv_secrets ? flatten([
    for code, s in local.services_by_code : [
      {
        key   = "${code}-endpoint"
        name  = lower(replace(coalesce(s.endpoint_secret_name, "${code}-ENDPOINT"), "_", "-"))
        value = "${var.apim_gateway_url}/${data.azurerm_api_management_api.first[code].path}"
      },
      {
        key   = "${code}-key"
        name  = lower(replace(coalesce(s.api_key_secret_name, "${code}-KEY"), "_", "-"))
        value = azurerm_api_management_subscription.this[code].primary_key
      }
    ]
  ]) : []
}

resource "azurerm_key_vault_secret" "service" {
  for_each     = { for p in local.kv_secret_pairs : p.key => p }
  name         = each.value.name
  value        = each.value.value
  key_vault_id = var.key_vault_id
  content_type = "text/plain"
}

# ============================================================
# Foundry APIM connection (optional)
# ============================================================

data "azurerm_subscription" "current" {}

locals {
  foundry_project_id = var.foundry_connection == null ? "" : format(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.CognitiveServices/accounts/%s/projects/%s",
    data.azurerm_subscription.current.subscription_id,
    var.foundry_connection.resource_group_name,
    var.foundry_connection.account_name,
    var.foundry_connection.project_name,
  )
}

resource "azapi_resource" "foundry_connection" {
  for_each  = var.foundry_connection == null ? {} : local.services_by_code
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  parent_id = local.foundry_project_id
  name      = "${local.foundry_connection_prefix}-${each.value.code}"

  body = {
    properties = {
      category      = "ApiManagement"
      target        = "${var.apim_gateway_url}/${data.azurerm_api_management_api.first[each.key].path}"
      authType      = "ApiKey"
      isSharedToAll = var.foundry_connection.shared_to_all
      credentials = {
        key = azurerm_api_management_subscription.this[each.key].primary_key
      }
      metadata = {
        deploymentInPath = "false"
      }
    }
  }

  schema_validation_enabled = false

  depends_on = [
    azurerm_api_management_subscription.this,
  ]
}

# ============================================================
# Outputs
# ============================================================

output "product_ids" {
  value = [for p in azurerm_api_management_product.this : p.product_id]
}

output "subscription_names" {
  value = [for s in azurerm_api_management_subscription.this : s.display_name]
}

output "foundry_connection_names" {
  value = [for c in azapi_resource.foundry_connection : c.name]
}
