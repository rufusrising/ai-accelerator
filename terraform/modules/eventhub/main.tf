# --------------------------------------------------------------------
# Event Hub namespace + 2 hubs (ai-usage + pii-usage) + consumer groups
# + private endpoint. Mirrors `bicep/infra/modules/event-hub/event-hub.bicep`.
# --------------------------------------------------------------------

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "sku" {
  type    = string
  default = "Standard"
}

variable "capacity" {
  type    = number
  default = 1
}

variable "auto_inflate_enabled" {
  type    = bool
  default = true
}

variable "maximum_throughput_units" {
  type    = number
  default = 20
}

variable "message_retention_days" {
  type    = number
  default = 7
}

variable "public_network_access" {
  type    = bool
  default = true
}

variable "enable_pii_hub" {
  type    = bool
  default = true
}

variable "private_endpoint_subnet_id" { type = string }
variable "private_endpoint_name" { type = string }
variable "dns_zone_id" { type = string }

# PE region — must equal the VNet's region. Defaults to var.location.
variable "private_endpoint_location" {
  type    = string
  default = ""
}

resource "azurerm_eventhub_namespace" "this" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = var.sku
  capacity                      = var.capacity
  auto_inflate_enabled          = var.auto_inflate_enabled
  maximum_throughput_units      = var.maximum_throughput_units
  public_network_access_enabled = var.public_network_access
  tags                          = var.tags
}

resource "azurerm_eventhub" "usage" {
  name              = "ai-usage"
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = 4
  message_retention = var.message_retention_days
}


resource "azurerm_eventhub_consumer_group" "usage_ingest" {
  name                = "aiUsageIngestion"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.usage.name
  resource_group_name = var.resource_group_name
}

resource "azurerm_eventhub" "pii" {
  count             = var.enable_pii_hub ? 1 : 0
  name              = "pii-usage"
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = 2
  message_retention = var.message_retention_days
}


resource "azurerm_eventhub_consumer_group" "pii_ingest" {
  count               = var.enable_pii_hub ? 1 : 0
  name                = "piiUsageIngestion"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.pii[0].name
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_endpoint" "eh" {
  name                = var.private_endpoint_name
  location            = coalesce(var.private_endpoint_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.private_endpoint_name
    private_connection_resource_id = azurerm_eventhub_namespace.this.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "namespace_id" { value = azurerm_eventhub_namespace.this.id }
output "namespace_name" { value = azurerm_eventhub_namespace.this.name }
output "usage_hub_name" { value = azurerm_eventhub.usage.name }
output "pii_hub_name" { value = try(azurerm_eventhub.pii[0].name, "") }
# `default_primary_connection_string`-style endpoint used by APIM loggers.
output "endpoint" { value = "https://${azurerm_eventhub_namespace.this.name}.servicebus.windows.net" }
