#Requires -Version 7.4
# TestCategory: Offline

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Initialize-AzdUpPhaseTwo.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "azd-up-phase-two-$([guid]::NewGuid())"
$binPath = Join-Path $tempRoot 'bin'
$callsPath = Join-Path $tempRoot 'calls.txt'
$identityCallsPath = Join-Path $tempRoot 'identity-calls.json'
$mockAzdPath = Join-Path $binPath 'azd.cmd'
$mockAzdScriptPath = Join-Path $binPath 'Mock-Azd.ps1'
$mockIdentityPath = Join-Path $tempRoot 'Mock-FoundryIdentity.ps1'
$mockProfilePath = Join-Path $tempRoot 'Mock-ProvisioningProfile.ps1'
$profileCallsPath = Join-Path $tempRoot 'profile-calls.json'
$previousPath = $env:Path
$previousCallsPath = $env:TEST_AZD_CALLS_PATH
$previousQuotaBehavior = $env:TEST_AZD_VIEWER_QUOTA_ONCE

try {
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
    Set-Content -LiteralPath $mockAzdScriptPath -Value @'
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CommandArgs
)
$global:LASTEXITCODE = 0
if ($CommandArgs[0] -eq 'version') {
    Write-Output 'azd version 99.0.0'
    return
}
Add-Content -LiteralPath $env:TEST_AZD_CALLS_PATH -Value ($CommandArgs -join ' ')
if ($env:TEST_AZD_VIEWER_QUOTA_ONCE -eq 'true' -and
    $CommandArgs -join ' ' -eq 'provision viewer --environment sample-dev --no-prompt') {
    $viewerCalls = @(Get-Content -LiteralPath $env:TEST_AZD_CALLS_PATH |
        Where-Object { $_ -eq 'provision viewer --environment sample-dev --no-prompt' })
    if ($viewerCalls.Count -eq 1) {
        Write-Output 'MaxNumberOfGlobalEnvironmentsInSubExceeded'
        exit 1
    }
}
if ($CommandArgs[0] -eq 'env' -and $CommandArgs[1] -eq 'get-value') {
    $values = @{
        FOUNDRY_PROJECT_OWNERSHIP = 'managed'
        FOUNDRY_PROJECT_ENDPOINT = 'https://sample.services.ai.azure.com/api/projects/sample-project'
        FOUNDRY_AGENT_NAME = 'win365-desktop-agent'
        AGENT_WIN365_DESKTOP_AGENT_VERSION = '1'
        AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        DEPLOY_STATE = 'true'
        STATE_STORAGE_ACCOUNT_NAME = 'samplestatestorage'
        STATE_CONTAINER_NAME = 'desktop-state'
        SESSION_BLOB_URI = 'https://samplestatestorage.blob.core.windows.net/desktop-state/slot.json'
    }
    Write-Output $values[$CommandArgs[2]]
}
'@
    Set-Content -LiteralPath $mockAzdPath -Value @"
