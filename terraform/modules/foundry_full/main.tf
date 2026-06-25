# --------------------------------------------------------------------
# Greenfield Foundry submodule.
#
# Creates one or more Azure AI Foundry (Cognitive Services kind=AIServices)
# accounts plus a default project on each, model deployments, multi-DNS
# private endpoints, optional agent network injection (subnet delegated
# to Microsoft.App/environments), and the required RBAC for APIM and the
# project manager.
#
# Mirrors `bicep/infra/modules/foundry/foundry.bicep` +
# `bicep/infra/modules/foundry/deployments.bicep`.
#
# Auth model: APIM calls Foundry using its UAMI. The role assignments below
# grant Cognitive Services User + Cognitive Services OpenAI User to the
# APIM UAMI on each Foundry account scope, so token acquisition works
# at the APIM Backend's credentials.managedIdentity layer.
# --------------------------------------------------------------------

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "Azure/azapi" }
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "foundry_instances" {
  description = <<-EOT
    List of Foundry accounts to create. The FIRST entry is the primary —
    its endpoint is the content-safety / PII Language Service backend.
  EOT
  type = list(object({
    name                       = string
    location                   = optional(string, "")
    custom_subdomain_name      = optional(string, "")
    default_project_name       = optional(string, "citadel-governance-project")
    network_injection_enabled  = optional(bool, false)
  }))
}

variable "model_deployments" {
  description = "Model deployments. foundry_index selects target Foundry; omit to deploy to all."
  type = list(object({
    name              = string
    publisher         = string
    version           = string
    sku               = optional(string, "GlobalStandard")
    capacity          = optional(number, 100)
    retirement_date   = optional(string, "")
    foundry_index     = optional(number)
  }))
  default = []
}

variable "public_network_access_enabled" {
  type    = bool
  default = false
}

variable "disable_local_auth" {
  type    = bool
  default = false
}

variable "private_endpoint_subnet_id" { type = string }

# Foundry PE region. Must match the VNet that owns private_endpoint_subnet_id.
# Default is each Foundry instance's own region (which works only when
# Foundry and VNet are co-located). For cross-region (Foundry in eastus2,
# VNet in eastus) set this explicitly to the VNet region — Azure supports
# cross-region private endpoints to Cognitive Services accounts.
variable "private_endpoint_location" {
  type    = string
  default = ""
}

variable "create_dns_a_records" {
  type    = bool
  default = true
}

variable "private_dns_zone_ids" {
  description = "DNS zone IDs required for the Foundry account PE (3 zones)."
  type = object({
    cognitive_services = string
    openai             = string
    ai_services        = string
  })
}

variable "agent_subnet_id" {
  description = "Subnet delegated to Microsoft.App/environments. Required only when any foundry_instances[*].network_injection_enabled is true."
  type        = string
  default     = ""
}

variable "apim_uami_principal_id" {
  description = "APIM user-assigned managed identity principal ID — granted Cognitive Services User / OpenAI User on each Foundry."
  type        = string
}

variable "deployer_object_id" {
  description = "Object ID of the operator running terraform — granted Azure AI Project Manager on each Foundry account so the project shows up in Foundry studio."
  type        = string
  default     = ""
}

variable "log_analytics_workspace_id" {
  type    = string
  default = ""
}

variable "app_insights_id" {
  type    = string
  default = ""
}

variable "app_insights_instrumentation_key" {
  type      = string
  default   = ""
  sensitive = true
}

# ------------------------------------------------------------
# Foundry accounts (Cognitive Services kind=AIServices)
# ------------------------------------------------------------

