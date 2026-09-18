#Requires -Version 7.4

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')

function Write-W365ProvisioningStep {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0:HH:mm:ss}] {1}' -f [DateTimeOffset]::Now, $Message)
}

function Get-W365AzdCommand {
    $azdPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command azd -All -ErrorAction SilentlyContinue)) {
        if ($null -ne $command -and !$azdPaths.Contains($command.Source)) {
            $azdPaths.Add($command.Source)
        }
    }
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Azure Dev CLI\azd.exe'),
        (Join-Path $env:ProgramFiles 'Azure Dev CLI\azd.exe')
    )) {
        if (![string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path) -and
            !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    $candidates = $azdPaths |
        ForEach-Object {
            $versionOutput = & $_ version 2>$null
            if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'azd version\s+(\d+\.\d+\.\d+)') {
                [pscustomobject]@{ Path = $_; Version = [version]$Matches[1] }
            }
        } |
        Sort-Object Version -Descending

    return $candidates |
        Where-Object Version -ge ([version]'1.32.0') |
        Select-Object -First 1
}

function Invoke-W365Azd {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    Write-Host ('[{0:HH:mm:ss}] [COMMAND] azd {1}' -f [DateTimeOffset]::Now, ($Arguments -join ' '))
    $output = & $Azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }

    return $output
}

function Get-W365AzdValue {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowMissing
    )

    try {
        return Invoke-W365Azd -Azd $Azd -Arguments @('env', 'get-value', $Name) -CaptureOutput
    }
    catch {
        if ($AllowMissing) {
            return ''
        }

        throw
    }
}

function Set-W365AzdValues {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )

    foreach ($entry in $Values.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            throw "Cannot persist empty azd environment value '$($entry.Key)'."
        }

        Invoke-W365Azd -Azd $Azd -Arguments @('env', 'set', [string]$entry.Key, [string]$entry.Value) | Out-Null
    }
}

function Resolve-W365TenantId {
    param(
        [Parameter(Mandatory)]$Azd,
        [guid]$ExplicitTenantId = [guid]::Empty
    )

    if ($ExplicitTenantId -ne [guid]::Empty) {
        return $ExplicitTenantId
    }

    foreach ($name in @('W365_TENANT_ID', 'AZURE_TENANT_ID')) {
        $value = Get-W365AzdValue -Azd $Azd -Name $name -AllowMissing
        $parsed = [guid]::Empty
        if ([guid]::TryParse($value, [ref]$parsed) -and $parsed -ne [guid]::Empty) {
            return $parsed
        }
    }

    throw 'TenantId is required when the azd environment does not contain AZURE_TENANT_ID or W365_TENANT_ID.'
}

function ConvertTo-W365NameToken {
    param([Parameter(Mandatory)][string]$Value)

    $token = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $token = $token -replace '-+', '-'
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Value '$Value' cannot produce a valid W365 resource name token."
    }

    return $token
}

function Get-W365PoolDisplayName {
    param(
        [Parameter(Mandatory)][string]$ResourcePrefix,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [ValidateRange(32, 128)][int]$MaximumLength = 64
    )

    $prefixToken = ConvertTo-W365NameToken -Value $ResourcePrefix
    $environmentToken = ConvertTo-W365NameToken -Value $EnvironmentName
    $name = "foundry-w365-$prefixToken-$environmentToken"
    if ($name.Length -le $MaximumLength) {
        return $name
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($name)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($bytes)
    $suffix = ([Convert]::ToHexString($hashBytes)).Substring(0, 8).ToLowerInvariant()
    $baseLength = $MaximumLength - $suffix.Length - 1
    return "$($name.Substring(0, $baseLength).TrimEnd('-'))-$suffix"
}

function Assert-W365ResourceApproval {
    param(
        [Parameter(Mandatory)][bool]$EnableW365,
        [Parameter(Mandatory)][bool]$ConfirmResourceChanges
    )

    if (!$EnableW365) {
        return
    }
    if (!$ConfirmResourceChanges) {
        throw 'W365 enablement can create or update billable Cloud PC and Entra resources. Review the plan and explicitly confirm resource changes.'
    }
}

function Get-W365ProvisioningState {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues
    )

    $manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $RepositoryRoot -EnvironmentName $EnvironmentName
    $manifest = Read-W365OwnershipManifest -Path $manifestPath -AllowMissing
    $persistedKeys = @('W365_POOL_ID', 'W365_AGENT_USER_ID', 'W365_AGENT_ID', 'W365_AGENT_OBJECT_ID', 'W365_BLUEPRINT_ID')
    $persistedState = @($persistedKeys | Where-Object {
        $EnvironmentValues.Contains($_) -and
        ![string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$_])
    })

    if ($null -eq $manifest) {
        if ($persistedState.Count -gt 0 -or [string]$EnvironmentValues['W365_ENABLED'] -eq 'true') {
            throw "W365 environment state exists without ownership manifest '$manifestPath'. Reconcile or tear down the legacy state before continuing."
        }

        return [pscustomobject]@{
            Name = 'FirstRun'
            ManifestPath = $manifestPath
            Manifest = $null
        }
    }

    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Ownership manifest '$manifestPath' uses unsupported schema version '$($manifest.schemaVersion)'."
    }
    if ([string]$manifest.environmentName -ne $EnvironmentName) {
        throw "Ownership manifest '$manifestPath' belongs to environment '$($manifest.environmentName)', not '$EnvironmentName'."
    }

    foreach ($required in @(
        @{ Path = 'w365.pool.id'; Value = $manifest.w365.pool.id },
        @{ Path = 'w365.agentUser.id'; Value = $manifest.w365.agentUser.id },
        @{ Path = 'w365.assignment.poolId'; Value = $manifest.w365.assignment.poolId },
        @{ Path = 'w365.assignment.userPrincipalId'; Value = $manifest.w365.assignment.userPrincipalId }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "Ownership manifest '$manifestPath' is incomplete: $($required.Path) is required."
        }
    }

    $comparisons = @(
        @{ Key = 'W365_POOL_ID'; ManifestValue = $manifest.w365.pool.id },
        @{ Key = 'W365_AGENT_USER_ID'; ManifestValue = $manifest.w365.agentUser.id },
        @{ Key = 'W365_AGENT_ID'; ManifestValue = $manifest.graph.agent.appId },
        @{ Key = 'W365_AGENT_OBJECT_ID'; ManifestValue = $manifest.graph.agent.objectId },
        @{ Key = 'W365_BLUEPRINT_ID'; ManifestValue = $manifest.graph.blueprint.appId }
    )
    foreach ($comparison in $comparisons) {
        $environmentValue = [string]$EnvironmentValues[$comparison.Key]
        if (![string]::IsNullOrWhiteSpace($environmentValue) -and
            $environmentValue -ne [string]$comparison.ManifestValue) {
            throw "W365 environment value '$($comparison.Key)' does not match the ownership manifest."
        }
    }

    return [pscustomobject]@{
        Name = if ([string]$EnvironmentValues['W365_ENABLED'] -eq 'true') { 'Complete' } else { 'Provisioned' }
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}