@echo off
pwsh -NoProfile -File "$mockAzdScriptPath" %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath $mockProfilePath -Value @'
param(
    [string]$Environment,
    [switch]$ViewerOnly,
    [string]$ViewerMode
)
@{
    environment = $Environment
    viewerOnly = $ViewerOnly.IsPresent
    viewerMode = $ViewerMode
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_PROFILE_CALLS_PATH
'@
    Set-Content -LiteralPath $mockIdentityPath -Value @'
param(
    [uri]$ProjectEndpoint,
    [string]$AgentName,
    [string]$AgentVersion,
    [guid]$TenantId
)
@{
    projectEndpoint = $ProjectEndpoint.AbsoluteUri
    agentName = $AgentName
    agentVersion = $AgentVersion
    tenantId = $TenantId.ToString()
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_IDENTITY_CALLS_PATH
[pscustomobject]@{
    TenantId = $TenantId
    BlueprintId = [guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    AgentIdentityId = [guid]'cccccccc-cccc-cccc-cccc-cccccccccccc'
}
'@

    $env:Path = "$binPath;$previousPath"
    $env:TEST_AZD_CALLS_PATH = $callsPath
    $env:TEST_IDENTITY_CALLS_PATH = $identityCallsPath
    $env:TEST_PROFILE_CALLS_PATH = $profileCallsPath

    & $scriptPath `
        -Environment 'sample-dev' `
        -DeployViewer `
        -IdentityScriptPath $mockIdentityPath

    $identityCall = Get-Content -LiteralPath $identityCallsPath -Raw | ConvertFrom-Json
    if ($identityCall.projectEndpoint -ne 'https://sample.services.ai.azure.com/api/projects/sample-project' -or
        $identityCall.agentName -ne 'win365-desktop-agent' -or
        $identityCall.agentVersion -ne '1' -or
        $identityCall.tenantId -ne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') {
        throw 'Phase-two initialization did not discover the exact deployed Foundry identity.'
    }

    $calls = @(Get-Content -LiteralPath $callsPath)
    $requiredCalls = @(
        'env select sample-dev',
        'env set ENABLE_W365 true',
        'env set DEPLOY_STATE true',
        'env set STATE_AGENT_PRINCIPAL_ID cccccccc-cccc-cccc-cccc-cccccccccccc',
        'env set DEPLOY_VIEWER true',
        'env set VIEWER_LIVE_ENABLED false',
        'env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret',
        'provision state --environment sample-dev --no-prompt',
        'provision viewer --environment sample-dev --no-prompt'
    )
    foreach ($requiredCall in $requiredCalls) {
        if ($requiredCall -notin $calls) {
            throw "Phase-two initialization did not issue required command: $requiredCall"
        }
    }
    $stateIndex = [array]::IndexOf($calls, 'provision state --environment sample-dev --no-prompt')
    $viewerIndex = [array]::IndexOf($calls, 'provision viewer --environment sample-dev --no-prompt')
    if ($stateIndex -lt 0 -or $viewerIndex -le $stateIndex) {
        throw 'Phase-two initialization did not provision shared state before the viewer.'
    }
    if ([array]::IndexOf($calls, 'env get-value STATE_STORAGE_ACCOUNT_NAME') -le $stateIndex -or
        [array]::IndexOf($calls, 'env get-value SESSION_BLOB_URI') -le $stateIndex) {
        throw 'Phase-two initialization did not reload state outputs before viewer provisioning.'
    }

    Remove-Item -LiteralPath $callsPath, $profileCallsPath -ErrorAction SilentlyContinue
    $env:TEST_AZD_VIEWER_QUOTA_ONCE = 'true'
    & $scriptPath `
        -Environment 'sample-dev' `
        -DeployViewer `
        -IdentityScriptPath $mockIdentityPath `
        -ProvisioningProfileScriptPath $mockProfilePath
    $quotaCalls = @(Get-Content -LiteralPath $callsPath)
    if (@($quotaCalls | Where-Object {
        $_ -eq 'provision viewer --environment sample-dev --no-prompt'
    }).Count -ne 2) {
        throw 'ACA managed-environment quota recovery did not retry only the viewer layer.'
    }
    $profileCall = Get-Content -LiteralPath $profileCallsPath -Raw | ConvertFrom-Json
    if ($profileCall.environment -ne 'sample-dev' -or
        !$profileCall.viewerOnly -or
        $profileCall.viewerMode -ne 'existing') {
        throw 'ACA managed-environment quota recovery did not request explicit existing-environment selection.'
    }

    Write-Host 'azd up phase-two initialization offline test passed.'
}
finally {
    $env:Path = $previousPath
    $env:TEST_AZD_CALLS_PATH = $previousCallsPath
    $env:TEST_AZD_VIEWER_QUOTA_ONCE = $previousQuotaBehavior
    Remove-Item Env:\TEST_IDENTITY_CALLS_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_PROFILE_CALLS_PATH -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
