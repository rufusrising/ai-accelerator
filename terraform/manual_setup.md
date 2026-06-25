# Manual Setup Guide — AI Hub Gateway

Step-by-step manual procedures for every resource the Terraform modules create.
Use this when you want to provision pieces by hand (portal / az CLI), when you
need to pre-stage shared resources before `terraform apply`, or as a reference
to understand exactly what the modules do under the covers.

All `az` commands assume you have already run:

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
```

For brevity, env vars in code blocks are inputs — replace before running.

---

## Table of contents

1. [Prerequisites & subscription prep](#1-prerequisites--subscription-prep)
2. [Entra ID app registration (entra_client_id)](#2-entra-id-app-registration-entra_client_id)
3. [Resource group](#3-resource-group)
4. [Networking — VNet, subnets, NSGs, route table](#4-networking--vnet-subnets-nsgs-route-table)
5. [Private DNS zones (12 zones + VNet links)](#5-private-dns-zones-12-zones--vnet-links)
6. [User-assigned managed identities (APIM + Logic App)](#6-user-assigned-managed-identities-apim--logic-app)
7. [Log Analytics + Application Insights x 3](#7-log-analytics--application-insights-x-3)
8. [Key Vault (RBAC mode + PE)](#8-key-vault-rbac-mode--pe)
9. [Cosmos DB (5 containers + PE + native data-plane role)](#9-cosmos-db-5-containers--pe--native-data-plane-role)
10. [Event Hub namespace + 2 hubs + consumer groups + PE](#10-event-hub-namespace--2-hubs--consumer-groups--pe)
11. [Azure Managed Redis (Enterprise) + PE](#11-azure-managed-redis-enterprise--pe)
12. [Storage account (4 PEs) + file share](#12-storage-account-4-pes--file-share)
13. [AI Foundry account + project + model deployments + PE](#13-ai-foundry-account--project--model-deployments--pe)
14. [Foundry agent network injection (opt-in)](#14-foundry-agent-network-injection-opt-in)
15. [API Management (StandardV2) + identities + PE](#15-api-management-standardv2--identities--pe)
16. [APIM named values + KV-backed App Insights credentials](#16-apim-named-values--kv-backed-app-insights-credentials)
17. [APIM loggers (App Insights, Azure Monitor, Event Hub)](#17-apim-loggers-app-insights-azure-monitor-event-hub)
18. [APIM Cache (Azure Managed Redis)](#18-apim-cache-azure-managed-redis)
19. [APIM policy fragments (50+)](#19-apim-policy-fragments-50)
20. [APIM AI APIs (OpenAI / Universal LLM / Unified / AI Search / DocIntel / Realtime / MCP)](#20-apim-ai-apis)
21. [LLM backends + multi-backend pools](#21-llm-backends--multi-backend-pools)
22. [Content-safety + embeddings backends](#22-content-safety--embeddings-backends)
23. [API Center + workspaces + environments](#23-api-center--workspaces--environments)
24. [Logic App Standard (usage processor) + VNet integration](#24-logic-app-standard-usage-processor--vnet-integration)
25. [Per-tenant access contracts (products + subs + KV secrets + Foundry connections)](#25-per-tenant-access-contracts)
26. [Cross-cutting RBAC summary](#26-cross-cutting-rbac-summary)
27. [Post-deploy validation](#27-post-deploy-validation)

---

## 1. Prerequisites & subscription prep

**Operator RBAC (the principal running `az` / Terraform):**

- `Owner` on the target subscription/RG, **or**
- `Contributor` + `User Access Administrator` (the module creates many role assignments).

**Tooling:**

```bash
az --version            # >= 2.60
az extension add --name application-insights
az extension add --name apim
az extension add --name apic-extension   # for API Center

# Optional — needed only for terraform path
terraform -version      # >= 1.7
```

**Register resource providers** (idempotent; takes a few minutes):

```bash
for ns in \
  Microsoft.ApiManagement Microsoft.Cache Microsoft.CognitiveServices \
  Microsoft.DocumentDB Microsoft.EventHub Microsoft.Insights \
  Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network \
  Microsoft.OperationalInsights Microsoft.Storage Microsoft.Web \
  Microsoft.ApiCenter Microsoft.App ; do
  az provider register --namespace "$ns" --wait
done
```

**Pick a region** that supports Azure OpenAI + Foundry: `uaenorth`, `southafricanorth`, `westeurope`, `southcentralus`, `australiaeast`, `canadaeast`, `eastus`, `eastus2`, `francecentral`, `japaneast`, `northcentralus`, `swedencentral`, `switzerlandnorth`, `uksouth`.

---

## 2. Entra ID app registration (entra_client_id)

Use the **Entra ID admin portal** (or `az ad app create`) to register an app for the gateway. This is what fills `entra_client_id` in `terraform.tfvars`.

```bash
APP_NAME="aihub-gateway"

APP_JSON=$(az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --identifier-uris "api://$APP_NAME" \
  --required-resource-accesses '[{
      "resourceAppId": "00000003-0000-0000-c000-000000000000",
      "resourceAccess": [{"id":"e1fe6dd8-ba31-4d61-89e7-88639da4683d","type":"Scope"}]
    }]')

ENTRA_CLIENT_ID=$(echo "$APP_JSON" | jq -r '.appId')
ENTRA_OBJECT_ID=$(echo "$APP_JSON" | jq -r '.id')

# Expose an API scope (`api://<appId>/.default` is what APIM JWT policies validate)
az ad app update --id "$ENTRA_OBJECT_ID" \
  --set "api={\"oauth2PermissionScopes\":[{\"id\":\"$(uuidgen)\",\"adminConsentDescription\":\"Access AI Gateway\",\"adminConsentDisplayName\":\"Access AI Gateway\",\"isEnabled\":true,\"type\":\"User\",\"userConsentDescription\":\"Access AI Gateway\",\"userConsentDisplayName\":\"Access AI Gateway\",\"value\":\"access\"}]}"

# Create a service principal for the app
az ad sp create --id "$ENTRA_CLIENT_ID"

# Create a client secret (only required if you use confidential-client flows;
# many gateway scenarios use bearer-token validation only and don't need a secret)
az ad app credential reset --id "$ENTRA_CLIENT_ID" --years 1 --query password -o tsv
```

Pass `ENTRA_CLIENT_ID` and your **tenant ID** (`az account show --query tenantId -o tsv`) to the Terraform module as `entra_client_id` / `entra_tenant_id`. The module derives `audience = "api://${entra_client_id}"` when `entra_audience` is left blank.

---

## 3. Resource group

```bash
LOCATION="swedencentral"
RG="rg-aihub-dev"

az group create --name "$RG" --location "$LOCATION"
```

---

## 4. Networking — VNet, subnets, NSGs, route table

**Attach mode** (root Terraform module): bring your own — skip this section and pass IDs into `var.network`.

**Citadel/greenfield mode**: the module owns these. To create manually:

```bash
VNET=vnet-aihub-dev
ASPC=10.170.0.0/24

