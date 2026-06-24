# Citadel — Full Greenfield AI Hub Gateway

A self-contained Terraform module that deploys the AI Hub Gateway accelerator
end-to-end — VNet, subnets (including the agent subnet for Foundry network
injection), all 12 Private DNS zones, the AI Foundry account(s) + projects,
APIM gateway + policies, LLM backends + pools, the usage telemetry pipeline,
Azure Managed Redis, API Center, Key Vault, and per-tenant access contracts.

Sibling module: the top-level `terraform/` module *attaches* the accelerator
to an existing Foundry + VNet + DNS estate. Pick one:

| Need | Use |
|---|---|
| Brownfield: existing Foundry, existing hub VNet, existing DNS | `terraform/` (attach mode) |
| Greenfield: provision everything in one apply | `terraform/citadel/` (this module) |

The two share the same `terraform/modules/*` building blocks (APIM core,
APIM APIs, APIM policy fragments, Cosmos, Event Hub, Redis, KV, Logic App,
API Center, products). Only the *network* and *Foundry* layers differ.

---

## What this module owns

```
                          ┌─────────────────────────────────────────────────┐
                          │       Resource Group (you create up front)      │
                          │                                                 │
   ┌──────────┐           │  ┌────────────────────────────────────────────┐ │
   │  Caller  │  HTTPS    │  │  VNet  10.170.0.0/24                       │ │
   │  (app /  │ ────────▶ │  │  ┌──────────────┬──────────────┐           │ │
   │  agent)  │           │  │  │ snet-apim    │ snet-pe      │           │ │
   └──────────┘           │  │  │ /26  (PE )   │ /26          │           │ │
                          │  │  │ delegated     │              │           │ │
                          │  │  │ Web/serverFar │              │           │ │
                          │  │  └──────┬────────┴──────┬───────┘           │ │
                          │  │         │               │                   │ │
                          │  │  ┌──────▼───────┐ ┌─────▼─────────┐         │ │
                          │  │  │ snet-funcapp │ │ snet-agents   │         │ │
                          │  │  │ /26 deleg.   │ │ /26 deleg.    │         │ │
                          │  │  │ Web/serverFar│ │ App/envs (opt)│         │ │
                          │  │  └──────────────┘ └───────────────┘         │ │
                          │  │  + NSGs + APIM route-table                  │ │
                          │  │  + 12 Private DNS zones (zone-VNet links)   │ │
                          │  └────────────────────────────────────────────┘ │
                          │                                                 │
                          │  ┌────────────────────────────────────────────┐ │
                          │  │  AI Foundry (Cognitive Services AIServices)│ │
                          │  │  • account(s) — module-created             │ │
                          │  │  • project — citadel-governance-project    │ │
                          │  │  • model deployments per foundry_index     │ │
                          │  │  • PE multi-DNS (3 zones)                  │ │
                          │  │  • OPTIONAL: networkInjections.scenario=   │ │
                          │  │    "agent" → snet-agents (delegated to     │ │
                          │  │    Microsoft.App/environments)             │ │
                          │  └────────────────────────────────────────────┘ │
                          │                                                 │
                          │  ┌────────────────────────────────────────────┐ │
                          │  │  APIM StandardV2 + AI Gateway policies     │ │
                          │  │  (uses APIM UAMI to call Foundry)          │ │
                          │  └────────────────────────────────────────────┘ │
                          │                                                 │
                          │  ┌────────────────────────────────────────────┐ │
                          │  │  KV │ Cosmos │ EventHub │ Redis │ Logic App│ │
                          │  │  + Storage Account (4 PEs) │ API Center    │ │
                          │  └────────────────────────────────────────────┘ │
                          └─────────────────────────────────────────────────┘
```

---

## Foundry network injection (opt-in)

This module mirrors the upstream Bicep module's `foundryNetworkInjectionEnabled`
flag via `features.enable_foundry_network_injection`. When true:

* The networking submodule provisions a fourth subnet, `snet-agents`, delegated
  to `Microsoft.App/environments`.
* Per-instance `network_injection_enabled` in `var.foundry_instances` opts each
  Foundry account into being attached to that subnet. The Foundry account body
  receives `networkInjections.scenario = "agent"` pointing at the subnet ARM ID.

**Caveat (carried over verbatim from the Bicep accelerator):** VNet injection
is only supported as part of the **full Foundry Standard Agent BYO setup** —
that requires you to bring your own Azure Storage + Azure AI Search + Azure
Cosmos DB AND declare an explicit `capabilityHost` on the project. Without that
wiring, the agent capability host (`aml_aiagentservice`) fails with
`Invalid vnet resource ID provided, or the virtual network could not be found`.

So: leave `enable_foundry_network_injection = false` for first deploy; turn it
on later once the Standard Agent BYO setup is in place.

---

## How APIM authenticates to Foundry

Identical to the attach-mode module: the APIM **user-assigned managed identity**
is granted `Cognitive Services OpenAI User` + `Cognitive Services User` on every
Foundry account scope (by `module.foundry`). Each Foundry-backed APIM backend
is created with `credentials.managedIdentity = { clientId = <APIM UAMI>, resource = https://cognitiveservices.azure.com }`,
so token acquisition is native at the backend layer. No API keys, no named
values, no policy-side headers.

---

## Quick start

```bash
cd terraform/citadel/examples/dev
cp terraform.tfvars.example terraform.tfvars
# fill in subscription_id, foundry_instances (names + regions), entra IDs
terraform init
terraform plan
terraform apply
```

You need an empty resource group already in place (`resource_group_name`). The
operator running Terraform needs `Owner` or `Contributor + User Access
Administrator` on it — many resources here create RBAC assignments.

---

## Inputs vs upstream Bicep main.bicepparam

| Bicep param | Terraform input |
|---|---|
| `environmentName` | `environment_name` |
| `location` | `location` |
| `vnetAddressPrefix` / `apimSubnetPrefix` / etc. | `network.*` (defaults match) |
| `aiFoundryInstances` | `foundry_instances` |
| `aiFoundryModelsConfig` | `foundry_model_deployments` |
| `foundryNetworkInjectionEnabled` | `features.enable_foundry_network_injection` |
| `enableManagedRedis` | `features.enable_managed_redis` |
| `enableAIGatewayPiiRedaction` | `features.enable_pii_redaction` |
| `enableUnifiedAiApi` | `features.enable_unified_ai_api` |
| `enableAPICenter` | `features.enable_api_center` |
| `apimSku` | `apim.sku_name` |
| `entraTenantId` / `entraClientId` | `entra_tenant_id` / `entra_client_id` |
| (citadel-access-contracts/main.bicep) | `access_contracts` |
