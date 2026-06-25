# --------------------------------------------------------------------
# Greenfield networking submodule.
#
# Owns:
#   - VNet (one address space)
#   - 4 subnets (apim, pe, function-app delegated to Microsoft.Web/serverFarms,
#                optional agent delegated to Microsoft.App/environments)
#   - NSGs for each subnet (APIM NSG carries the inbound/outbound rules
#     required for stv2 APIM to operate inside a VNet)
#   - Route Table for the APIM subnet (apim-management → Internet next hop)
#   - 12 Private DNS zones + VNet links
#
# Mirrors `bicep/infra/modules/networking/vnet.bicep` plus the per-zone
# dns/private-dns-zone resources in main.bicep.
# --------------------------------------------------------------------

variable "vnet_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "address_space" {
  type    = string
  default = "10.170.0.0/24"
}

variable "apim_subnet_name" {
  type    = string
  default = "snet-apim"
}

variable "apim_subnet_prefix" {
  type    = string
  default = "10.170.0.0/26"
}

variable "private_endpoint_subnet_name" {
  type    = string
  default = "snet-private-endpoint"
}

variable "private_endpoint_subnet_prefix" {
  type    = string
  default = "10.170.0.64/26"
}

variable "function_app_subnet_name" {
  type    = string
  default = "snet-functionapp"
}

variable "function_app_subnet_prefix" {
  type    = string
  default = "10.170.0.128/26"
}

variable "enable_agent_subnet" {
  type    = bool
  default = false
}

variable "agent_subnet_name" {
  type    = string
  default = "snet-agents"
}

variable "agent_subnet_prefix" {
  type    = string
  default = "10.170.0.192/26"
}

variable "is_apim_v2_sku" {
  type    = bool
  default = true
}

variable "include_azure_monitor_dns_zone" {
  type    = bool
  default = false
}

# CENTRALIZED DNS PATTERN (matches CAF landing-zone DNS architecture)
#   true  (default) — module creates the 12 Private DNS zones in this RG
#         AND links them to the VNet. Use for fully greenfield single-sub
#         deployments.
#   false           — module creates NEITHER the zones NOR the VNet links.
#         Caller must supply `external_private_dns_zone_ids` pointing at
#         zones that live in a different (central) subscription / RG.
#         The spoke VNet is expected to resolve those zones via DNS
#         forwarders (Azure Firewall DNS proxy, DNS Private Resolver,
#         or custom DNS servers) — that wiring lives at the hub.
variable "create_private_dns_zones" {
  type    = bool
  default = true
}

variable "external_private_dns_zone_ids" {
  description = "Required when create_private_dns_zones=false. Same shape as the root module's private_dns_zone_ids."
  type = object({
    key_vault          = string
    cosmos_db          = string
    event_hub          = string
    storage_blob       = string
    storage_file       = string
    storage_table      = string
    storage_queue      = string
    cognitive_services = string
    openai             = string
    ai_services        = string
    apim_gateway       = string
    redis_enterprise   = string
    azure_monitor      = optional(string, "")
  })
  default = null
}

# --------------------------
# NSGs
# --------------------------

# APIM NSG carries the canonical rule set Microsoft documents for stv2
# (https://learn.microsoft.com/azure/api-management/api-management-using-with-vnet).
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-${var.apim_subnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowPublicAccess"
    priority                   = 3000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAPIMManagement"
    priority                   = 3010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAPIMLoadBalancer"
    priority                   = 3020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureTrafficManager"
    priority                   = 3030
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureTrafficManager"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowStorage"
    priority                   = 3000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  security_rule {
    name                       = "AllowSql"
    priority                   = 3010
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Sql"
  }

  security_rule {
    name                       = "AllowKeyVault"
    priority                   = 3020
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureKeyVault"
  }

  security_rule {
    name                         = "AllowMonitor"
    priority                     = 3030
    direction                    = "Outbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_ranges      = ["1886", "443"]
    source_address_prefix        = "VirtualNetwork"
    destination_address_prefix   = "AzureMonitor"
  }
}

resource "azurerm_network_security_group" "private_endpoint" {
  name                = "nsg-${var.private_endpoint_subnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "function_app" {
  name                = "nsg-${var.function_app_subnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "agent" {
  count               = var.enable_agent_subnet ? 1 : 0
  name                = "nsg-${var.agent_subnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# --------------------------
# Route table (APIM management traffic → Internet)
# --------------------------

resource "azurerm_route_table" "apim" {
  name                = "rt-${var.apim_subnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  route {
    name           = "apim-management"
    address_prefix = "ApiManagement"
    next_hop_type  = "Internet"
  }
}