resource "azapi_resource" "foundry" {
  count     = length(var.foundry_instances)
  type      = "Microsoft.CognitiveServices/accounts@2026-01-15-preview"
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  name      = var.foundry_instances[count.index].name
  location  = coalesce(var.foundry_instances[count.index].location, var.location)
  tags      = var.tags

  body = {
    identity = {
      type = "SystemAssigned"
    }
    sku = {
      name = "S0"
    }
    kind = "AIServices"
    properties = merge(
      {
        allowProjectManagement = true
        customSubDomainName    = lower(coalesce(var.foundry_instances[count.index].custom_subdomain_name, var.foundry_instances[count.index].name))
        disableLocalAuth       = var.disable_local_auth
        publicNetworkAccess    = var.public_network_access_enabled ? "Enabled" : "Disabled"
        networkAcls = {
          defaultAction       = "Deny"
          bypass              = "AzureServices"
          ipRules             = []
          virtualNetworkRules = []
        }
      },
      var.foundry_instances[count.index].network_injection_enabled && var.agent_subnet_id != "" ? {
        networkInjections = [
          {
            scenario                    = "agent"
            subnetArmId                 = var.agent_subnet_id
            useMicrosoftManagedNetwork  = false
          }
        ]
      } : {}
    )
  }

  response_export_values = ["identity.principalId", "properties.endpoint"]

  schema_validation_enabled = false
}

data "azurerm_subscription" "current" {}

# ------------------------------------------------------------
# Foundry projects (one per Foundry account)
# ------------------------------------------------------------

resource "azapi_resource" "project" {
  count     = length(var.foundry_instances)
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  parent_id = azapi_resource.foundry[count.index].id
  name      = coalesce(var.foundry_instances[count.index].default_project_name, "citadel-governance-project")
  location  = coalesce(var.foundry_instances[count.index].location, var.location)
  tags      = var.tags

  body = {
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      description = "Citadel Governance Hub default project for AI Evaluation default LLMs"
    }
  }

  depends_on = [
    azapi_resource.private_endpoint,
  ]

  schema_validation_enabled = false
}

# ------------------------------------------------------------
# Model deployments (cognitive_deployment)
# ------------------------------------------------------------

locals {
  deployments_expanded = flatten([
    for m in var.model_deployments :
    m.foundry_index == null ?
      [for i in range(length(var.foundry_instances)) : merge(m, { _idx = i })] :
      [merge(m, { _idx = m.foundry_index })]
  ])

  deployments_keyed = {
    for d in local.deployments_expanded :
    "${d._idx}-${d.name}" => d
  }
}

# Use azapi for deployments so we can pin @batchSize(1) ordering via
# explicit depends_on chains (Bicep batches model deployments serially to
# avoid Cognitive Services quota races).
resource "azapi_resource" "deployment" {
  for_each  = local.deployments_keyed
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-06-01"
  parent_id = azapi_resource.foundry[each.value._idx].id
  name      = each.value.name

  body = {
    sku = {
      name     = each.value.sku
      capacity = each.value.capacity
    }
    properties = {
      model = {
        format  = each.value.publisher
        name    = each.value.name
        version = each.value.version
      }
      raiPolicyName = "Microsoft.DefaultV2"
    }
  }

  depends_on = [
    azapi_resource.project,
    azurerm_role_assignment.apim_cog_openai_user,
  ]

  schema_validation_enabled = false
}

# ------------------------------------------------------------
# Private endpoints (multi-DNS: 3 zones per Foundry account)
# ------------------------------------------------------------

resource "azapi_resource" "private_endpoint" {
  count                  = length(var.foundry_instances)
  type                   = "Microsoft.Network/privateEndpoints@2025-05-01"
  parent_id              = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  name                   = "${var.foundry_instances[count.index].name}-pe"
  response_export_values = ["properties.customDnsConfigs"]
  # PE always lives in the VNet's region; coalesce falls back to the
  # Foundry account region (co-located deployments) when the caller hasn't
  # passed an explicit private_endpoint_location.
  location = coalesce(
    var.private_endpoint_location,
    var.foundry_instances[count.index].location,
    var.location,
  )
  tags = var.tags

  body = {
    properties = {
      subnet = { id = var.private_endpoint_subnet_id }
      privateLinkServiceConnections = [
        {
          name = "${var.foundry_instances[count.index].name}-pe"
          properties = {
            privateLinkServiceId = azapi_resource.foundry[count.index].id
            groupIds             = ["account"]
          }
        }
      ]
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "pe_dns_zone_group" {
  count     = var.create_dns_a_records ? length(var.foundry_instances) : 0
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01"
  parent_id = azapi_resource.private_endpoint[count.index].id
  name      = "privateDnsZoneGroup"

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "cognitiveservices"
          properties = { privateDnsZoneId = var.private_dns_zone_ids.cognitive_services }
        },
        {
          name = "openai"
          properties = { privateDnsZoneId = var.private_dns_zone_ids.openai }
        },
        {
          name = "aiservices"
          properties = { privateDnsZoneId = var.private_dns_zone_ids.ai_services }
        },
      ]
    }
  }
}

