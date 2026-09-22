#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [switch]$DeployViewer,
    [string]$IdentityScriptPath = (Join-Path $PSScriptRoot 'Get-FoundryIdentity.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$IsWindows) {
    throw 'The azd phase-two initializer is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

$azd = Get-W365AzdCommand
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}

Invoke-W365Azd -Azd $azd -Arguments @('env', 'select', $Environment) | Out-Null
$ownership = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_OWNERSHIP' -AllowMissing
if ([string]::IsNullOrWhiteSpace($ownership)) {
    $ownership = 'managed'
}
if ($ownership -ne 'managed') {
    throw "Automatic phase-two setup is limited to a dedicated managed Foundry project; environment '$Environment' uses ownership '$ownership'."
}

$projectEndpoint = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_ENDPOINT'
$agentName = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_AGENT_NAME' -AllowMissing
if ([string]::IsNullOrWhiteSpace($agentName)) {
    $agentName = 'win365-desktop-agent'
}
$agentVersion = Get-W365AzdValue -Azd $azd -Name 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
$tenantIdValue = Get-W365AzdValue -Azd $azd -Name 'AZURE_TENANT_ID'
$tenantId = [guid]::Empty
if (![guid]::TryParse($tenantIdValue, [ref]$tenantId) -or $tenantId -eq [guid]::Empty) {
    throw "Azd environment '$Environment' does not contain a valid AZURE_TENANT_ID."
}

Write-W365ProvisioningStep "Discovering the phase-one Foundry principal for agent '$agentName' version '$agentVersion'."
$identityResult = @(& $IdentityScriptPath `
    -ProjectEndpoint $projectEndpoint `
    -AgentName $agentName `
    -AgentVersion $agentVersion `
    -TenantId $tenantId)
if ($LASTEXITCODE -ne 0) {
    throw 'Foundry identity discovery failed before phase-two provisioning.'
}
$identity = $identityResult | Select-Object -Last 1
$agentPrincipalId = [guid]::Empty
if ($null -eq $identity -or
    ![guid]::TryParse([string]$identity.AgentIdentityId, [ref]$agentPrincipalId) -or
    $agentPrincipalId -eq [guid]::Empty) {
    throw 'Foundry identity discovery did not return a valid agent object/principal ID.'
}

$phaseTwoValues = [ordered]@{
    ENABLE_W365 = 'true'
    DEPLOY_STATE = 'true'
    STATE_AGENT_PRINCIPAL_ID = $agentPrincipalId.ToString()
    DEPLOY_VIEWER = $DeployViewer.IsPresent.ToString().ToLowerInvariant()
    VIEWER_LIVE_ENABLED = 'false'
}
Set-W365AzdValues -Azd $azd -Values $phaseTwoValues

$previousUserAgent = $env:AZURE_DEV_USER_AGENT
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
try {
    Write-W365ProvisioningStep "Provisioning shared Blob state for agent principal '$agentPrincipalId'."
    Invoke-W365Azd -Azd $azd -Arguments @(
        'provision', 'state', '--environment', $Environment, '--no-prompt'
    ) | Out-Null

    if ($DeployViewer) {
        Write-W365ProvisioningStep 'Provisioning the ACA viewer bootstrap after shared state is ready.'
        Invoke-W365Azd -Azd $azd -Arguments @(
            'provision', 'viewer', '--environment', $Environment, '--no-prompt'
        ) | Out-Null
    }
}
finally {
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
}

Write-Host "Phase-two Azure prerequisites are ready for '$Environment'."
