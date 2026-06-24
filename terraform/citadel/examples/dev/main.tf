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

variable "subscription_id" { type = string }
variable "environment_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
variable "name_prefix" { type = string }
variable "deployer_object_id" {
  type    = string
  default = ""
}

variable "foundry_instances" {
  type = any
}

variable "foundry_model_deployments" {
  type    = any
  default = []
}

variable "primary_foundry_embedding_model_name" {
  type    = string
  default = "text-embedding-3-large"
}

variable "network" {
  type    = any
  default = {}
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

module "citadel" {
  source = "../../"

  environment_name    = var.environment_name
  location            = var.location
  resource_group_name = var.resource_group_name
  name_prefix         = var.name_prefix
  tags                = var.tags
  deployer_object_id  = var.deployer_object_id

  foundry_instances                    = var.foundry_instances
  foundry_model_deployments            = var.foundry_model_deployments
  primary_foundry_embedding_model_name = var.primary_foundry_embedding_model_name

  network  = var.network
  apim     = var.apim
  features = var.features

  ai_search_instances = var.ai_search_instances
  entra_tenant_id     = var.entra_tenant_id
  entra_client_id     = var.entra_client_id

  access_contracts = var.access_contracts
}

output "apim_gateway_url" { value = module.citadel.apim_gateway_url }
output "key_vault_uri"    { value = module.citadel.key_vault_uri }
output "vnet_id"          { value = module.citadel.vnet_id }
output "foundry_accounts" { value = module.citadel.foundry_accounts }
output "foundry_projects" { value = module.citadel.foundry_projects }
output "llm_backends"     { value = module.citadel.llm_backends }
