# --------------------------------------------------------------------
# API Center submodule.
#
# azurerm has very limited apiCenter coverage so we use azapi for the
# core service, workspace, environments and metadata schema. APIM-side
# API registration (apiCenter API import) is not done by this module —
# operators typically import APIs from APIM via the portal or the
# `az apic api register` CLI after deployment.
#
# Mirrors `bicep/infra/modules/apic/apic.bicep`.
# --------------------------------------------------------------------

terraform {
  required_providers {
    azapi = { source = "Azure/azapi" }
  }
}

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "sku" {
  type    = string
  default = "Free"
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azapi_resource" "service" {
  type      = "Microsoft.ApiCenter/services@2024-06-01-preview"
  parent_id = data.azurerm_resource_group.rg.id
  name      = var.name
  location  = var.location
  tags      = var.tags

  body = {
    sku = { name = var.sku }
    properties = {
      portalSettings = { enabled = true }
      siteProfile = {
        name              = "AI Hub API Registry"
        companyName       = "AI Hub"
        companyUrl        = "https://example.com"
        supportEmail      = "support@example.com"
        termsOfServiceUrl = "https://example.com/terms"
        privacyPolicyUrl  = "https://example.com/privacy"
      }
    }
  }

  schema_validation_enabled = false
}

resource "azapi_resource" "workspace" {
  type      = "Microsoft.ApiCenter/services/workspaces@2024-06-01-preview"
  parent_id = azapi_resource.service.id
  name      = "default"

  body = {
    properties = {
      title       = "Default workspace"
      description = "Default workspace"
    }
  }
}

resource "azapi_resource" "env_api_dev" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  parent_id = azapi_resource.workspace.id
  name      = "api-dev"
  body = {
    properties = {
      title       = "API Development"
      description = "API default development environment"
      kind        = "REST"
      server = {
        managementPortalUri = ["https://portal.azure.com/"]
        type                = "Development"
      }
    }
  }
}

resource "azapi_resource" "env_api_prod" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  parent_id = azapi_resource.workspace.id
  name      = "api-prod"
  body = {
    properties = {
      title       = "API Production"
      description = "API default production environment"
      kind        = "REST"
      server = {
        managementPortalUri = ["https://portal.azure.com/"]
        type                = "Production"
      }
    }
  }
}

resource "azapi_resource" "env_mcp_dev" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  parent_id = azapi_resource.workspace.id
  name      = "mcp-dev"
  body = {
    properties = {
      title       = "MCP Development"
      description = "MCP default development environment"
      kind        = "MCP"
      server = {
        managementPortalUri = ["https://portal.azure.com/"]
        type                = "Development"
      }
    }
  }
}

resource "azapi_resource" "env_mcp_prod" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  parent_id = azapi_resource.workspace.id
  name      = "mcp-prod"
  body = {
    properties = {
      title       = "MCP Production"
      description = "MCP default production environment"
      kind        = "MCP"
      server = {
        managementPortalUri = ["https://portal.azure.com/"]
        type                = "Production"
      }
    }
  }
}

output "id" { value = azapi_resource.service.id }
output "name" { value = azapi_resource.service.name }
output "workspace_name" { value = azapi_resource.workspace.name }
