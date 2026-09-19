#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$ProjectEndpoint,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$AgentName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string]$AgentVersion,
    [Parameter(Mandatory)][guid]$TenantId
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
if ($ProjectEndpoint.Scheme -ne 'https' -or !$ProjectEndpoint.Host.EndsWith('.services.ai.azure.com') -or
    $ProjectEndpoint.UserInfo -or $ProjectEndpoint.Query -or $ProjectEndpoint.Fragment -or
    $ProjectEndpoint.AbsolutePath.TrimEnd('/') -notmatch '^/api/projects/[^/]+$') {
    throw 'Use the public-cloud Foundry project endpoint https://<account>.services.ai.azure.com/api/projects/<project>.'
}
$account = az account show --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.tenantId -ne $TenantId.ToString()) {
    throw 'Sign in to Azure CLI in the same tenant as Foundry and W365 before discovery.'
}
$url = "$($ProjectEndpoint.AbsoluteUri.TrimEnd('/'))/agents/$AgentName/versions/$AgentVersion`?api-version=2025-11-15-preview"
# Azure CLI handles the bearer internally; never print or persist tokens.
$agent = az rest --method get --url $url --resource https://ai.azure.com --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Foundry agent identity discovery failed.' }
$blueprint = [guid]$agent.blueprint.client_id
$principal = [guid]$agent.instance_identity.principal_id
if ($blueprint -eq [guid]::Empty -or $principal -eq [guid]::Empty) {
    throw 'Foundry has not populated the blueprint and instance principal. Wait for provisioning; do not create substitute identities.'
}
[pscustomobject]@{
    TenantId = $TenantId
    BlueprintId = $blueprint
    AgentIdentityId = $principal
}