# 1. VNet + APIM subnet
az network vnet create -g "$RG" -n "$VNET" --address-prefixes "$ASPC" --location "$LOCATION"

# 2. NSGs (one per subnet). APIM NSG carries the stv2 rules.
az network nsg create -g "$RG" -n nsg-snet-apim
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowPublicAccess \
  --priority 3000 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet --destination-address-prefixes VirtualNetwork \
  --destination-port-ranges 443
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowAPIMManagement \
  --priority 3010 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes ApiManagement --destination-address-prefixes VirtualNetwork \
  --destination-port-ranges 3443
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowAPIMLoadBalancer \
  --priority 3020 --direction Inbound --access Allow --protocol "*" \
  --source-address-prefixes AzureLoadBalancer --destination-address-prefixes VirtualNetwork \
  --destination-port-ranges 6390
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowAzureTrafficManager \
  --priority 3030 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes AzureTrafficManager --destination-address-prefixes VirtualNetwork \
  --destination-port-ranges 443
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowStorage \
  --priority 3000 --direction Outbound --access Allow --protocol Tcp \
  --source-address-prefixes VirtualNetwork --destination-address-prefixes Storage \
  --destination-port-ranges 443
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowKeyVault \
  --priority 3020 --direction Outbound --access Allow --protocol Tcp \
  --source-address-prefixes VirtualNetwork --destination-address-prefixes AzureKeyVault \
  --destination-port-ranges 443
az network nsg rule create -g "$RG" --nsg-name nsg-snet-apim --name AllowMonitor \
  --priority 3030 --direction Outbound --access Allow --protocol Tcp \
  --source-address-prefixes VirtualNetwork --destination-address-prefixes AzureMonitor \
  --destination-port-ranges 1886 443

az network nsg create -g "$RG" -n nsg-snet-pe        # empty (PE subnet has no rules)
az network nsg create -g "$RG" -n nsg-snet-funcapp   # empty
az network nsg create -g "$RG" -n nsg-snet-agents    # empty (only if VNet injection)

# 3. APIM route table (forces APIM management traffic out to Internet)
az network route-table create -g "$RG" -n rt-snet-apim
az network route-table route create -g "$RG" --route-table-name rt-snet-apim \
  --name apim-management --address-prefix ApiManagement --next-hop-type Internet

# 4. Subnets
# 4a. APIM subnet — for StandardV2/PremiumV2 must be delegated to Microsoft.Web/serverFarms
az network vnet subnet create -g "$RG" --vnet-name "$VNET" --name snet-apim \
  --address-prefixes 10.170.0.0/26 \
  --network-security-group nsg-snet-apim \
  --route-table rt-snet-apim \
  --service-endpoints Microsoft.KeyVault Microsoft.Storage Microsoft.EventHub Microsoft.Sql Microsoft.ServiceBus Microsoft.AzureActiveDirectory Microsoft.CognitiveServices \
  --delegations Microsoft.Web/serverFarms

# 4b. Private Endpoint subnet
az network vnet subnet create -g "$RG" --vnet-name "$VNET" --name snet-pe \
  --address-prefixes 10.170.0.64/26 \
  --network-security-group nsg-snet-pe \
  --service-endpoints Microsoft.CognitiveServices \
  --disable-private-endpoint-network-policies true

# 4c. Function App subnet — delegated for the Logic App Standard runtime
az network vnet subnet create -g "$RG" --vnet-name "$VNET" --name snet-funcapp \
  --address-prefixes 10.170.0.128/26 \
  --network-security-group nsg-snet-funcapp \
  --service-endpoints Microsoft.CognitiveServices \
  --delegations Microsoft.Web/serverFarms

# 4d. Agent subnet — only when you enable Foundry network injection
az network vnet subnet create -g "$RG" --vnet-name "$VNET" --name snet-agents \
  --address-prefixes 10.170.0.192/26 \
  --network-security-group nsg-snet-agents \
  --delegations Microsoft.App/environments
```

---

## 5. Private DNS zones (12 zones + VNet links)

Each privatelink service requires a matching `privatelink.*` zone linked to the VNet. The module creates 12 zones; do the same manually:

```bash
ZONES=(
  privatelink.vaultcore.azure.net
  privatelink.documents.azure.com
  privatelink.servicebus.windows.net
  privatelink.blob.core.windows.net
  privatelink.file.core.windows.net
  privatelink.table.core.windows.net
  privatelink.queue.core.windows.net
  privatelink.cognitiveservices.azure.com
  privatelink.openai.azure.com
  privatelink.services.ai.azure.com
  privatelink.azure-api.net
  privatelink.redis.azure.net
)

for z in "${ZONES[@]}"; do
  az network private-dns zone create -g "$RG" -n "$z"
  az network private-dns link vnet create -g "$RG" -n "${z}-link" \
    --zone-name "$z" --virtual-network "$VNET" --registration-enabled false
done

# Optional 13th zone — only if you wire Azure Monitor Private Link Scope
az network private-dns zone create -g "$RG" -n privatelink.monitor.azure.com
az network private-dns link vnet create -g "$RG" -n privatelink.monitor.azure.com-link \
  --zone-name privatelink.monitor.azure.com --virtual-network "$VNET" --registration-enabled false
```

---

## 6. User-assigned managed identities (APIM + Logic App)

```bash
APIM_UAMI=id-apim-aihub
LOGIC_UAMI=id-logicapp-aihub

az identity create -g "$RG" -n "$APIM_UAMI"  -l "$LOCATION"
az identity create -g "$RG" -n "$LOGIC_UAMI" -l "$LOCATION"

# Pull principal IDs / client IDs for later commands
APIM_UAMI_PRINCIPAL=$(az identity show -g "$RG" -n "$APIM_UAMI"  --query principalId -o tsv)
APIM_UAMI_CLIENTID=$(az identity show  -g "$RG" -n "$APIM_UAMI"  --query clientId -o tsv)
APIM_UAMI_ID=$(az identity show        -g "$RG" -n "$APIM_UAMI"  --query id -o tsv)

LOGIC_UAMI_PRINCIPAL=$(az identity show -g "$RG" -n "$LOGIC_UAMI" --query principalId -o tsv)
LOGIC_UAMI_ID=$(az identity show        -g "$RG" -n "$LOGIC_UAMI" --query id -o tsv)
```

Assign RG-scoped roles to the APIM UAMI (mirrors `managed-identity-apim.bicep`):

```bash
RG_ID=$(az group show -n "$RG" --query id -o tsv)

az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal --scope "$RG_ID" --role "Cognitive Services User"
az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal --scope "$RG_ID" --role "Cognitive Services OpenAI User"
az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal --scope "$RG_ID" --role "Azure Event Hubs Data Sender"

