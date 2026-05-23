targetScope = 'subscription'

// ---------- azd built-in parameters ----------

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Set automatically by azd from `azd env new`; used to derive resource names and as the value of the required `azd-env-name` tag.')
param environmentName string

@minLength(1)
@description('Azure region into which all resources are deployed (for example, `westeurope`, `eastus2`). azd shows a region picker on first deployment.')
@metadata({ azd: { type: 'location' } })
param location string

// ---------- User-prompted parameters ----------

@minLength(3)
@maxLength(64)
@description('Display name shown for the workspace in Azure Machine Learning Studio. Free text, e.g. `Fraud Detection Workspace`.')
param workspaceFriendlyName string

@description('Free-text description of the workspace and what it is used for. Visible in the Azure portal and Studio.')
param workspaceDescription string

@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
])
@description('Redundancy tier for the workspace storage account. LRS = lowest cost, single region; GRS = geo-redundant; ZRS = zone-redundant within a region.')
param storageSkuName string

@allowed([
  'standard'
  'premium'
])
@description('Key Vault SKU. `standard` is software-protected keys; `premium` adds HSM-backed keys (higher cost).')
param keyVaultSkuName string

@description('Whether to also deploy an Azure Container Registry alongside the workspace. Required only if you plan to build and publish custom training environment images.')
param deployContainerRegistry bool

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
@description('Azure Container Registry SKU. Only used when `deployContainerRegistry` is true. `Premium` is required for VNet integration and geo-replication.')
param containerRegistrySku string

@description('Mark the workspace as High Business Impact. Reduces diagnostic data collected by the service and strengthens encryption at rest. Cannot be changed after creation.')
param hbiWorkspace bool

@allowed([
  'Enabled'
  'Disabled'
])
@description('Whether the workspace endpoint is reachable from the public internet. Choose `Disabled` if you plan to use private endpoints only.')
param publicNetworkAccess string

@minLength(1)
@description('Value applied to the `Owner` tag on every deployed resource (for cost allocation and governance). Typically an email address or team name.')
param ownerTag string

// ---------- Derived names & tags ----------

var resourceSuffix = take(uniqueString(subscription().id, environmentName, location), 6)

var tags = {
  'azd-env-name': environmentName
  Owner: ownerTag
}

var resourceGroupName = 'rg-${environmentName}'

// ---------- Deployment ----------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources './modules/resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    resourceSuffix: resourceSuffix
    workspaceFriendlyName: workspaceFriendlyName
    workspaceDescription: workspaceDescription
    storageSkuName: storageSkuName
    keyVaultSkuName: keyVaultSkuName
    deployContainerRegistry: deployContainerRegistry
    containerRegistrySku: containerRegistrySku
    hbiWorkspace: hbiWorkspace
    publicNetworkAccess: publicNetworkAccess
  }
}

// ---------- Outputs (UPPERCASE → captured by azd as env vars) ----------

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZUREML_WORKSPACE_NAME string = resources.outputs.workspaceName
output AZUREML_WORKSPACE_ID string = resources.outputs.workspaceId
output AZURE_KEY_VAULT_NAME string = resources.outputs.keyVaultName
output AZURE_STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.containerRegistryEndpoint
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = resources.outputs.logAnalyticsWorkspaceId
