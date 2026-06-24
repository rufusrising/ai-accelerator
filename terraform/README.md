# AI Hub Gateway — Terraform Module

Attaches the AI Hub Gateway accelerator (originally shipped as Bicep) on top of
your **existing** Azure AI Foundry account(s), **existing** VNet, and **existing**
Private DNS zones. Provisions APIM (StandardV2 by default), the AI Gateway
policy fragments, LLM backends + pools, the usage telemetry pipeline (Cosmos +
Event Hub + Logic App), Azure Managed Redis for semantic cache, API Center,
Key Vault, and per-tenant access contracts (products + subscriptions + optional
Foundry connections).

> **Design choices baked in**
>
> 1. **Managed identity end-to-end**. APIM runs with both SystemAssigned and a
>    UserAssigned identity. The UAMI is granted `Cognitive Services User`,
>    `Cognitive Services OpenAI User`, `Azure Event Hubs Data Sender` at the RG
>    scope and `Cognitive Services User` / `Cognitive Services OpenAI User` on
>    each Foundry account. The Logic App UAMI gets `Cosmos DB Built-in Data
>    Contributor` (native), `Azure Event Hubs Data Owner`, `Monitoring Reader`,
>    and `Storage Blob Data Owner` on the usage storage account.
> 2. **APIM → Foundry uses the APIM user-assigned managed identity**. Every
>    auto-generated Foundry LLM backend is created with
>    `credentials.managedIdentity = { clientId = <UAMI>, resource = https://cognitiveservices.azure.com }`.
>    APIM acquires the AAD token natively at the backend layer on every request;
>    no API keys, no named-value plumbing, no policy-side auth headers. Same MI
>    is reused by the **content-safety** and **PII / Language Service** backends
>    (also Foundry endpoints).
> 3. **No Foundry API keys in the module**. The KV-backed secret pattern is
>    retained only for EXTRA non-Foundry LLM backends you may add via
>    `var.llm_backends` (Bedrock api-key, Anthropic x-api-key, etc.).

---

## Repository layout

```
terraform/
├── main.tf                 # Root composition
├── variables.tf            # Inputs (foundry, network, dns, features, ...)
├── outputs.tf              # APIM URL, KV, Cosmos, EH, Redis, etc.
├── locals.tf               # Naming, LLM backend + pool derivation
├── versions.tf             # Provider pins (azurerm 4.x + azapi 2.x)
├── policies/               # 50+ APIM policy XMLs (copied verbatim from Bicep)
├── api-specs/              # OpenAPI specs for Azure OpenAI / Universal LLM /
│                           # Unified AI / AI Search / Doc Intelligence
└── modules/
    ├── monitoring/         # Log Analytics + 3 x Application Insights
    ├── keyvault/           # RBAC-mode KV + PE + APIM UAMI Secrets User
    ├── cosmosdb/           # Cosmos SQL + 5 containers + PE
    ├── eventhub/           # Event Hub namespace + 2 hubs + PE
    ├── redis/              # Azure Managed Redis (Enterprise) + PE
    ├── logicapp_usage/     # Storage + Workflow Standard plan + Logic App
    ├── foundry_integration/# Reference existing Foundry + model deployments + RBAC
    ├── apim_core/          # APIM StandardV2 + identities + named values + logger
    ├── apim_policies/      # All policy fragments (50+) + dynamic substitutions
    ├── apim_apis/          # Azure OpenAI / Universal / Unified / AI Search / DocIntel
    │                       # + LLM backends + multi-backend pools
    ├── apic/               # API Center + workspace + environments
    └── products/           # Citadel access contracts (products + subs + KV + Foundry conn)
```

---

## Architecture — ASCII connectivity diagram