# Logic App UAMI gets EH Data Owner + Monitoring Reader at RG scope
az role assignment create --assignee-object-id "$LOGIC_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal --scope "$RG_ID" --role "Azure Event Hubs Data Owner"
az role assignment create --assignee-object-id "$LOGIC_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal --scope "$RG_ID" --role "Monitoring Reader"
```

---

## 7. Log Analytics + Application Insights x 3

```bash
LAW=log-aihub-dev
az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION" \
  --sku PerGB2018 --retention-time 30

LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)

for ai in appi-apim-aihub appi-func-aihub appi-aif-aihub ; do
  az monitor app-insights component create -g "$RG" --app "$ai" --location "$LOCATION" \
    --workspace "$LAW_ID" --kind web --application-type web
done
```

---

## 8. Key Vault (RBAC mode + PE)

```bash
KV=kv-aihub-dev-$RANDOM
az keyvault create -g "$RG" -n "$KV" -l "$LOCATION" \
  --sku standard --enable-rbac-authorization true --enable-purge-protection true \
  --retention-days 90 --public-network-access Disabled \
  --default-action Deny --bypass AzureServices

# Private endpoint + DNS A record
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)
KV_ZONE_ID=$(az network private-dns zone show -g "$RG" -n privatelink.vaultcore.azure.net --query id -o tsv)

az network private-endpoint create -g "$RG" -n pe-kv -l "$LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$KV_ID" --group-id vault \
  --connection-name pe-kv
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name pe-kv --name default \
  --private-dns-zone "$KV_ZONE_ID" --zone-name privatelink.vaultcore.azure.net

# Grant APIM UAMI 'Key Vault Secrets User'
az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID" --role "Key Vault Secrets User"
```

> The **APIM system-assigned identity** is granted the same role AFTER APIM is created (step 15).

---

## 9. Cosmos DB (5 containers + PE + native data-plane role)

```bash
COSMOS=cosmos-aihub-dev-$RANDOM
az cosmosdb create -g "$RG" -n "$COSMOS" --kind GlobalDocumentDB \
  --default-consistency-level Session \
  --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=False \
  --disable-key-based-metadata-write-access true \
  --public-network-access DISABLED

az cosmosdb sql database create -g "$RG" -a "$COSMOS" -n ai-usage-db