# ------------------------------------------------------------
# RBAC: APIM UAMI on every Foundry account
# ------------------------------------------------------------

resource "azurerm_role_assignment" "apim_cog_openai_user" {
  count                = length(var.foundry_instances)
  scope                = azapi_resource.foundry[count.index].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = var.apim_uami_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_cog_user" {
  count                = length(var.foundry_instances)
  scope                = azapi_resource.foundry[count.index].id
  role_definition_name = "Cognitive Services User"
  principal_id         = var.apim_uami_principal_id
  principal_type       = "ServicePrincipal"
}

# Optional: grant the operator Azure AI Project Manager so the Foundry
# project surfaces in studio. The role definition ID matches the Bicep
# variable `aiProjectManagerRoleDefinitionID`.
resource "azurerm_role_assignment" "deployer_project_manager" {
  count                = var.deployer_object_id == "" ? 0 : length(var.foundry_instances)
  scope                = azapi_resource.foundry[count.index].id
  role_definition_id   = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/eadc314b-1a2d-4efa-be10-5d325db5065e"
  principal_id         = var.deployer_object_id
}

# ------------------------------------------------------------
# Diagnostic settings + App Insights connection
# ------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "foundry" {
  count                      = var.log_analytics_workspace_id == "" ? 0 : length(var.foundry_instances)
  name                       = "${var.foundry_instances[count.index].name}-diagnostics"
  target_resource_id         = azapi_resource.foundry[count.index].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azapi_resource" "app_insights_connection" {
  count     = (var.app_insights_id == "" || var.app_insights_instrumentation_key == "") ? 0 : length(var.foundry_instances)
  type      = "Microsoft.CognitiveServices/accounts/connections@2025-06-01"
  parent_id = azapi_resource.foundry[count.index].id
  name      = "${var.foundry_instances[count.index].name}-appInsights-connection"

  body = {
    properties = {
      authType                    = "ApiKey"
      category                    = "AppInsights"
      target                      = var.app_insights_id
      useWorkspaceManagedIdentity = false
      isSharedToAll               = false
      sharedUserList              = []
      peRequirement               = "NotRequired"
      peStatus                    = "NotApplicable"
      metadata = {
        ApiType    = "Azure"
        ResourceId = var.app_insights_id
      }
      credentials = {
        key = var.app_insights_instrumentation_key
      }
    }
  }

  schema_validation_enabled = false
}

# ------------------------------------------------------------
# Outputs (same shape that downstream submodules expect)
# ------------------------------------------------------------

output "foundry_account_ids" {
  value = [for f in azapi_resource.foundry : f.id]
}

output "foundry_account_names" {
  value = [for f in azapi_resource.foundry : f.name]
}

output "foundry_endpoints" {
  value = [for f in azapi_resource.foundry : f.output.properties.endpoint]
}

output "foundry_system_assigned_principal_ids" {
  value = [for f in azapi_resource.foundry : f.output.identity.principalId]
}

output "primary_foundry_account_name" {
  value = azapi_resource.foundry[0].name
}

output "primary_foundry_endpoint" {
  value = "https://${azapi_resource.foundry[0].name}.cognitiveservices.azure.com/"
}

output "project_names" {
  value = [for p in azapi_resource.project : p.name]
}

output "pe_dns_configs" {
  description = "Per-Foundry list of { fqdn, ipAddresses[] } records exported from the PE NIC. Each Foundry needs 3 A records (cognitiveservices / openai / services.ai). When create_dns_a_records=false, feed these into the central DNS pipeline."
  value       = [for pe in azapi_resource.private_endpoint : try(pe.output.properties.customDnsConfigs, [])]
}
