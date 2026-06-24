# --------------------------------------------------------------------
# Example root config that consumes the ai-hub-gateway module.
# Replace the placeholder IDs in main.tfvars with your own resources.
# --------------------------------------------------------------------

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 4.20.0, < 5.0.0" }
    azapi   = { source = "Azure/azapi", version = ">= 2.2.0" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

# Inputs intentionally mirror the upstream module variables so the
# example tfvars works without translation.
variable "environment_name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" {
  type = string
}

variable "foundry" {
  type = list(object({
    account_name        = string
    resource_group_name = string
    subscription_id     = optional(string, "")
    project_name        = optional(string, "")
    location            = optional(string, "")
  }))
}

variable "foundry_model_deployments" {
  type    = list(any)
  default = []
}

variable "primary_foundry_embedding_model_name" {
  type    = string
  default = "text-embedding-3-large"
}

variable "foundry_api_key_secret_uri" {
  type    = string
  default = ""
}

variable "network" {
  type = object({
    vnet_id                    = string
    apim_subnet_id             = string
    private_endpoint_subnet_id = string
    function_app_subnet_id     = string
    agent_subnet_id            = optional(string, "")
  })
}

variable "private_dns_zone_ids" {
  type = any
}

variable "apim" {
  type    = any
  default = {}
}

variable "features" {
  type    = any
  default = {}
}

variable "ai_search_instances" {
  type    = any
  default = []
}

variable "access_contracts" {
  type    = any
  default = []
}

variable "entra_tenant_id" {
  type    = string
  default = ""
}

variable "entra_client_id" {
  type    = string
  default = ""
}

module "ai_hub_gateway" {
  source = "../../"

  environment_name    = var.environment_name
  location            = var.location
  resource_group_name = var.resource_group_name
  name_prefix         = var.name_prefix
  tags                = var.tags

  foundry                              = var.foundry
  foundry_model_deployments            = var.foundry_model_deployments
  primary_foundry_embedding_model_name = var.primary_foundry_embedding_model_name
  foundry_api_key_secret_uri           = var.foundry_api_key_secret_uri

  network              = var.network
  private_dns_zone_ids = var.private_dns_zone_ids

  apim     = var.apim
  features = var.features

  ai_search_instances = var.ai_search_instances
  entra_tenant_id     = var.entra_tenant_id
  entra_client_id     = var.entra_client_id

  access_contracts = var.access_contracts
}

output "apim_gateway_url" { value = module.ai_hub_gateway.apim_gateway_url }
output "key_vault_uri" { value = module.ai_hub_gateway.key_vault_uri }
output "llm_backends" { value = module.ai_hub_gateway.llm_backends }
