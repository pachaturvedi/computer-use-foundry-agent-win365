#Requires -Version 7.4
<#
.SYNOPSIS
Removes a sample-owned environment with missing-layer recovery.

.DESCRIPTION
Runs ownership-driven W365/Entra cleanup once, deletes viewer, state, and foundry layers separately, continues only when an ARM deployment is already absent, and verifies that no tagged resource group remains. If a tagged resource group still remains after every layer has been attempted (the known azd layered-infra 'deployment not found' limitation can leave resources behind even when it is tolerated per layer), it falls back to deleting that resource group directly and polls for completion before failing.

Key inputs: EnvironmentName plus optional environment/manifest paths, executable overrides, UseDeviceCode, the default-enabled Purge option, Force, and the residual-resource-group poll attempts/delay used only by the fallback deletion.

.OUTPUTS
Layer-by-layer teardown progress and a final residual-resource verification result.

.NOTES
Destructive workflow. Other azd failures remain fatal, and cleanup fails closed without ownership proof.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName,
    [string]$EnvironmentFilePath,
    [string]$OwnershipManifestPath,
    [string]$AzdPath,
    [string]$AzureCliPath,
    [switch]$UseDeviceCode,
    [switch]$Purge = $true,
    [switch]$Force,
    [ValidateRange(0, [int]::MaxValue)]
    [int]$ResidualGroupPollAttempts = 20,
    [ValidateRange(0, [int]::MaxValue)]
    [int]$ResidualGroupPollDelaySeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Resolve-ApplicationPath {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory)][string]$CommandName
    )

    if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (!(Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "$CommandName executable '$ExplicitPath' was not found."
        }

        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    foreach ($command in @(Get-Command $CommandName -All -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($null -ne $command -and
            ![string]::IsNullOrWhiteSpace($command.Source) -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    }

    throw "$CommandName executable was not found on PATH."
}

function Resolve-AzdPath {
    param([string]$ExplicitPath)

    if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return Resolve-ApplicationPath -ExplicitPath $ExplicitPath -CommandName 'azd'
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command azd -All -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($null -ne $command -and
            ![string]::IsNullOrWhiteSpace($command.Source) -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf) -and
            !$candidatePaths.Contains($command.Source)) {
            $candidatePaths.Add($command.Source)
        }
    }

    $knownPaths = @()
    if (![string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $knownPaths += Join-Path $env:LOCALAPPDATA 'Programs\Azure Dev CLI\azd.exe'
    }
    if (![string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $knownPaths += Join-Path $env:ProgramFiles 'Azure Dev CLI\azd.exe'
    }
    foreach ($path in $knownPaths) {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and !$candidatePaths.Contains($path)) {
            $candidatePaths.Add($path)
        }
    }

    $candidates = @(
        foreach ($path in $candidatePaths) {
            try {
                $output = @(& $path version 2>$null)
                if ($LASTEXITCODE -eq 0 -and
                    ($output | Out-String) -match 'azd version\s+(\d+\.\d+\.\d+)') {
                    [pscustomobject]@{
                        Path = $path
                        Version = [version]$Matches[1]
                    }
                }
            }
            catch {
            }
        }
    )
    $selected = $candidates |
        Where-Object Version -ge ([version]'1.32.0') |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $selected) {
        throw 'Azure Developer CLI 1.32.0 or later was not found.'
    }

    return $selected.Path
}

function Invoke-AzdDownCommand {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Write-Host ('[{0:HH:mm:ss}] [COMMAND] azd {1}' -f [DateTimeOffset]::Now, ($Arguments -join ' '))
    $output = @(& $ExecutablePath @Arguments 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output | Out-String).Trim()
    }
}

function Invoke-AzureCliCommand {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $ExecutablePath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | Out-String).Trim()
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE. $detail"
    }

    return ($output | Out-String).Trim()
}

function Get-RemainingResourceGroups {
    param(
        [Parameter(Mandatory)][string]$AzureCliExecutable,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $output = Invoke-AzureCliCommand `
        -ExecutablePath $AzureCliExecutable `
        -Arguments @(
            'group'
            'list'
            '--subscription'
            $SubscriptionId
            '--tag'
            "azd-env-name=$EnvironmentName"
            '--query'
            '[].name'
            '--output'
            'tsv'
            '--only-show-errors'
        )
    return @($output -split '\r?\n' | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($EnvironmentFilePath)) {
    $EnvironmentFilePath = Join-Path (Join-Path $repositoryRoot ".azure\$EnvironmentName") '.env'
}
if ([string]::IsNullOrWhiteSpace($OwnershipManifestPath)) {
    $OwnershipManifestPath = Get-W365OwnershipManifestPath `
        -RepositoryRoot $repositoryRoot `
        -EnvironmentName $EnvironmentName
}

$azdExecutable = Resolve-AzdPath -ExplicitPath $AzdPath
$versionOutput = @(& $azdExecutable version 2>&1)
if ($LASTEXITCODE -ne 0 -or
    ($versionOutput | Out-String) -notmatch 'azd version\s+(\d+\.\d+\.\d+)' -or
    [version]$Matches[1] -lt [version]'1.32.0') {
    throw "Azure Developer CLI 1.32.0 or later is required. Version output: $(($versionOutput | Out-String).Trim())"
}

$azureCliExecutable = Resolve-ApplicationPath -ExplicitPath $AzureCliPath -CommandName 'az'
$environmentValues = if (Test-Path -LiteralPath $EnvironmentFilePath -PathType Leaf) {
    Read-AzdEnvironmentFile -Path $EnvironmentFilePath
}
else {
    [ordered]@{}
}
$subscriptionId = [string]$environmentValues['AZURE_SUBSCRIPTION_ID']
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    $subscriptionId = Invoke-AzureCliCommand `
        -ExecutablePath $azureCliExecutable `
        -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv', '--only-show-errors')
}
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw "Unable to resolve the Azure subscription for environment '$EnvironmentName'."
}