```
                                        ┌──────────────────────────────────┐
                                        │   YOUR EXISTING AZURE FOUNDRY    │
                                        │  (Cognitive Services account +   │
                                        │   project; pre-existing)         │
                                        │                                  │
                                        │  ┌──────────┐    ┌─────────────┐ │
                                        │  │ Models   │    │ Content     │ │
                                        │  │ (added   │    │ Safety + PII│ │
                                        │  │  by TF)  │    │ APIs        │ │
                                        │  └────┬─────┘    └──────┬──────┘ │
                                        └───────┼──────────────────┼───────┘
                                  Managed Identity                Managed Identity
                                       (APIM UAMI)                    (APIM UAMI)
                                                ▼                  ▼
   client app                  ┌──────────────────────────────────────────┐
   (uses              HTTPS    │              APIM StandardV2             │
   subscription      ─────────▶│                                          │
   key OR JWT)                 │  ┌────────────────────────────────────┐  │
                               │  │  AI Gateway policy fragments       │  │
                               │  │  • security-handler / pii-anon     │  │
                               │  │  • set-backend-pools (dynamic)     │  │
                               │  │  • request-processor / path-builder│  │
                               │  │  • get-available-models (dynamic)  │  │
                               │  │  • metadata-config (per-model)     │  │
                               │  │  • strip-backend-headers           │  │
                               │  │  • responses-id-security/cache     │  │
                               │  │  • set-llm-usage / ai-usage        │  │
                               │  └────────────────────────────────────┘  │
                               │                                          │
                               │  APIs:                                   │
                               │   • azure-openai-api  (/openai)          │
                               │   • universal-llm-api (/models)          │
                               │   • unified-ai-api    (/unified-ai)      │
                               │   • azure-ai-search-index-api (/search)  │
                               │   • document-intelligence (+legacy)      │
                               │   • openai-realtime-ws (WebSocket)       │
                               │   • weather-api + MCP samples            │
                               │                                          │
                               │  SystemAssigned + UserAssigned MIs       │
                               └──┬──────────┬─────────┬───────────────────┘
                                  │          │         │
                            UAMI  │   UAMI   │   SAMI  │
                          (logger) │ (eh data)│ (kv sec)│
                                   ▼          ▼         ▼
                  ┌────────────────────┐ ┌──────────────┐ ┌──────────────┐
                  │ Application        │ │ Event Hub    │ │ Key Vault    │
                  │ Insights x3        │ │  ai-usage    │ │  Secrets:    │
                  │ + Log Analytics    │ │  pii-usage   │ │  appi-conn   │
                  │ (existing or       │ │              │ │  product-*-* │
                  │  module-created)   │ │ (PE)         │ │              │
                  └────────────────────┘ └─────┬────────┘ └──────────────┘
                                               │
                                               │ EH Trigger (UAMI)
                                               ▼
                                ┌──────────────────────────────┐
                                │  Logic App Standard          │
                                │  (Workflow Standard plan,    │
                                │   VNet-integrated, UAMI)     │
                                │                              │
                                │  Storage Account (4 PEs:     │
                                │   blob/file/table/queue)     │
                                └──────────────┬───────────────┘
                                  Cosmos UAMI │
                                               ▼
                                ┌────────────────────────────┐
                                │  Cosmos DB (SQL API)       │
                                │  containers:               │
                                │   • ai-usage-container     │
                                │   • pii-usage-container    │
                                │   • llm-usage-container    │
                                │   • model-pricing          │
                                │   • streaming-export-config│
                                │  (PE)                      │
                                └────────────────────────────┘

                                ┌────────────────────────────┐
                                │  Azure Managed Redis       │
                                │  (Enterprise, RediSearch,  │
                                │   port 10000, PE)          │
                                │  ← APIM Cache "redis-cache"│
                                └────────────────────────────┘

                                ┌────────────────────────────┐
                                │  API Center                │
                                │  + workspaces + env (REST/MCP)│
                                └────────────────────────────┘

  ─── BYO INPUTS (you supply existing IDs) ──────────────────────────────────
  • VNet                        var.network.vnet_id
  • APIM subnet                 var.network.apim_subnet_id
  • Private endpoint subnet     var.network.private_endpoint_subnet_id
  • Function app subnet         var.network.function_app_subnet_id
  • Private DNS zones (12)      var.private_dns_zone_ids.* (must be linked
                                  to var.network.vnet_id)
  • Existing Foundry accounts   var.foundry[*].account_name
  • APIM UAMI must hold         Cognitive Services OpenAI User on each Foundry
    (granted automatically by the foundry_integration submodule)
```

