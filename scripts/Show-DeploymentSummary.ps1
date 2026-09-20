#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$Environment = $env:AZURE_ENV_NAME
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$values = if (![string]::IsNullOrWhiteSpace($Environment)) {
    Read-AzdEnvironmentFile -Path (Join-Path $RepositoryRoot ".azure\$Environment\.env")
}
else {
    @{}
}
function Get-Value {
    param([string]$Name)
    $value = [string]$values[$Name]
    return $(if ([string]::IsNullOrWhiteSpace($value)) { '-' } else { $value })
}

$rows = @(
    [pscustomobject]@{ Resource = 'Foundry project'; ResourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'; Name = Get-Value 'AZURE_AI_PROJECT_NAME'; Result = 'Ready' }
    [pscustomobject]@{ Resource = 'Hosted agent'; ResourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'; Name = Get-Value 'FOUNDRY_AGENT_NAME'; Result = Get-Value 'AGENT_WIN365_DESKTOP_AGENT_ENDPOINT' }
    [pscustomobject]@{ Resource = 'W365 credential vault'; ResourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'; Name = Get-Value 'W365_KEY_VAULT_NAME'; Result = 'Ready' }
    [pscustomobject]@{ Resource = 'Shared Blob state'; ResourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'; Name = Get-Value 'STATE_STORAGE_ACCOUNT_NAME'; Result = $(if ((Get-Value 'DEPLOY_STATE') -eq 'true') { 'Ready' } else { 'Skipped' }) }
    [pscustomobject]@{ Resource = 'ACA viewer'; ResourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'; Name = Get-Value 'VIEWER_APP_NAME'; Result = $(if ((Get-Value 'DEPLOY_VIEWER') -eq 'true') { Get-Value 'VIEWER_PUBLIC_URL' } else { 'Skipped' }) }
    [pscustomobject]@{ Resource = 'Windows 365'; ResourceGroup = '-'; Name = $(if ((Get-Value 'W365_POOL_NAME') -ne '-') { Get-Value 'W365_POOL_NAME' } else { Get-Value 'W365_POOL_ID' }); Result = $(if ((Get-Value 'W365_ENABLED') -eq 'true') { 'Ready' } else { 'Skipped' }) }
)

Write-Host ''
Write-Host "Deployment result: $Environment"
$rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
if ((Get-Value 'W365_ENABLED') -eq 'true') {
    $agentVersion = Get-Value 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
    Write-Host "Next: start a fresh hosted-agent session pinned to active version ${agentVersion}:"
    Write-Host "  azd ai agent invoke $(Get-Value 'FOUNDRY_AGENT_NAME') --environment $Environment --version $agentVersion --new-session '<task>'"
}
Write-SampleVerbose -Component 'deployment-summary' -Message 'Final values were loaded from the selected azd environment.'
Write-SampleDebug -Component 'deployment-summary' -Message "Environment file contains $($values.Count) non-secret entries."
