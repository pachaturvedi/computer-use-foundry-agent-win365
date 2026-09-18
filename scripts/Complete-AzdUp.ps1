#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$W365SetupScriptPath = (Join-Path $PSScriptRoot 'Invoke-W365SetupFlow.ps1'),
    [string]$ViewerBootstrapScriptPath = (Join-Path $PSScriptRoot 'Deploy-ViewerBootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')

function Test-EnabledValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    if ($Value -notin @('true', 'false')) {
        throw "Expected a strict true/false value, received '$Value'."
    }

    return $Value -eq 'true'
}

function Import-AzdEnvironmentValues {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $environmentPath = Join-Path (Join-Path $Root ".azure\$EnvironmentName") '.env'
    $values = Read-AzdEnvironmentFile -Path $environmentPath
    foreach ($entry in $values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }

    return $values
}

function Confirm-W365PostUpChanges {
    if (Test-EnabledValue -Value $env:W365_RESOURCE_CHANGES_CONFIRMED) {
        return
    }
    if (Test-EnabledValue -Value $env:AZD_NON_INTERACTIVE) {
        throw 'W365 resource changes require interactive approval. For protected automation, set W365_RESOURCE_CHANGES_CONFIRMED=true only for this process.'
    }

    Write-Host ''
    Write-Host 'Windows 365 enablement can create or update an Entra agent user,'
    Write-Host 'a billable Cloud PC agent pool, its assignment, and Graph consent.'
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') {
        throw 'Windows 365 resource changes were not approved.'
    }
}

if (Test-EnabledValue -Value $env:W365_POSTUP_IN_PROGRESS) {
    Write-Host 'Nested W365 postup execution skipped.'
    return
}

$enableW365 = Test-EnabledValue -Value $env:ENABLE_W365
if ($enableW365) {
    if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
        throw 'ENABLE_W365=true requires AZURE_ENV_NAME.'
    }
    $environmentName = $env:AZURE_ENV_NAME
    $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
    $w365AlreadyEnabled = Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED'])
    if ($w365AlreadyEnabled) {
        $state = Get-W365ProvisioningState `
            -RepositoryRoot $RepositoryRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $currentValues
        if ($state.Name -ne 'Complete') {
            throw "W365_ENABLED=true but environment '$environmentName' is not complete."
        }

        Write-Host "W365 environment '$environmentName' is already complete; setup redeployment skipped."
    }
    else {
        Confirm-W365PostUpChanges
        $previousPostUpGuard = $env:W365_POSTUP_IN_PROGRESS
        $env:W365_POSTUP_IN_PROGRESS = 'true'
        try {
            $setupArguments = @{
                Environment = $environmentName
                BillingConfirmed = $true
                ConfirmResourceChanges = $true
                UseDeviceCode = $true
            }
            $configuredPrincipalName = [string]$currentValues['W365_AGENT_USER_PRINCIPAL_NAME']
            if (![string]::IsNullOrWhiteSpace($configuredPrincipalName)) {
                $setupArguments.AgentUserPrincipalName = $configuredPrincipalName
            }
            $configuredDomain = [string]$currentValues['W365_AGENT_USER_DOMAIN']
            if (![string]::IsNullOrWhiteSpace($configuredDomain)) {
                $setupArguments.AgentUserDomain = $configuredDomain
            }
            & $W365SetupScriptPath @setupArguments
        }
        catch {
            $manifestPath = Get-W365OwnershipManifestPath `
                -RepositoryRoot $RepositoryRoot `
                -EnvironmentName $environmentName
            Write-Warning "The bootstrap agent remains W365-disabled. If resources were created, ownership evidence is retained at '$manifestPath'."
            throw
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'W365_POSTUP_IN_PROGRESS',
                $previousPostUpGuard,
                'Process')
        }

        $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
        $state = Get-W365ProvisioningState `
            -RepositoryRoot $RepositoryRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $currentValues
        if ($state.Name -ne 'Complete') {
            throw "W365 setup returned successfully, but environment '$environmentName' did not reach Complete state."
        }

        Write-Host "W365 setup and final hosted-agent deployment completed for '$environmentName'."
    }
}
else {
    Write-Host 'W365 setup skipped because ENABLE_W365 is not true.'
}

& $ViewerBootstrapScriptPath
