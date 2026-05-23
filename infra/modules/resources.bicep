targetScope = 'resourceGroup'

// ---------- Parameters from main.bicep ----------

param location string
param tags object
param environmentName string
param resourceSuffix string

param workspaceFriendlyName string
param workspaceDescription string
param storageSkuName string
param keyVaultSkuName string
param deployContainerRegistry bool
param containerRegistrySku string
param hbiWorkspace bool
param publicNetworkAccess string

// ---------- Derived resource names (CAF-aligned) ----------

var envNameSanitized = toLower(replace(environmentName, '-', ''))

var storageAccountName = 'st${take(envNameSanitized, 16)}${resourceSuffix}'
var keyVaultName = 'kv-${take(environmentName, 14)}-${resourceSuffix}'
var logAnalyticsName = 'log-${environmentName}-${resourceSuffix}'
var appInsightsName = 'appi-${environmentName}-${resourceSuffix}'
var containerRegistryName = 'cr${take(envNameSanitized, 40)}${resourceSuffix}'
var workspaceName = 'mlw-${environmentName}-${resourceSuffix}'

// ---------- Storage account ----------

module storage 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage-account'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: storageSkuName
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// ---------- Key Vault ----------

module keyVault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'key-vault'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    sku: keyVaultSkuName
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    enableRbacAuthorization: true
    publicNetworkAccess: publicNetworkAccess
  }
}

// ---------- Log Analytics workspace (required by App Insights) ----------

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.1' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: 30
  }
}

// ---------- Application Insights ----------

module appInsights 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'app-insights'
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    applicationType: 'web'
    kind: 'web'
  }
}

// ---------- Container Registry (optional) ----------

module containerRegistry 'br/public:avm/res/container-registry/registry:0.12.1' = if (deployContainerRegistry) {
  name: 'container-registry'
  params: {
    name: containerRegistryName
    location: location
    tags: tags
    acrSku: containerRegistrySku
    acrAdminUserEnabled: false
    publicNetworkAccess: publicNetworkAccess
  }
}

// ---------- Machine Learning workspace ----------

module workspace 'br/public:avm/res/machine-learning-services/workspace:0.13.2' = {
  name: 'ml-workspace'
  params: {
    name: workspaceName
    location: location
    tags: tags
    sku: 'Basic'
    kind: 'Default'
    friendlyName: workspaceFriendlyName
    description: workspaceDescription
    hbiWorkspace: hbiWorkspace
    publicNetworkAccess: publicNetworkAccess
    managedIdentities: {
      systemAssigned: true
    }
    associatedStorageAccountResourceId: storage.outputs.resourceId
    associatedKeyVaultResourceId: keyVault.outputs.resourceId
    associatedApplicationInsightsResourceId: appInsights.outputs.resourceId
    associatedContainerRegistryResourceId: deployContainerRegistry ? containerRegistry!.outputs.resourceId : null
    systemDatastoresAuthMode: 'Identity'
  }
}

// ---------- Outputs ----------

output workspaceName string = workspace.outputs.name
output workspaceId string = workspace.outputs.resourceId
output keyVaultName string = keyVault.outputs.name
output storageAccountName string = storage.outputs.name
output containerRegistryEndpoint string = deployContainerRegistry ? containerRegistry!.outputs.loginServer : ''
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