$target = "azd environment '$EnvironmentName' in subscription '$subscriptionId'"
if ($Force) {
    if ($WhatIfPreference) {
        $PSCmdlet.ShouldProcess($target, 'Delete all sample-owned W365, Entra, and Azure resources') | Out-Null
        return
    }
}
elseif (!$PSCmdlet.ShouldProcess($target, 'Delete all sample-owned W365, Entra, and Azure resources')) {
    return
}

$previousCleanupApproval = $env:W365_CLEANUP_CONFIRMED
$previousPredownState = $env:W365_PREDOWN_ALREADY_COMPLETED
try {
    $env:W365_CLEANUP_CONFIRMED = 'true'
    & (Join-Path $PSScriptRoot 'Remove-W365Resources.ps1') `
        -EnvironmentName $EnvironmentName `
        -EnvironmentFilePath $EnvironmentFilePath `
        -OwnershipManifestPath $OwnershipManifestPath `
        -UseDeviceCode:$UseDeviceCode `
        -Confirm:$false

    $env:W365_PREDOWN_ALREADY_COMPLETED = 'true'
    foreach ($layer in @('viewer', 'state', 'foundry')) {
        $arguments = @(
            'down'
            $layer
            '--environment'
            $EnvironmentName
            '--force'
        )
        if ($Purge) {
            $arguments += '--purge'
        }

        Write-Host ''
        Write-Host "Deleting azd infrastructure layer '$layer'."
        $result = Invoke-AzdDownCommand -ExecutablePath $azdExecutable -Arguments $arguments
        if ($result.ExitCode -eq 0) {
            $result.Output | Write-Output
            continue
        }

        if ($result.Text -match '(?i)\bdeployment not found\b') {
            Write-Warning "The '$layer' deployment is already absent. Continuing with the remaining infrastructure layers."
            continue
        }

        throw "azd $($arguments -join ' ') failed with exit code $($result.ExitCode). $($result.Text)"
    }
}
finally {
    [Environment]::SetEnvironmentVariable('W365_CLEANUP_CONFIRMED', $previousCleanupApproval, 'Process')
    [Environment]::SetEnvironmentVariable('W365_PREDOWN_ALREADY_COMPLETED', $previousPredownState, 'Process')
}

$remainingResourceGroups = @(Get-RemainingResourceGroups `
    -AzureCliExecutable $azureCliExecutable `
    -SubscriptionId $subscriptionId `
    -EnvironmentName $EnvironmentName)

if ($remainingResourceGroups.Count -gt 0) {
    Write-Warning "azd down did not remove resource group(s) tagged for '$EnvironmentName' (a known azd layered-infra limitation: 'deployment not found' is thrown for layers whose ARM deployment record is already missing, even when the resource group itself still holds resources): $($remainingResourceGroups -join ', '). Falling back to direct resource group deletion."
    foreach ($resourceGroupName in $remainingResourceGroups) {
        Invoke-AzureCliCommand `
            -ExecutablePath $azureCliExecutable `
            -Arguments @(
                'group'
                'delete'
                '--name'
                $resourceGroupName
                '--subscription'
                $subscriptionId
                '--yes'
                '--only-show-errors'
            ) | Out-Null
        Write-Host "Requested direct deletion of resource group '$resourceGroupName'."
    }

    for ($attempt = 1; $attempt -le $ResidualGroupPollAttempts; $attempt++) {
        $remainingResourceGroups = @(Get-RemainingResourceGroups `
            -AzureCliExecutable $azureCliExecutable `
            -SubscriptionId $subscriptionId `
            -EnvironmentName $EnvironmentName)
        if ($remainingResourceGroups.Count -eq 0) {
            break
        }
        if ($attempt -lt $ResidualGroupPollAttempts) {
            Start-Sleep -Seconds $ResidualGroupPollDelaySeconds
        }
    }
}

if ($remainingResourceGroups.Count -gt 0) {
    throw "Azure teardown is incomplete. Resource group(s) tagged for '$EnvironmentName' remain after fallback deletion: $($remainingResourceGroups -join ', ')."
}

Write-Output "Teardown completed for '$EnvironmentName'. No Azure resource group tagged for this environment remains."