# --------------------------
# VNet + subnets
# --------------------------

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "apim" {
  name                 = var.apim_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.apim_subnet_prefix]

  private_endpoint_network_policies             = "Enabled"
  private_link_service_network_policies_enabled = true

  service_endpoints = [
    "Microsoft.AzureActiveDirectory",
    "Microsoft.EventHub",
    "Microsoft.KeyVault",
    "Microsoft.ServiceBus",
    "Microsoft.Sql",
    "Microsoft.Storage",
    "Microsoft.CognitiveServices",
  ]

  # APIM V2 SKUs (StandardV2, PremiumV2) require the apim subnet delegated
  # to Microsoft.Web/serverFarms (the V2 data-plane runs on App Service).
  dynamic "delegation" {
    for_each = var.is_apim_v2_sku ? [1] : []
    content {
      name = "Microsoft.Web.serverFarms"
      service_delegation {
        name = "Microsoft.Web/serverFarms"
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

resource "azurerm_subnet_route_table_association" "apim" {
  subnet_id      = azurerm_subnet.apim.id
  route_table_id = azurerm_route_table.apim.id
}

resource "azurerm_subnet" "private_endpoint" {
  name                 = var.private_endpoint_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.private_endpoint_subnet_prefix]

  private_endpoint_network_policies             = "Disabled"
  private_link_service_network_policies_enabled = true

  service_endpoints = ["Microsoft.CognitiveServices"]
}

resource "azurerm_subnet_network_security_group_association" "private_endpoint" {
  subnet_id                 = azurerm_subnet.private_endpoint.id
  network_security_group_id = azurerm_network_security_group.private_endpoint.id
}

resource "azurerm_subnet" "function_app" {
  name                 = var.function_app_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.function_app_subnet_prefix]

  private_endpoint_network_policies             = "Enabled"
  private_link_service_network_policies_enabled = true

  service_endpoints = ["Microsoft.CognitiveServices"]

  delegation {
    name = "Microsoft.Web.serverFarms"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "function_app" {
  subnet_id                 = azurerm_subnet.function_app.id
  network_security_group_id = azurerm_network_security_group.function_app.id
}

resource "azurerm_subnet" "agent" {
  count                = var.enable_agent_subnet ? 1 : 0
  name                 = var.agent_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.agent_subnet_prefix]

  private_endpoint_network_policies             = "Enabled"
  private_link_service_network_policies_enabled = true

  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "agent" {
  count                     = var.enable_agent_subnet ? 1 : 0
  subnet_id                 = azurerm_subnet.agent[0].id
  network_security_group_id = azurerm_network_security_group.agent[0].id
}

# --------------------------
# Private DNS zones + VNet links
# --------------------------

locals {
  base_dns_zones = [
    "privatelink.vaultcore.azure.net",
    "privatelink.documents.azure.com",
    "privatelink.servicebus.windows.net",
    "privatelink.blob.core.windows.net",
    "privatelink.file.core.windows.net",
    "privatelink.table.core.windows.net",
    "privatelink.queue.core.windows.net",
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
    "privatelink.azure-api.net",
    "privatelink.redis.azure.net",
  ]

  dns_zones = var.include_azure_monitor_dns_zone ? concat(local.base_dns_zones, ["privatelink.monitor.azure.com"]) : local.base_dns_zones
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = var.create_private_dns_zones ? toset(local.dns_zones) : toset([])
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = azurerm_private_dns_zone.this
  name                  = "${each.key}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

# --------------------------
# Outputs (shaped to satisfy the existing root-module variables)
# --------------------------

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "apim_subnet_id" {
  value = azurerm_subnet.apim.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.private_endpoint.id
}

output "function_app_subnet_id" {
  value = azurerm_subnet.function_app.id
}

output "agent_subnet_id" {
  value = try(azurerm_subnet.agent[0].id, "")
}

output "private_dns_zone_ids" {
  description = "Map matching the shape root-module `private_dns_zone_ids` expects. Sourced from the locally-created zones when create_private_dns_zones=true, otherwise from var.external_private_dns_zone_ids."
  value = var.create_private_dns_zones ? {
    key_vault          = azurerm_private_dns_zone.this["privatelink.vaultcore.azure.net"].id
    cosmos_db          = azurerm_private_dns_zone.this["privatelink.documents.azure.com"].id
    event_hub          = azurerm_private_dns_zone.this["privatelink.servicebus.windows.net"].id
    storage_blob       = azurerm_private_dns_zone.this["privatelink.blob.core.windows.net"].id
    storage_file       = azurerm_private_dns_zone.this["privatelink.file.core.windows.net"].id
    storage_table      = azurerm_private_dns_zone.this["privatelink.table.core.windows.net"].id
    storage_queue      = azurerm_private_dns_zone.this["privatelink.queue.core.windows.net"].id
    cognitive_services = azurerm_private_dns_zone.this["privatelink.cognitiveservices.azure.com"].id
    openai             = azurerm_private_dns_zone.this["privatelink.openai.azure.com"].id
    ai_services        = azurerm_private_dns_zone.this["privatelink.services.ai.azure.com"].id
    apim_gateway       = azurerm_private_dns_zone.this["privatelink.azure-api.net"].id
    redis_enterprise   = azurerm_private_dns_zone.this["privatelink.redis.azure.net"].id
    azure_monitor      = try(azurerm_private_dns_zone.this["privatelink.monitor.azure.com"].id, "")
    } : {
    key_vault          = var.external_private_dns_zone_ids.key_vault
    cosmos_db          = var.external_private_dns_zone_ids.cosmos_db
    event_hub          = var.external_private_dns_zone_ids.event_hub
    storage_blob       = var.external_private_dns_zone_ids.storage_blob
    storage_file       = var.external_private_dns_zone_ids.storage_file
    storage_table      = var.external_private_dns_zone_ids.storage_table
    storage_queue      = var.external_private_dns_zone_ids.storage_queue
    cognitive_services = var.external_private_dns_zone_ids.cognitive_services
    openai             = var.external_private_dns_zone_ids.openai
    ai_services        = var.external_private_dns_zone_ids.ai_services
    apim_gateway       = var.external_private_dns_zone_ids.apim_gateway
    redis_enterprise   = var.external_private_dns_zone_ids.redis_enterprise
    azure_monitor      = try(var.external_private_dns_zone_ids.azure_monitor, "")
  }
}
