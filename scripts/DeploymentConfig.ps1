#Requires -Version 7.4

Set-StrictMode -Version Latest

function Read-DeploymentConfigFile {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        throw "Configuration file '$Path' was not found."
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20)
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON. $($_.Exception.Message)"
    }
}

function Merge-DeploymentConfig {
    param(
        [Parameter(Mandatory)][hashtable]$Base,
        [Parameter(Mandatory)][hashtable]$Override
    )

    foreach ($key in $Override.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            Merge-DeploymentConfig -Base $Base[$key] -Override $Override[$key]
            continue
        }

        $Base[$key] = $Override[$key]
    }
}

function Convert-DeploymentSettingValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)]$DefaultValue
    )

    if ($DefaultValue -is [bool]) {
        return [bool]::Parse($Value)
    }
    if ($DefaultValue -is [int]) {
        return [int]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    }

    return $Value
}

function Get-DeploymentConfiguredValue {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)]$DefaultValue
    )

    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($environmentValue)) {
        return $DefaultValue
    }

    return Convert-DeploymentSettingValue -Value $environmentValue -DefaultValue $DefaultValue
}

function Get-DeploymentConfig {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ConfigPath
    )

    $resolvedConfigPath = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($resolvedConfigPath)) {
        $resolvedConfigPath = Join-Path $RepositoryRoot 'config\deployment.defaults.json'
    }

    $config = Read-DeploymentConfigFile -Path $resolvedConfigPath
    $localConfigPath = Join-Path (Split-Path -Parent $resolvedConfigPath) 'deployment.local.json'
    if (Test-Path -LiteralPath $localConfigPath) {
        Merge-DeploymentConfig -Base $config -Override (Read-DeploymentConfigFile -Path $localConfigPath)
    }

    return [pscustomobject]@{
        Path = $resolvedConfigPath
        LocalOverridePath = $localConfigPath
        Values = $config
    }
}