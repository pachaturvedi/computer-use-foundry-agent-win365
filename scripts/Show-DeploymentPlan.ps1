#Requires -Version 7.4
<#
.SYNOPSIS
Prints the component create, reuse, or skip plan.

.DESCRIPTION
Evaluates the current deployment environment and displays the intended Foundry, state, viewer, and W365 topology before resource changes.


Key inputs: Values are read from the current process and selected azd environment.

.OUTPUTS
A concise deployment-plan table for operator review.

.NOTES
Read-only. It performs no Azure, Entra, Graph, Foundry, or W365 mutation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Test-True {
    param([string]$Value)
    return $Value -eq 'true'
}

function Get-CreateOrReuse {
    param([string]$ExistingValue)
    return $(if ([string]::IsNullOrWhiteSpace($ExistingValue)) { 'Create' } else { 'Reuse' })
}

$viewerEnabled = Test-True $env:DEPLOY_VIEWER
$stateEnabled = Test-True $env:DEPLOY_STATE
$w365Enabled = Test-True $env:W365_ENABLED
$enableW365 = Test-True $env:ENABLE_W365
if ($viewerEnabled) {
    Assert-ViewerAzureCliPrerequisites
}
$vaultName = if (![string]::IsNullOrWhiteSpace($env:W365_KEY_VAULT_NAME)) {
    $env:W365_KEY_VAULT_NAME
}
else {
    $env:VIEWER_KEY_VAULT_NAME
}

$rows = @(
    [pscustomobject]@{
        Component = 'Foundry'
        Action = Get-CreateOrReuse $env:FOUNDRY_PROJECT_ENDPOINT
        Target = $(if ($env:AZURE_AI_PROJECT_NAME) { $env:AZURE_AI_PROJECT_NAME } else { 'Foundry project and hosted agent' })
        Reason = $(if ($env:FOUNDRY_PROJECT_ENDPOINT) { 'Project endpoint already configured' } else { 'No existing project endpoint' })
    }
    [pscustomobject]@{
        Component = 'Credential vault'
        Action = Get-CreateOrReuse $vaultName
        Target = $(if ($vaultName) { $vaultName } else { "$($env:STATE_RESOURCE_GROUP_NAME) / generated name" })
        Reason = 'Required by W365 client-secret authentication; independent of viewer'
    }
    [pscustomobject]@{
        Component = 'Shared state'
        Action = $(if ($stateEnabled) { Get-CreateOrReuse $env:STATE_STORAGE_ACCOUNT_NAME } else { 'Skip' })
        Target = $(if ($env:STATE_STORAGE_ACCOUNT_NAME) { $env:STATE_STORAGE_ACCOUNT_NAME } else { $env:STATE_RESOURCE_GROUP_NAME })
        Reason = $(if ($stateEnabled) { 'DEPLOY_STATE=true' } else { 'DEPLOY_STATE=false' })
    }
    [pscustomobject]@{
        Component = 'Viewer'
        Action = $(if ($viewerEnabled) { Get-CreateOrReuse $env:VIEWER_APP_NAME } else { 'Skip' })
        Target = $(if ($env:VIEWER_APP_NAME) { $env:VIEWER_APP_NAME } else { $env:VIEWER_RESOURCE_GROUP_NAME })
        Reason = $(if ($viewerEnabled) { 'DEPLOY_VIEWER=true' } else { 'DEPLOY_VIEWER=false' })
    }
    [pscustomobject]@{
        Component = 'Windows 365'
        Action = $(if ($w365Enabled) { 'Reuse' } elseif ($enableW365) { 'Create' } else { 'Skip' })
        Target = $(if ($env:W365_POOL_ID) { $env:W365_POOL_ID } else { 'Agent user, consent, and Cloud PC pool' })
        Reason = $(if ($w365Enabled) { 'W365 setup already complete' } elseif ($enableW365) { 'ENABLE_W365=true' } else { 'ENABLE_W365=false' })
    }
)

Write-Host ''
Write-Host "Deployment plan: $($env:AZURE_ENV_NAME)"
Write-Host "Environment resource group: $($env:AZURE_RESOURCE_GROUP)"
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-SampleVerbose -Component 'deployment-plan' -Message 'Use layer-specific azd provision --preview commands for Azure what-if details.'
Write-SampleDebug -Component 'deployment-plan' -Message "Subscription=$($env:AZURE_SUBSCRIPTION_ID); location=$($env:AZURE_LOCATION); resourcePrefix=$($env:RESOURCE_PREFIX)."
