#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [guid]$TenantId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{1,14}$')]
    [string]$Prefix,
    [ValidatePattern('^[a-z][a-z0-9-]{0,6}[a-z0-9]$')]
    [string]$Environment = 'dev',
    [string]$Location = 'eastus',
    [switch]$DeployViewer,
    [switch]$SkipPreview
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This greenfield initializer is Windows-only.'
}

$root = Split-Path $PSScriptRoot
$azd = Get-Command azd -ErrorAction SilentlyContinue
if (!$azd) {
    throw 'Azure Developer CLI is required.'
}

$resourcePrefix = "$Prefix-$Environment".ToLowerInvariant()
$environmentName = $resourcePrefix
$compactPrefix = $resourcePrefix.Replace('-', '')
$hashInput = "$SubscriptionId|$resourcePrefix|$Location"
$hashBytes = [Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($hashInput))
$suffix = [Convert]::ToHexString($hashBytes)[0..5] -join ''
$suffix = $suffix.ToLowerInvariant()

$values = [ordered]@{
    AZURE_RESOURCE_GROUP = "$resourcePrefix-foundry-rg"
    AZURE_AI_ACCOUNT_NAME = "$compactPrefix" + "ai" + $suffix
    AZURE_AI_PROJECT_NAME = "$resourcePrefix-project"
    RESOURCE_PREFIX = $resourcePrefix
    DEPLOY_STATE = 'false'
    STATE_RESOURCE_GROUP_NAME = "$resourcePrefix-state-rg"
    STATE_AGENT_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000000'
    DEPLOY_VIEWER = $DeployViewer.ToString().ToLowerInvariant()
    VIEWER_RESOURCE_GROUP_NAME = "$resourcePrefix-viewer-rg"
    VIEWER_IMAGE_NAME = 'win365-sample:v1'
    W365_ENABLED = 'false'
}
if ($PSBoundParameters.ContainsKey('TenantId')) {
    $values.AZURE_TENANT_ID = $TenantId
}

Push-Location $root
try {
    & $azd.Source env new $environmentName `
        --subscription $SubscriptionId `
        --location $Location `
        --no-prompt
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create azd environment $environmentName."
    }

    foreach ($entry in $values.GetEnumerator()) {
        & $azd.Source env set $entry.Key ([string]$entry.Value)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to set azd environment value $($entry.Key)."
        }
    }

    Write-Host ''
    Write-Host "Greenfield environment '$environmentName' is configured."
    Write-Host "  Resource prefix:        $resourcePrefix"
    Write-Host "  Foundry resource group: $($values.AZURE_RESOURCE_GROUP)"
    Write-Host "  Foundry account:        $($values.AZURE_AI_ACCOUNT_NAME)"
    Write-Host "  Foundry project:        $($values.AZURE_AI_PROJECT_NAME)"
    if ($DeployViewer) {
        Write-Host "  Viewer resource group:  $($values.VIEWER_RESOURCE_GROUP_NAME)"
    }

    if (!$SkipPreview) {
        $previousUserAgent = $env:AZURE_DEV_USER_AGENT
        $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
        try {
            & $azd.Source provision --preview --no-prompt
            if ($LASTEXITCODE -ne 0) {
                throw 'Greenfield provisioning preview failed.'
            }
        }
        finally {
            $env:AZURE_DEV_USER_AGENT = $previousUserAgent
        }
    }

    Write-Host ''
    Write-Host 'Review the preview, then deploy everything with:'
    Write-Host '  azd up --no-prompt'
}
finally {
    Pop-Location
}
