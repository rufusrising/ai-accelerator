# --------------------------------------------------------------------
# Provider & Terraform version constraints
# --------------------------------------------------------------------
# This module targets the latest stable Azure providers as of mid-2026.
# `azapi` is required for the resources without first-class azurerm support:
#   - APIM policy fragments
#   - APIM Cache (Microsoft.ApiManagement/service/caches)
#   - APIM Backend resources with the modern `credentials.managedIdentity`
#     and `credentials.header` shapes (incl. backend Pools)
#   - APIM 2024-06-01-preview API resource for the wildcard / MCP APIs
#   - Microsoft.ApiCenter/* (no azurerm coverage)
#   - Microsoft.CognitiveServices/accounts/projects/connections (Foundry connections)
#   - Microsoft.Cache/redisEnterprise (Azure Managed Redis) — first-class but we use
#     azapi for the database modules with RediSearch.
# --------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.20.0, < 5.0.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