---

## Quick start

```bash
cd terraform/examples/dev
cp terraform.tfvars.example terraform.tfvars
# fill in subscription_id, foundry, network, private_dns_zone_ids
terraform init
terraform plan
terraform apply
```

You will need:

* The 12 Private DNS zones below already created **and linked to the VNet you pass**:
  * `privatelink.vaultcore.azure.net`
  * `privatelink.documents.azure.com`
  * `privatelink.servicebus.windows.net`
  * `privatelink.blob.core.windows.net`
  * `privatelink.file.core.windows.net`
  * `privatelink.table.core.windows.net`
  * `privatelink.queue.core.windows.net`
  * `privatelink.cognitiveservices.azure.com`
  * `privatelink.openai.azure.com`
  * `privatelink.services.ai.azure.com`
  * `privatelink.azure-api.net`
  * `privatelink.redis.azure.net`
* A Key Vault secret (in any KV reachable from the APIM UAMI) populated with your
  Foundry API key, and its URI exported as `foundry_api_key_secret_uri`. APIM will
  reference it via a named value resolved at runtime.
* RBAC: the principal running Terraform needs `Owner` (or `Contributor + User
  Access Administrator`) on the target resource group — many resources here
  create role assignments.

---

## How APIM authenticates to Foundry (deep dive)

Each auto-generated Foundry-backed APIM backend is created with
`credentials.managedIdentity` referencing the APIM user-assigned managed identity:

```hcl
credentials = {
  managedIdentity = {
    clientId = <APIM UAMI clientId>
    resource = "https://cognitiveservices.azure.com"
  }
  header = {
    "x-ms-client-id" = [<APIM UAMI clientId>]
  }
}
```

APIM acquires an AAD access token for `https://cognitiveservices.azure.com/.default`
on every backend invocation (the access token is cached per the standard MSAL
TTL). The UAMI is granted `Cognitive Services OpenAI User` + `Cognitive Services
User` on each Foundry account by the `foundry_integration` submodule, so the
token authorizes immediately.

**Why UAMI and not SAMI?** APIM also has a SystemAssigned MI (used for KV
named-value resolution and certificate fetches), but the UAMI is preferred for
data-plane LLM calls because it survives APIM service recreation — its principal
ID is stable across `terraform destroy`/`apply` of just the APIM resource.

**Flipping a single backend to api-key** (e.g. for a Foundry instance in a
subscription where you can't grant the MI role): pass a same-`backend_id` entry
in `var.llm_backends` with `auth_type = "api-key-header"` and a KV secret URI.
That entry overrides the derived MI default because user-supplied backends are
concatenated after the auto-derived list.

---

## Validating

```bash
cd terraform
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

If the OpenAPI specs evolve in the Bicep accelerator, refresh the copies in
`terraform/api-specs/` and `terraform/policies/`. They are static artifacts the
module reads with `file()`.

---

## Trade-offs / known gaps

* **No standalone networking submodule.** BYO model means VNet, subnets, NSGs,
  route tables, DNS zones, and zone-to-VNet links must be created out-of-band.
  If you want a greenfield variant, switch by setting `useExistingVnet = false`
  in your wrapper and adding the appropriate `azurerm_virtual_network` /
  `azurerm_private_dns_zone` resources alongside this module — they are not
  shipped here because production hub-spoke setups should own them centrally.
* **Foundry agent network injection** is intentionally NOT enabled. The Bicep
  accelerator flags this as incompatible with the gateway-mode Foundry attach
  because the agent capability host (aml_aiagentservice) requires a BYO
  Standard Agent setup (Storage + AI Search + Cosmos + capabilityHost). Enable
  it only after that wiring is in place.
* **API Center API onboarding** (registering each APIM API into APIC) is not
  performed because the Bicep version uses scripts; run `az apic api register`
  after deployment if you want full APIC catalog coverage.
* **APIM Cache entity (`redis-cache`)** requires the runtime connection string,
  which the Redis submodule emits as a sensitive output. The connection string
  embeds the access key (Azure Managed Redis private endpoint design); this is
  identical to the Bicep behaviour.