for c in \
  "ai-usage-container:/productName" \
  "model-pricing:/model" \
  "streaming-export-config:/type" \
  "pii-usage-container:/type" \
  "llm-usage-container:/productName" ; do
    name=${c%%:*}; key=${c##*:}
    az cosmosdb sql container create -g "$RG" -a "$COSMOS" -d ai-usage-db -n "$name" \
      --partition-key-path "$key" --throughput 400
done

# Private endpoint
COSMOS_ID=$(az cosmosdb show -g "$RG" -n "$COSMOS" --query id -o tsv)
COSMOS_ZONE_ID=$(az network private-dns zone show -g "$RG" -n privatelink.documents.azure.com --query id -o tsv)
az network private-endpoint create -g "$RG" -n pe-cosmos -l "$LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$COSMOS_ID" --group-id Sql --connection-name pe-cosmos
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name pe-cosmos --name default \
  --private-dns-zone "$COSMOS_ZONE_ID" --zone-name privatelink.documents.azure.com

# Native (data-plane) Cosmos DB role for the Logic App UAMI
az cosmosdb sql role assignment create -g "$RG" -a "$COSMOS" \
  --role-definition-id "00000000-0000-0000-0000-000000000002" \
  --principal-id "$LOGIC_UAMI_PRINCIPAL" \
  --scope "$COSMOS_ID"
```

---

## 10. Event Hub namespace + 2 hubs + consumer groups + PE

```bash
EH_NS=evhns-aihub-dev-$RANDOM
az eventhubs namespace create -g "$RG" -n "$EH_NS" -l "$LOCATION" \
  --sku Standard --capacity 1 --enable-auto-inflate true --maximum-throughput-units 20 \
  --enable-kafka false

az eventhubs eventhub create -g "$RG" --namespace-name "$EH_NS" -n ai-usage   --partition-count 4 --message-retention 7
az eventhubs eventhub create -g "$RG" --namespace-name "$EH_NS" -n pii-usage  --partition-count 2 --message-retention 7

# Consumer groups
for eh in ai-usage pii-usage ; do
  az eventhubs eventhub consumer-group create -g "$RG" --namespace-name "$EH_NS" --eventhub-name "$eh" --name '$Default'
  cg=$([ "$eh" = ai-usage ] && echo aiUsageIngestion || echo piiUsageIngestion)
  az eventhubs eventhub consumer-group create -g "$RG" --namespace-name "$EH_NS" --eventhub-name "$eh" --name "$cg"
done

# Private endpoint
EH_ID=$(az eventhubs namespace show -g "$RG" -n "$EH_NS" --query id -o tsv)
EH_ZONE_ID=$(az network private-dns zone show -g "$RG" -n privatelink.servicebus.windows.net --query id -o tsv)
az network private-endpoint create -g "$RG" -n pe-evh -l "$LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$EH_ID" --group-id namespace --connection-name pe-evh
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name pe-evh --name default \
  --private-dns-zone "$EH_ZONE_ID" --zone-name privatelink.servicebus.windows.net
```

---

## 11. Azure Managed Redis (Enterprise) + PE

The accelerator requires the RediSearch module + clientProtocol Encrypted + port 10000.

```bash
REDIS=redis-aihub-dev-$RANDOM

az redisenterprise create -g "$RG" -n "$REDIS" -l "$LOCATION" \
  --sku Balanced_B10 --minimum-tls-version 1.2

az redisenterprise database create -g "$RG" --cluster-name "$REDIS" --name default \
  --client-protocol Encrypted --port 10000 \
  --eviction-policy NoEviction --clustering-policy EnterpriseCluster \
  --modules name=RediSearch

# Private endpoint
REDIS_ID=$(az redisenterprise show -g "$RG" -n "$REDIS" --query id -o tsv)
REDIS_ZONE_ID=$(az network private-dns zone show -g "$RG" -n privatelink.redis.azure.net --query id -o tsv)
az network private-endpoint create -g "$RG" -n pe-redis -l "$LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$REDIS_ID" --group-id redisEnterprise --connection-name pe-redis
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name pe-redis --name default \
  --private-dns-zone "$REDIS_ZONE_ID" --zone-name privatelink.redis.azure.net
```

---

## 12. Storage account (4 PEs) + file share

```bash
STG=staihubdev$RANDOM
az storage account create -g "$RG" -n "$STG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --public-network-access Disabled \
  --default-action Deny --bypass AzureServices

# File share for Workflow Standard plan content
az storage share-rm create --resource-group "$RG" --storage-account "$STG" --name usage-logic-content --quota 100

# Logic App UAMI -> Storage Blob Data Owner
STG_ID=$(az storage account show -g "$RG" -n "$STG" --query id -o tsv)
az role assignment create --assignee-object-id "$LOGIC_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --scope "$STG_ID" --role "Storage Blob Data Owner"

# Four private endpoints
declare -A SUB=( [blob]=blob [file]=file [table]=table [queue]=queue )
for k in "${!SUB[@]}"; do
  ZID=$(az network private-dns zone show -g "$RG" -n "privatelink.${k}.core.windows.net" --query id -o tsv)
  az network private-endpoint create -g "$RG" -n "pe-st-$k" -l "$LOCATION" \
    --vnet-name "$VNET" --subnet snet-pe \
    --private-connection-resource-id "$STG_ID" --group-id "${SUB[$k]}" --connection-name "pe-st-$k"
  az network private-endpoint dns-zone-group create -g "$RG" \
    --endpoint-name "pe-st-$k" --name default \
    --private-dns-zone "$ZID" --zone-name "privatelink.${k}.core.windows.net"
done
```

---

## 13. AI Foundry account + project + model deployments + PE

```bash
FOUNDRY=aif-aihub-swec-01
FOUNDRY_LOCATION="swedencentral"

# Create AI Foundry (Cognitive Services kind=AIServices, allowProjectManagement=true)
az cognitiveservices account create -g "$RG" -n "$FOUNDRY" -l "$FOUNDRY_LOCATION" \
  --kind AIServices --sku S0 \
  --custom-domain "$FOUNDRY" \
  --assign-identity \
  --yes

# Tweak properties not exposed by az: allowProjectManagement, networkAcls
FOUNDRY_ID=$(az cognitiveservices account show -g "$RG" -n "$FOUNDRY" --query id -o tsv)
az resource patch --ids "$FOUNDRY_ID" --api-version 2026-01-15-preview --properties \
  '{"allowProjectManagement":true,"publicNetworkAccess":"Disabled","networkAcls":{"defaultAction":"Deny","bypass":"AzureServices","ipRules":[],"virtualNetworkRules":[]}}'

# Foundry project
az resource create -g "$RG" --resource-type Microsoft.CognitiveServices/accounts/projects \
  --api-version 2025-04-01-preview \
  --name "$FOUNDRY/citadel-governance-project" \
  --properties '{"description":"Citadel Governance Hub default project"}' \
  --location "$FOUNDRY_LOCATION" \
  --is-full-object \
  --properties '{"identity":{"type":"SystemAssigned"},"properties":{"description":"Citadel Governance Hub default project"},"location":"'"$FOUNDRY_LOCATION"'"}'

# Model deployments (batchSize 1 — Cognitive Services rejects concurrent deploys to the same account)
for spec in \
  "gpt-4o-mini:OpenAI:2024-07-18:GlobalStandard:100" \
  "gpt-4o:OpenAI:2024-11-20:GlobalStandard:100" \
  "DeepSeek-R1:DeepSeek:1:GlobalStandard:1" \
  "Phi-4:Microsoft:3:GlobalStandard:1" \
  "text-embedding-3-large:OpenAI:1:GlobalStandard:100" ; do
    IFS=: read -r name pub ver sku cap <<< "$spec"
    az cognitiveservices account deployment create -g "$RG" -n "$FOUNDRY" \
      --deployment-name "$name" \
      --model-name "$name" --model-version "$ver" --model-format "$pub" \
      --sku-name "$sku" --sku-capacity "$cap"
done

# Multi-DNS private endpoint (Foundry needs 3 zones: cognitiveservices + openai + services.ai)
az network private-endpoint create -g "$RG" -n "pe-$FOUNDRY" -l "$FOUNDRY_LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$FOUNDRY_ID" --group-id account --connection-name "pe-$FOUNDRY"

for z in privatelink.cognitiveservices.azure.com privatelink.openai.azure.com privatelink.services.ai.azure.com ; do
  ZID=$(az network private-dns zone show -g "$RG" -n "$z" --query id -o tsv)
  az network private-endpoint dns-zone-group add -g "$RG" \
    --endpoint-name "pe-$FOUNDRY" --name privateDnsZoneGroup \
    --private-dns-zone "$ZID" --zone-name "$z" 2>/dev/null \
  || az network private-endpoint dns-zone-group create -g "$RG" \
       --endpoint-name "pe-$FOUNDRY" --name privateDnsZoneGroup \
       --private-dns-zone "$ZID" --zone-name "$z"
done

# RBAC: APIM UAMI on the Foundry account
az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --scope "$FOUNDRY_ID" --role "Cognitive Services OpenAI User"
az role assignment create --assignee-object-id "$APIM_UAMI_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --scope "$FOUNDRY_ID" --role "Cognitive Services User"

# Optional: deployer gets Azure AI Project Manager (so the project appears in studio)
DEPLOYER_OID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee "$DEPLOYER_OID" \
  --role "eadc314b-1a2d-4efa-be10-5d325db5065e" --scope "$FOUNDRY_ID"

# Diagnostic settings
az monitor diagnostic-settings create --name foundry-diag \
  --resource "$FOUNDRY_ID" --workspace "$LAW_ID" \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

Repeat the section for each additional Foundry region (one per entry in `var.foundry_instances`). The **first** account is the primary — its endpoint is consumed by APIM as the content-safety + PII Language Service backend.

---

## 14. Foundry agent network injection (opt-in)

Only do this **after** completing the full Standard Agent BYO (Storage + AI Search + Cosmos + capabilityHost) — otherwise `aml_aiagentservice` fails to provision.

```bash
AGENT_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" --name snet-agents --query id -o tsv)

az resource patch --ids "$FOUNDRY_ID" --api-version 2026-01-15-preview --properties '{
  "networkInjections":[{
    "scenario":"agent",
    "subnetArmId":"'"$AGENT_SUBNET_ID"'",
    "useMicrosoftManagedNetwork":false
  }]
}'
```

---

## 15. API Management (StandardV2) + identities + PE

```bash
APIM=apim-aihub-dev

az apim create -g "$RG" -n "$APIM" -l "$LOCATION" \
  --sku-name StandardV2 --sku-capacity 1 \
  --publisher-name "AI Hub" --publisher-email "noreply@example.com" \
  --enable-managed-identity true \
  --public-network-access false \
  --virtual-network External \
  --no-wait

# Wait for APIM (15–45 min). Then attach UAMI:
az apim update -g "$RG" -n "$APIM" \
  --set "identity.type=SystemAssigned, UserAssigned" \
        "identity.userAssignedIdentities.$APIM_UAMI_ID={}"

# Pin V2 subnet integration (apim subnet must be delegated to Microsoft.Web/serverFarms)
APIM_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" --name snet-apim --query id -o tsv)
APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)
az resource patch --ids "$APIM_ID" --api-version 2024-05-01 --properties \
  "{\"virtualNetworkType\":\"External\",\"virtualNetworkConfiguration\":{\"subnetResourceId\":\"$APIM_SUBNET_ID\"}}"

# Private endpoint (Gateway subresource) + DNS
APIM_ZONE_ID=$(az network private-dns zone show -g "$RG" -n privatelink.azure-api.net --query id -o tsv)
az network private-endpoint create -g "$RG" -n pe-apim -l "$LOCATION" \
  --vnet-name "$VNET" --subnet snet-pe \
  --private-connection-resource-id "$APIM_ID" --group-id Gateway --connection-name pe-apim
az network private-endpoint dns-zone-group create -g "$RG" \
  --endpoint-name pe-apim --name default \
  --private-dns-zone "$APIM_ZONE_ID" --zone-name privatelink.azure-api.net

# Now grant the APIM SYSTEM-assigned identity Key Vault Secrets User + Certificate User
APIM_SAMI=$(az apim show -g "$RG" -n "$APIM" --query identity.principalId -o tsv)
az role assignment create --assignee-object-id "$APIM_SAMI" --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID" --role "Key Vault Secrets User"
az role assignment create --assignee-object-id "$APIM_SAMI" --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID" --role "Key Vault Certificate User"

# APIM diagnostic settings -> Log Analytics
az monitor diagnostic-settings create --name apimDiagnosticSettings \
  --resource "$APIM_ID" --workspace "$LAW_ID" \
  --logs '[{"categoryGroup":"AllLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
```

---

## 16. APIM named values + KV-backed App Insights credentials

```bash
# Store the App Insights connection string in Key Vault
APIM_AI_CS=$(az monitor app-insights component show -g "$RG" --app appi-apim-aihub --query connectionString -o tsv)
az keyvault secret set --vault-name "$KV" --name apim-appinsights-connection-string --value "$APIM_AI_CS"

# APIM named values (core)
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id uami-client-id  --display-name uami-client-id  --secret true  --value "$APIM_UAMI_CLIENTID"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id entra-auth      --display-name entra-auth                       --value true
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id client-id       --display-name client-id       --secret true  --value "$ENTRA_CLIENT_ID"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id tenant-id       --display-name tenant-id       --secret true  --value "$(az account show --query tenantId -o tsv)"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id audience        --display-name audience        --secret true  --value "api://$ENTRA_CLIENT_ID"

PRIMARY_FOUNDRY_EP="https://$FOUNDRY.cognitiveservices.azure.com/"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id piiServiceUrl         --display-name piiServiceUrl         --value "$PRIMARY_FOUNDRY_EP"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id contentSafetyServiceUrl --display-name contentSafetyServiceUrl --value "$PRIMARY_FOUNDRY_EP"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id piiServiceKey         --display-name piiServiceKey         --secret true --value "replace-if-needed"

# JWT named values
TENANT_ID=$(az account show --query tenantId -o tsv)
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id JWT-TenantId           --display-name JWT-TenantId           --value "$TENANT_ID"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id JWT-AppRegistrationId  --display-name JWT-AppRegistrationId  --value "$ENTRA_CLIENT_ID"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id JWT-Issuer             --display-name JWT-Issuer             --value "https://login.microsoftonline.com/$TENANT_ID/v2.0"
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id JWT-OpenIdConfigUrl    --display-name JWT-OpenIdConfigUrl    --value "https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"

# AWS placeholders (required by set-backend-authorization fragment even if you don't use Bedrock)
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id aws-access-key      --display-name aws-access-key      --secret true  --value NOT_CONFIGURED
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id aws-secret-key      --display-name aws-secret-key      --secret true  --value NOT_CONFIGURED
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id aws-region          --display-name aws-region                       --value NOT_CONFIGURED
az apim nv create -g "$RG" --service-name "$APIM" --named-value-id anthropic-version   --display-name anthropic-version               --value 2023-06-01

# KV-backed App Insights credentials named value (uses the APIM UAMI to fetch the secret)
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/namedValues/appinsights-logger-credentials?api-version=2024-06-01-preview" \
  --body '{
    "properties":{
      "displayName":"appinsights-logger-credentials",
      "secret":true,
      "keyVault":{
        "identityClientId":"'"$APIM_UAMI_CLIENTID"'",
        "secretIdentifier":"https://'"$KV"'.vault.azure.net/secrets/apim-appinsights-connection-string"
      }
    }
  }'
```

---

## 17. APIM loggers (App Insights, Azure Monitor, Event Hub)

```bash
# App Insights logger — credentials.connectionString points at the NV from step 16
APPI_ID=$(az monitor app-insights component show -g "$RG" --app appi-apim-aihub --query id -o tsv)
az apim logger create -g "$RG" --service-name "$APIM" --logger-id appinsights-logger \
  --logger-type applicationInsights --description "App Insights logger" \
  --resource-id "$APPI_ID" \
  --credentials "instrumentationKey={{appinsights-logger-credentials}}"

# Azure Monitor logger (used by inference-api diagnostic blocks)
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/loggers/azuremonitor?api-version=2024-10-01-preview" \
  --body '{"properties":{"loggerType":"azureMonitor","isBuffered":false,"description":"Azure Monitor logger"}}'

# Event Hub loggers — UAMI-based credentials
az apim logger create -g "$RG" --service-name "$APIM" --logger-id usage-eventhub-logger \
  --logger-type azureEventHub --description "Usage events" \
  --credentials "name=ai-usage" \
                "endpointAddress=$EH_NS.servicebus.windows.net" \
                "identityClientId=$APIM_UAMI_CLIENTID"
az apim logger create -g "$RG" --service-name "$APIM" --logger-id pii-usage-eventhub-logger \
  --logger-type azureEventHub --description "PII events" \
  --credentials "name=pii-usage" \
                "endpointAddress=$EH_NS.servicebus.windows.net" \
                "identityClientId=$APIM_UAMI_CLIENTID"
```

---

## 18. APIM Cache (Azure Managed Redis)

```bash
REDIS_HOST=$(az redisenterprise show -g "$RG" -n "$REDIS" --query hostName -o tsv)
REDIS_KEY=$(az redisenterprise database list-keys -g "$RG" --cluster-name "$REDIS" --name default --query primaryKey -o tsv)
REDIS_CS="$REDIS_HOST:10000,password=$REDIS_KEY,ssl=true"

az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/caches/redis-cache?api-version=2024-06-01-preview" \
  --body "{
    \"properties\":{
      \"connectionString\":\"$REDIS_CS\",
      \"useFromLocation\":\"default\",
      \"description\":\"AMR cache for APIM semantic cache\"
    }
  }"
```

---

## 19. APIM policy fragments (50+)

Each XML under `terraform/policies/` becomes a policy fragment. Two fragments need dynamic substitutions before upload:

```bash
POLICIES_DIR=./terraform/policies

# Static fragments
for f in \
  frag-ai-usage.xml frag-raise-throttling-events.xml frag-pii-anonymization.xml \
  frag-pii-deanonymization.xml frag-security-handler.xml frag-strip-backend-headers.xml \
  frag-set-target-backend-pool.xml frag-set-llm-usage.xml frag-set-llm-requested-model.xml \
  frag-validate-model-access.xml frag-responses-id-security.xml frag-responses-id-cache-store.xml \
  frag-set-backend-authorization.xml frag-pii-state-saving.xml frag-ai-foundry-compatibility.xml \
  frag-central-cache-manager.xml frag-request-processor.xml frag-path-builder.xml \
  frag-set-response-headers.xml ; do
    name=${f#frag-}; name=${name%.xml}
    BODY=$(jq -Rs '{properties:{format:"rawxml",description:"Static fragment '"$name"'",value:.}}' < "$POLICIES_DIR/$f")
    az rest --method PUT \
      --uri "https://management.azure.com$APIM_ID/policyFragments/$name?api-version=2024-06-01-preview" \
      --body "$BODY"
done

# frag-resolve-model-alias.xml — strip the {inlineAliasesCode} marker first
RM_XML=$(sed 's|//{inlineAliasesCode}||g' "$POLICIES_DIR/frag-resolve-model-alias.xml")
BODY=$(jq -Rs --arg val "$RM_XML" '{properties:{format:"rawxml",description:"Resolve model alias",value:$val}}' /dev/null)
az rest --method PUT --uri "https://management.azure.com$APIM_ID/policyFragments/resolve-model-alias?api-version=2024-06-01-preview" --body "$BODY"

# frag-set-backend-pools.xml, frag-get-available-models.xml, frag-metadata-config.xml
# are template files containing C# code markers (//{backendPoolsCode}, //{modelDeploymentsCode},
# //{modelsConfigCode}). Replace these with generated code per LLM backend topology BEFORE upload —
# see `terraform/modules/apim_policies/main.tf` for the generation logic.
```

---

## 20. APIM AI APIs

Each API is created via `az rest` (or `az apim api import` for OpenAPI). Repeat the pattern below for each API in `terraform/api-specs/` — adjusting `path` and policy XML.

```bash
# Azure OpenAI API
az apim api import -g "$RG" --service-name "$APIM" --path openai \
  --api-id azure-openai-api --display-name "Azure OpenAI API" \
  --protocols https --specification-format OpenApiJson \
  --specification-path ./terraform/api-specs/AIFoundryOpenAI.json \
  --subscription-required false
az apim api policy create -g "$RG" --service-name "$APIM" --api-id azure-openai-api \
  --policy-format rawxml --value "$(cat $POLICIES_DIR/azure-open-ai-api-policy.xml)"

# Universal LLM API
az apim api import -g "$RG" --service-name "$APIM" --path models \
  --api-id universal-llm-api --display-name "Universal LLM API" \
  --protocols https --specification-format OpenApiJson \
  --specification-path ./terraform/api-specs/AIFoundryOpenAIV1.json \
  --subscription-required false
az apim api policy create -g "$RG" --service-name "$APIM" --api-id universal-llm-api \
  --policy-format rawxml --value "$(cat $POLICIES_DIR/universal-llm-api-policy-v2.xml)"

# Unified AI Wildcard API
az apim api import -g "$RG" --service-name "$APIM" --path unified-ai \
  --api-id unified-ai-api --display-name "Unified AI API" \
  --protocols https --specification-format OpenApiJson \
  --specification-path ./terraform/api-specs/UnifiedAIWildcard.json \
  --subscription-required true
az apim api policy create -g "$RG" --service-name "$APIM" --api-id unified-ai-api \
  --policy-format rawxml --value "$(cat $POLICIES_DIR/unified-ai-api-policy.xml)"
# Unified AI product (subscription-based)
az apim product create -g "$RG" --service-name "$APIM" --product-id unified-ai-product \
  --display-name "Unified AI Gateway" --subscription-required true --approval-required false \
  --subscriptions-limit 10 --state published
az apim product api add -g "$RG" --service-name "$APIM" --product-id unified-ai-product --api-id unified-ai-api

# AI Search Index
az apim api import -g "$RG" --service-name "$APIM" --path search \
  --api-id azure-ai-search-index-api --display-name "Azure AI Search Index API" \
  --protocols https --specification-format OpenApiJson \
  --specification-path ./terraform/api-specs/ai-search-index-2024-07-01-api-spec.json \
  --subscription-required false
az apim api policy create -g "$RG" --service-name "$APIM" --api-id azure-ai-search-index-api \
  --policy-format rawxml --value "$(cat $POLICIES_DIR/ai-search-index-api-policy.xml)"

# Document Intelligence
az apim api import -g "$RG" --service-name "$APIM" --path documentintelligence \
  --api-id document-intelligence-api --display-name "Document Intelligence API" \
  --protocols https --specification-format OpenApi \
  --specification-path ./terraform/api-specs/document-intelligence-2024-11-30-compressed.openapi.yaml \
  --subscription-required false
az apim api policy create -g "$RG" --service-name "$APIM" --api-id document-intelligence-api \
  --policy-format rawxml --value "$(cat $POLICIES_DIR/doc-intelligence-api-policy.xml)"
# Repeat for path=formrecognizer + api-id=document-intelligence-api-legacy

# OpenAI Realtime (WebSocket) — must be created via REST (az apim doesn't support WebSocket API kind)
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/apis/openai-realtime-ws-api?api-version=2024-06-01-preview" \
  --body '{
    "properties":{
      "apiType":"websocket","type":"websocket","protocols":["wss"],
      "displayName":"Azure OpenAI Realtime API","path":"openai/realtime",
      "serviceUrl":"wss://to-be-replaced-by-policy",
      "subscriptionRequired":false,
      "subscriptionKeyParameterNames":{"header":"api-key","query":"api-key"}
    }
  }'

# MCP samples — see `apim_apis/main.tf` for the body shape
```

---

## 21. LLM backends + multi-backend pools

```bash
# Foundry-backed LLM backend (managed-identity auth)
for idx in 0 1 ; do  # adjust to length(foundry_instances)
  FNAME=$([ $idx -eq 0 ] && echo "aif-aihub-swec-01" || echo "aif-aihub-eus2-01")
  BACKEND_ID="${FNAME}-${idx}"
  az rest --method PUT \
    --uri "https://management.azure.com$APIM_ID/backends/$BACKEND_ID?api-version=2024-06-01-preview" \
    --body "{
      \"properties\":{
        \"description\":\"AI Foundry backend $FNAME\",
        \"url\":\"https://$FNAME.cognitiveservices.azure.com/\",
        \"protocol\":\"http\",
        \"credentials\":{
          \"managedIdentity\":{\"clientId\":\"$APIM_UAMI_CLIENTID\",\"resource\":\"https://cognitiveservices.azure.com\"},
          \"header\":{\"x-ms-client-id\":[\"$APIM_UAMI_CLIENTID\"]}
        },
        \"circuitBreaker\":{
          \"rules\":[{
            \"name\":\"$BACKEND_ID-breaker-rule\",\"tripDuration\":\"PT1M\",\"acceptRetryAfter\":true,
            \"failureCondition\":{\"count\":3,\"interval\":\"PT5M\",\"errorReasons\":[\"Server errors\"],
              \"statusCodeRanges\":[{\"min\":429,\"max\":429},{\"min\":500,\"max\":503}]}
          }]
        },
        \"tls\":{\"validateCertificateChain\":true,\"validateCertificateName\":true}
      }
    }"
done

# Multi-backend pool (only when ≥ 2 backends serve the same model)
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/backends/deepseek-r1-ai-foundry-backend-pool?api-version=2024-06-01-preview" \
  --body '{
    "properties":{
      "description":"Backend pool for model DeepSeek-R1",
      "type":"Pool",
      "pool":{
        "services":[
          {"id":"/backends/aif-aihub-swec-01-0","priority":1,"weight":100},
          {"id":"/backends/aif-aihub-eus2-01-1","priority":1,"weight":100}
        ]
      }
    }
  }'
```

For api-key-based backends (Bedrock, Anthropic, etc.) replace `credentials.managedIdentity` with `credentials.header` referencing a named value (`api-key` / `Authorization` / `x-goog-api-key` / `x-api-key`).

---

## 22. Content-safety + embeddings backends

Always created, irrespective of LLM backends:

```bash
# Content Safety backend → primary Foundry, MI auth
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/backends/content-safety-backend?api-version=2024-05-01" \
  --body "{
    \"properties\":{
      \"description\":\"Content Safety Service Backend\",
      \"url\":\"$PRIMARY_FOUNDRY_EP\",
      \"protocol\":\"http\",
      \"credentials\":{
        \"managedIdentity\":{\"clientId\":\"$APIM_UAMI_CLIENTID\",\"resource\":\"https://cognitiveservices.azure.com\"},
        \"header\":{\"x-ms-client-id\":[\"$APIM_UAMI_CLIENTID\"]}
      },
      \"tls\":{\"validateCertificateChain\":true,\"validateCertificateName\":true}
    }
  }"

# Embeddings backend (used by APIM semantic cache)
az rest --method PUT \
  --uri "https://management.azure.com$APIM_ID/backends/foundry-embeddings?api-version=2024-06-01-preview" \
  --body "{
    \"properties\":{
      \"description\":\"AI Foundry embeddings backend\",
      \"url\":\"${PRIMARY_FOUNDRY_EP}openai/deployments/text-embedding-3-large/embeddings\",
      \"protocol\":\"http\",
      \"credentials\":{
        \"managedIdentity\":{\"clientId\":\"$APIM_UAMI_CLIENTID\",\"resource\":\"https://cognitiveservices.azure.com\"},
        \"header\":{\"x-ms-client-id\":[\"$APIM_UAMI_CLIENTID\"]}
      },
      \"tls\":{\"validateCertificateChain\":true,\"validateCertificateName\":true}
    }
  }"
```

---

## 23. API Center + workspaces + environments

```bash
APIC=apic-aihub-dev

az apic create -g "$RG" -n "$APIC" -l "$LOCATION" --sku Free

az rest --method PUT --uri "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.ApiCenter/services/$APIC/workspaces/default?api-version=2024-06-01-preview" \
  --body '{"properties":{"title":"Default workspace","description":"Default workspace"}}'

for env in api-dev api-prod mcp-dev mcp-prod ; do
  KIND=$([[ $env == mcp-* ]] && echo MCP || echo REST)
  TYPE=$([[ $env == *-prod ]] && echo Production || echo Development)
  TITLE=$([[ $env == api-dev ]] && echo "API Development" || \
           [[ $env == api-prod ]] && echo "API Production"  || \
           [[ $env == mcp-dev ]] && echo "MCP Development"  || echo "MCP Production")
  az rest --method PUT \
    --uri "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.ApiCenter/services/$APIC/workspaces/default/environments/$env?api-version=2024-06-01-preview" \
    --body "{\"properties\":{\"title\":\"$TITLE\",\"description\":\"$TITLE\",\"kind\":\"$KIND\",\"server\":{\"managementPortalUri\":[\"https://portal.azure.com/\"],\"type\":\"$TYPE\"}}}"
done
```

To onboard the APIM APIs into API Center after deployment:

```bash
az apic api register -g "$RG" -n "$APIC" --api-location ./terraform/api-specs/AIFoundryOpenAI.json
# repeat per spec
```

---

## 24. Logic App Standard (usage processor) + VNet integration

```bash
PLAN=asp-logic-usage-aihub
LOGIC=logic-usage-aihub

# Workflow Standard plan (kind=elastic, WS1)
az functionapp plan create -g "$RG" -n "$PLAN" -l "$LOCATION" \
  --sku WS1 --min-instances 1 --max-burst 20 --elastic-scale true

# Logic App Standard
FUNC_SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" --name snet-funcapp --query id -o tsv)
STG_CS=$(az storage account show-connection-string -g "$RG" -n "$STG" --query connectionString -o tsv)

az logicapp create -g "$RG" -n "$LOGIC" --plan "$PLAN" --storage-account "$STG" \
  --functions-version 4 --runtime node --runtime-version 24 \
  --assign-identity "$LOGIC_UAMI_ID" "[system]" \
  --subnet "$FUNC_SUBNET_ID"

# App settings (wire up Cosmos / EH / App Insights)
APIM_AI_CS_FUNC=$(az monitor app-insights component show -g "$RG" --app appi-func-aihub --query connectionString -o tsv)
az logicapp config appsettings set -g "$RG" -n "$LOGIC" --settings \
  APPLICATIONINSIGHTS_CONNECTION_STRING="$APIM_AI_CS_FUNC" \
  FUNCTIONS_EXTENSION_VERSION=~4 \
  FUNCTIONS_WORKER_RUNTIME=node \
  WEBSITE_NODE_DEFAULT_VERSION=~24 \
  WEBSITE_CONTENTSHARE=usage-logic-content \
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING="$STG_CS" \
  WEBSITE_VNET_ROUTE_ALL=0 \
  WEBSITE_CONTENTOVERVNET=1 \
  APP_KIND=workflowapp \
  AzureFunctionsJobHost__extensionBundle=Microsoft.Azure.Functions.ExtensionBundle.Workflows \
  eventHub_fullyQualifiedNamespace="$EH_NS.servicebus.windows.net" \
  eventHub_name=ai-usage eventHub_pii_name=pii-usage \
  CosmosDBAccount="$COSMOS" CosmosDBDatabase=ai-usage-db \
  CosmosDBContainerConfig=streaming-export-config CosmosDBContainerUsage=ai-usage-container \
  CosmosDBContainerPII=pii-usage-container CosmosDBContainerLLMUsage=llm-usage-container \
  AppInsights_ResourceGroup="$RG" AppInsights_Name=appi-apim-aihub
```

After creating the Logic App, deploy the workflow JSON files (not in scope for this guide — see the upstream Logic App workflow exports).

---

## 25. Per-tenant access contracts

Per business unit / use case, create one product per service code with its API links, policy, subscription, and KV secrets:

```bash
BU=HR; UC=InternalAssistant; ENV=DEV
POSTFIX=$BU-$UC-$ENV
CODE=OAI
PRODUCT_ID=$CODE-$POSTFIX
SUB_ID=$PRODUCT_ID-SUB-01

# Product
az apim product create -g "$RG" --service-name "$APIM" --product-id "$PRODUCT_ID" \
  --display-name "$CODE $BU $UC $ENV" --description "AI Gateway product for $CODE - $UC" \
  --subscription-required true --approval-required false --subscriptions-limit 10 --state published

# Product policy (rate-limit + subscription-key check; replace XML as needed)
az apim product policy create -g "$RG" --service-name "$APIM" --product-id "$PRODUCT_ID" \
  --policy-format rawxml --value '<policies><inbound><base /><rate-limit calls="60" renewal-period="60"/></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

# Link APIs
az apim product api add -g "$RG" --service-name "$APIM" --product-id "$PRODUCT_ID" --api-id azure-openai-api

# Subscription
az apim subscription create -g "$RG" --service-name "$APIM" --subscription-id "$SUB_ID" \
  --display-name "$SUB_ID" --scope "/products/$PRODUCT_ID" --state active

# Store endpoint + key in KV (lowercased, underscores -> hyphens)
PRIM_KEY=$(az apim subscription show -g "$RG" --service-name "$APIM" --sid "$SUB_ID" --query primaryKey -o tsv)
APIM_GW_URL=$(az apim show -g "$RG" -n "$APIM" --query gatewayUrl -o tsv)
API_PATH=$(az apim api show -g "$RG" --service-name "$APIM" --api-id azure-openai-api --query path -o tsv)
az keyvault secret set --vault-name "$KV" --name "${CODE,,}-endpoint" --value "$APIM_GW_URL/$API_PATH"
az keyvault secret set --vault-name "$KV" --name "${CODE,,}-key"      --value "$PRIM_KEY"

# Optional Foundry connection on the project so Foundry agents reach the gateway
az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY/projects/citadel-governance-project/connections/Hub-$POSTFIX-$CODE?api-version=2025-04-01-preview" \
  --body "{
    \"properties\":{
      \"category\":\"ApiManagement\",
      \"target\":\"$APIM_GW_URL/$API_PATH\",
      \"authType\":\"ApiKey\",
      \"isSharedToAll\":false,
      \"credentials\":{\"key\":\"$PRIM_KEY\"},
      \"metadata\":{\"deploymentInPath\":\"false\"}
    }
  }"
```

---

## 26. Cross-cutting RBAC summary

| Principal | Scope | Role | Why |
|---|---|---|---|
| Operator / CI | RG | `Owner` or `Contributor` + `User Access Administrator` | Module creates many role assignments. |
| APIM UAMI | RG | `Cognitive Services User` | Foundry data-plane fallback |
| APIM UAMI | RG | `Cognitive Services OpenAI User` | OpenAI scope |
| APIM UAMI | RG | `Azure Event Hubs Data Sender` | APIM EH usage loggers |
| APIM UAMI | KV | `Key Vault Secrets User` | Resolve KV-backed named values |
| APIM UAMI | each Foundry account | `Cognitive Services OpenAI User` + `Cognitive Services User` | Backend MI auth to Foundry |
| APIM SAMI | KV | `Key Vault Secrets User` + `Key Vault Certificate User` | Resolve KV-backed APIM resources |
| Logic App UAMI | RG | `Azure Event Hubs Data Owner` + `Monitoring Reader` | Read EH events, query App Insights |
| Logic App UAMI | Storage account | `Storage Blob Data Owner` | Workflow runtime |
| Logic App UAMI | Cosmos account | `Cosmos DB Built-in Data Contributor` (id `00000000-0000-0000-0000-000000000002`) | Write usage records |
| Logic App SAMI | RG | same as UAMI roles for EH + Monitoring | The Bicep grants these to SAMI too; mirror with role assignments |
| Deployer | each Foundry account | `Azure AI Project Manager` (id `eadc314b-1a2d-4efa-be10-5d325db5065e`) | So the project shows in Foundry studio |

---

## 27. Post-deploy validation

```bash
# APIM gateway reachable?
APIM_GW=$(az apim show -g "$RG" -n "$APIM" --query gatewayUrl -o tsv)
curl -i "$APIM_GW/status-0123456789abcdef"   # APIM ping endpoint

# Foundry PE DNS resolves to private IP from within the VNet
nslookup "$FOUNDRY.cognitiveservices.azure.com"

# APIM → Foundry through Azure OpenAI API (subscription key path)
PRIM_KEY=$(az apim subscription show -g "$RG" --service-name "$APIM" --sid OAI-HR-InternalAssistant-DEV-SUB-01 --query primaryKey -o tsv)
curl "$APIM_GW/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21" \
  -H "api-key: $PRIM_KEY" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}],"max_tokens":50}'

# Usage events flowing into Event Hub
az eventhubs eventhub show -g "$RG" --namespace-name "$EH_NS" -n ai-usage --query messageRetentionInDays

# Cosmos usage container has documents
az cosmosdb sql container throughput show -g "$RG" -a "$COSMOS" -d ai-usage-db -n ai-usage-container
```

---

## Mapping back to the Terraform module

| Section above | Terraform submodule |
|---|---|
| 4–5 | `modules/networking_full` (citadel) — attach mode skips |
| 6 | Inline in `main.tf` (azurerm_user_assigned_identity + role assignments) |
| 7 | `modules/monitoring` |
| 8 | `modules/keyvault` |
| 9 | `modules/cosmosdb` + inline azapi role assignment |
| 10 | `modules/eventhub` |
| 11 | `modules/redis` |
| 12 | `modules/logicapp_usage` (storage half) |
| 13–14 | `modules/foundry_full` (citadel) or `modules/foundry_integration` (attach) |
| 15–18 | `modules/apim_core` |
| 19 | `modules/apim_policies` |
| 20–22 | `modules/apim_apis` |
| 23 | `modules/apic` |
| 24 | `modules/logicapp_usage` |
| 25 | `modules/products` |
