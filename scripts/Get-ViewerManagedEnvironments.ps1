#Requires -Version 7.4
[CmdletBinding()]
param(
    [guid]$SubscriptionId,
    [switch]$SucceededOnly,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

$arguments = @('containerapp', 'env', 'list', '--output', 'json')
if ($SubscriptionId -ne [guid]::Empty) {
    $arguments += @('--subscription', $SubscriptionId.ToString())
}

$json = & az @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list Azure Container Apps managed environments.'
}

$environments = @($json | ConvertFrom-Json)
$results = foreach ($environment in $environments) {
    $apps = @(& az containerapp list `
        --subscription $environment.id.Split('/')[2] `
        --environment $environment.name `
        --resource-group $environment.resourceGroup `
        --query '[].name' `
        --output tsv)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Container Apps in managed environment '$($environment.name)'."
    }

    [pscustomobject]@{
        Name = [string]$environment.name
        ResourceGroup = [string]$environment.resourceGroup
        Location = [string]$environment.location
        ProvisioningState = [string]$environment.properties.provisioningState
        ContainerAppCount = @($apps | Where-Object { ![string]::IsNullOrWhiteSpace($_) }).Count
        ResourceId = [string]$environment.id
    }
}

$results = @($results |
    Where-Object { !$SucceededOnly -or $_.ProvisioningState -eq 'Succeeded' } |
    Sort-Object Location, ResourceGroup, Name)

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
}
else {
    $results | Format-Table -AutoSize
}
