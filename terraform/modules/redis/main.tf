# --------------------------------------------------------------------
# Azure Managed Redis (Microsoft.Cache/redisEnterprise) for APIM
# semantic cache. azurerm has first-class support but we use azapi to
# enable the RediSearch module + client port 10000 + clustering policy
# as required by APIM's "useFromLocation: default" cache binding.
#
# Mirrors `bicep/infra/modules/redis/redis.bicep`.
# --------------------------------------------------------------------

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "Azure/azapi" }
  }
}

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "sku_name" {
  type    = string
  default = "Balanced_B10"
}

variable "sku_capacity" {
  type    = number
  default = 2
}

variable "minimum_tls_version" {
  type    = string
  default = "1.2"
}

variable "public_network_access_enabled" {
  type    = bool
  default = false
}

variable "private_endpoint_subnet_id" { type = string }
variable "private_endpoint_name" { type = string }
variable "dns_zone_id" { type = string }

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  uses_sku_capacity = can(regex("^Enterprise", var.sku_name))
  sku_object = local.uses_sku_capacity ? {
    name     = var.sku_name
    capacity = var.sku_capacity
    } : {
    name = var.sku_name
  }
}

resource "azapi_resource" "cluster" {
  type      = "Microsoft.Cache/redisEnterprise@2025-07-01"
  parent_id = data.azurerm_resource_group.rg.id
  name      = var.name
  location  = var.location
  tags      = var.tags

  body = {
    sku = local.sku_object
    properties = {
      minimumTlsVersion   = var.minimum_tls_version
      publicNetworkAccess = var.public_network_access_enabled ? "Enabled" : "Disabled"
    }
  }

  response_export_values = ["properties.hostName"]
}

resource "azapi_resource" "database" {
  type      = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  parent_id = azapi_resource.cluster.id
  name      = "default"

  body = {
    properties = {
      accessKeysAuthentication = "Enabled"
      evictionPolicy           = "NoEviction"
      clusteringPolicy         = "EnterpriseCluster"
      clientProtocol           = "Encrypted"
      modules = [
        { name = "RediSearch" }
      ]
      port = 10000
    }
  }

  response_export_values = ["properties.port"]
}

# Surface the primary access key via azapi action call.
resource "azapi_resource_action" "keys" {
  type        = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  resource_id = azapi_resource.database.id
  action      = "listKeys"
  method      = "POST"

  response_export_values = ["primaryKey"]
}

resource "azurerm_private_endpoint" "redis" {
  name                = var.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.private_endpoint_name
    private_connection_resource_id = azapi_resource.cluster.id
    is_manual_connection           = false
    subresource_names              = ["redisEnterprise"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

locals {
  host_name   = azapi_resource.cluster.output.properties.hostName
  port        = azapi_resource.database.output.properties.port
  primary_key = azapi_resource_action.keys.output.primaryKey
}

output "id" { value = azapi_resource.cluster.id }
output "hostname" { value = local.host_name }
output "port" { value = local.port }
output "connection_string" {
  value     = "${local.host_name}:${local.port},password=${local.primary_key},ssl=true"
  sensitive = true
}
