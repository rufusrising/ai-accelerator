# --------------------------------------------------------------------
# Monitoring submodule
#   - Log Analytics workspace (or reference existing)
#   - 3 x Application Insights (APIM, Logic App / Function App, Foundry)
#
# Mirrors `bicep/infra/modules/monitor/monitoring.bicep`.
# The Azure Monitor Private Link Scope is intentionally NOT created here
# (BYO networking model — the user is expected to wire AMPLS at the
# platform layer; the root module accepts a private_dns_zone_ids.azure_monitor
# key for future use).
# --------------------------------------------------------------------

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "log_analytics_name" { type = string }
variable "apim_app_insights_name" { type = string }
variable "func_app_insights_name" { type = string }
variable "foundry_app_insights_name" { type = string }

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

# ----------------------------------
# Log Analytics
# ----------------------------------

data "azurerm_log_analytics_workspace" "existing" {
  count               = var.use_existing_log_analytics ? 1 : 0
  name                = var.existing_log_analytics.name
  resource_group_name = var.existing_log_analytics.resource_group_name
}

resource "azurerm_log_analytics_workspace" "this" {
  count               = var.use_existing_log_analytics ? 0 : 1
  name                = var.log_analytics_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

locals {
  workspace_id   = var.use_existing_log_analytics ? data.azurerm_log_analytics_workspace.existing[0].id : azurerm_log_analytics_workspace.this[0].id
  workspace_name = var.use_existing_log_analytics ? data.azurerm_log_analytics_workspace.existing[0].name : azurerm_log_analytics_workspace.this[0].name
}

# ----------------------------------
# Application Insights x 3 (web, workspace-based)
# ----------------------------------

resource "azurerm_application_insights" "apim" {
  name                = var.apim_app_insights_name
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = local.workspace_id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_application_insights" "func" {
  name                = var.func_app_insights_name
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = local.workspace_id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_application_insights" "foundry" {
  name                = var.foundry_app_insights_name
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = local.workspace_id
  application_type    = "web"
  tags                = var.tags
}

# ----------------------------------
# Outputs
# ----------------------------------

output "log_analytics_workspace_id" { value = local.workspace_id }
output "log_analytics_workspace_name" { value = local.workspace_name }

output "apim_app_insights_id" {
  value = azurerm_application_insights.apim.id
}

output "apim_app_insights_name" {
  value = azurerm_application_insights.apim.name
}

output "apim_app_insights_connection_string" {
  value     = azurerm_application_insights.apim.connection_string
  sensitive = true
}

output "apim_app_insights_instrumentation_key" {
  value     = azurerm_application_insights.apim.instrumentation_key
  sensitive = true
}

output "func_app_insights_id" {
  value = azurerm_application_insights.func.id
}

output "func_app_insights_name" {
  value = azurerm_application_insights.func.name
}

output "func_app_insights_connection_string" {
  value     = azurerm_application_insights.func.connection_string
  sensitive = true
}

output "foundry_app_insights_id" {
  value = azurerm_application_insights.foundry.id
}

output "foundry_app_insights_name" {
  value = azurerm_application_insights.foundry.name
}

output "foundry_app_insights_connection_string" {
  value     = azurerm_application_insights.foundry.connection_string
  sensitive = true
}

output "foundry_app_insights_instrumentation_key" {
  value     = azurerm_application_insights.foundry.instrumentation_key
  sensitive = true
}
