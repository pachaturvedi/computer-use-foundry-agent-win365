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
$mockAzdPath = Join-Path $binPath 'azd.ps1'
$mockIdentityPath = Join-Path $tempRoot 'Mock-FoundryIdentity.ps1'
$previousPath = $env:Path
$previousCallsPath = $env:TEST_AZD_CALLS_PATH

try {
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
    Set-Content -LiteralPath $mockAzdPath -Value @'
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
if ($CommandArgs[0] -eq 'env' -and $CommandArgs[1] -eq 'get-value') {
    $values = @{
        FOUNDRY_PROJECT_OWNERSHIP = 'managed'
        FOUNDRY_PROJECT_ENDPOINT = 'https://sample.services.ai.azure.com/api/projects/sample-project'
        FOUNDRY_AGENT_NAME = 'win365-desktop-agent'
        AGENT_WIN365_DESKTOP_AGENT_VERSION = '1'
        AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    }
    Write-Output $values[$CommandArgs[2]]
}
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

    Write-Host 'azd up phase-two initialization offline test passed.'
}
finally {
    $env:Path = $previousPath
    $env:TEST_AZD_CALLS_PATH = $previousCallsPath
    Remove-Item Env:\TEST_IDENTITY_CALLS_PATH -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
