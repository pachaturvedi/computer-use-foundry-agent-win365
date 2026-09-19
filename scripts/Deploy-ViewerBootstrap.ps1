#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if ($env:DEPLOY_VIEWER -ne 'true') {
    Write-Host 'Viewer deployment skipped because DEPLOY_VIEWER is not true.'
    return
}

$required = @(
    'AZURE_SUBSCRIPTION_ID',
    'VIEWER_RESOURCE_GROUP_NAME',
    'VIEWER_APP_NAME',
    'VIEWER_IDENTITY_PRINCIPAL_ID',
    'VIEWER_IDENTITY_RESOURCE_ID',
    'VIEWER_REGISTRY_NAME',
    'VIEWER_REGISTRY_ENDPOINT',
    'VIEWER_IMAGE_NAME',
    'STATE_RESOURCE_GROUP_NAME',
    'STATE_STORAGE_ACCOUNT_NAME',
    'STATE_CONTAINER_NAME',
    'SESSION_BLOB_URI'
)
foreach ($name in $required) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing required viewer deployment value $name."
    }
}

Assert-ViewerSharedStateConfiguration `
    -DeployState $env:DEPLOY_STATE `
    -StateResourceGroupName $env:STATE_RESOURCE_GROUP_NAME `
    -StateStorageAccountName $env:STATE_STORAGE_ACCOUNT_NAME `
    -StateContainerName $env:STATE_CONTAINER_NAME `
    -SessionBlobUri $env:SESSION_BLOB_URI
Assert-ViewerManagedEnvironmentResourceId `
    -ResourceId $env:VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required for the viewer image deployment hook.'
}
if (!(az extension show --name containerapp --output none 2>$null)) {
    throw 'Azure CLI extension containerapp is required. Install it before running azd up.'
}
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

$subscription = $env:AZURE_SUBSCRIPTION_ID
$resourceGroup = $env:VIEWER_RESOURCE_GROUP_NAME
$appName = $env:VIEWER_APP_NAME
$registryName = $env:VIEWER_REGISTRY_NAME
$registryEndpoint = $env:VIEWER_REGISTRY_ENDPOINT
$identityPrincipalId = $env:VIEWER_IDENTITY_PRINCIPAL_ID
$identityResourceId = $env:VIEWER_IDENTITY_RESOURCE_ID
$imageName = $env:VIEWER_IMAGE_NAME

if ($env:VIEWER_LIVE_ENABLED -eq 'true') {
    $liveRequired = @(
        'VIEWER_PUBLIC_URL',
        'VIEWER_CLIENT_ID',
        'OPERATOR_TENANT_ID',
        'OPERATOR_OBJECT_ID',
        'W365_TENANT_ID',
        'W365_BLUEPRINT_ID',
        'W365_AGENT_ID',
        'W365_AGENT_OBJECT_ID',
        'W365_AGENT_USER_ID',
        'SCREENSHARE_SDK_URL',
        'SCREENSHARE_FRAME_ORIGINS',
        'SCREENSHARE_APP_URL',
        'VIEWER_KEY_VAULT_NAME',
        'W365_BLUEPRINT_CREDENTIAL_MODE'
    )
    foreach ($name in $liveRequired) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "VIEWER_LIVE_ENABLED=true requires $name."
        }
    }
    if ($env:W365_ENABLED -ne 'true') {
        throw 'VIEWER_LIVE_ENABLED=true requires W365_ENABLED=true.'
    }
    Assert-ViewerCredentialMode -CredentialMode $env:W365_BLUEPRINT_CREDENTIAL_MODE
    Assert-ViewerIdentityModeConfiguration `
        -CredentialMode $env:W365_BLUEPRINT_CREDENTIAL_MODE `
        -ViewerPrincipalId $env:VIEWER_IDENTITY_PRINCIPAL_ID `
        -OwnershipManifestPath (Join-Path (Split-Path $PSScriptRoot) ".azure\$($env:AZURE_ENV_NAME)\w365-ownership.json")

    $requiredSecrets = @('w365-viewer-client-secret')
    if ($env:W365_BLUEPRINT_CREDENTIAL_MODE -eq 'client_secret') {
        $requiredSecrets += 'w365-blueprint-client-secret'
    }
    foreach ($secretName in $requiredSecrets) {
        & az keyvault secret show `
            --subscription $subscription `
            --vault-name $env:VIEWER_KEY_VAULT_NAME `
            --name $secretName `
            --query id `
            --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Key Vault '$($env:VIEWER_KEY_VAULT_NAME)' must contain secret '$secretName'."
        }
    }
}

Invoke-Az @(
    'acr', 'build',
    '--subscription', $subscription,
    '--registry', $registryName,
    '--image', $imageName,
    '--file', (Join-Path (Split-Path $PSScriptRoot) 'Dockerfile'),
    (Split-Path $PSScriptRoot),
    '--output', 'none'
)

$registryId = (& az acr show `
    --subscription $subscription `
    --name $registryName `
    --query 'id' `
    --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($registryId)) {
    throw 'Unable to resolve the viewer registry resource ID.'
}

for ($attempt = 1; $attempt -le 5; $attempt++) {
    $role = & az role assignment list `
        --subscription $subscription `
        --scope $registryId `
        --assignee-object-id $identityPrincipalId `
        --query "[?roleDefinitionName=='AcrPull'].roleDefinitionName" `
        --output tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and $role -eq 'AcrPull') {
        break
    }
    if ($attempt -eq 5) {
        throw 'AcrPull did not propagate within five minutes.'
    }
    Write-Host "Waiting for AcrPull propagation ($attempt/5)..."
    Start-Sleep -Seconds 60
}

Invoke-Az @(
    'containerapp', 'registry', 'set',
    '--subscription', $subscription,
    '--resource-group', $resourceGroup,
    '--name', $appName,
    '--server', $registryEndpoint,
    '--identity', $identityResourceId
)
Invoke-Az @(
    'containerapp', 'update',
    '--subscription', $subscription,
    '--resource-group', $resourceGroup,
    '--name', $appName,
    '--image', "$registryEndpoint/$imageName",
    '--output', 'none'
)

$hostname = (& az containerapp show `
    --subscription $subscription `
    --resource-group $resourceGroup `
    --name $appName `
    --query 'properties.configuration.ingress.fqdn' `
    --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostname)) {
    throw 'Unable to resolve the viewer hostname.'
}

$healthUri = "https://$hostname/health"
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
do {
    try {
        $health = Invoke-RestMethod -Uri $healthUri -TimeoutSec 10
        if ($health.status -eq 'healthy') {
            & azd env set VIEWER_PUBLIC_URL "https://$hostname"
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to save VIEWER_PUBLIC_URL to the azd environment.'
            }
            Write-Host "Viewer bootstrap is healthy: $healthUri"
            return
        }
    }
    catch {
        Start-Sleep -Seconds 10
    }
} while ([DateTimeOffset]::UtcNow -lt $deadline)

throw "Viewer did not become healthy within five minutes. Check Container Apps logs for $appName."
