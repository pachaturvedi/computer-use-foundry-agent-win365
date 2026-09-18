#Requires -Version 7.4

Set-StrictMode -Version Latest

function Copy-W365ManifestValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-W365ManifestValue -Value $Value[$key]
        }

        return $copy
    }

    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = Copy-W365ManifestValue -Value $property.Value
        }

        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable] -and !($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(Copy-W365ManifestValue -Value $item)
        }

        return $items
    }

    return $Value
}

function Get-W365OwnershipManifestPath {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    return Join-Path (Join-Path $RepositoryRoot ".azure\$EnvironmentName") 'w365-ownership.json'
}

function Read-W365OwnershipManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissing
    )

    if (!(Test-Path -LiteralPath $Path)) {
        if ($AllowMissing) {
            return $null
        }

        throw "Ownership manifest '$Path' was not found."
    }

    try {
        return Copy-W365ManifestValue -Value (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 80)
    }
    catch {
        throw "Ownership manifest '$Path' is not valid JSON. $($_.Exception.Message)"
    }
}

function Write-W365OwnershipManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Manifest
    )

    $directory = Split-Path -Parent $Path
    if (![string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ConvertTo-Json (Copy-W365ManifestValue -Value $Manifest) -Depth 80
    Set-Content -LiteralPath $Path -Value $json
}

function Read-AzdEnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        throw "azd environment file '$Path' was not found."
    }

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$name] = $value
    }

    return $values
}