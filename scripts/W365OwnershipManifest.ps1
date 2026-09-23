#Requires -Version 7.4
<#
.SYNOPSIS
Provides ownership-manifest and azd environment-file helpers.

.DESCRIPTION
Reads, copies, and atomically writes W365/viewer ownership manifests and non-secret azd environment values while preserving type and path safety.


Key inputs: Repository/environment paths, manifest objects, and key/value dictionaries supplied to exported functions.

.OUTPUTS
Manifest objects, resolved paths, environment dictionaries, and updated local files.

.NOTES
Dot-source library. Ownership records are security boundaries; callers must not infer ownership from resource names.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'W365OwnershipManifest' -Message 'Loaded ownership manifest helpers.'
Write-SampleDebug -Component 'W365OwnershipManifest' -Message 'Ownership records contain identifiers and prior state, never credential values.'

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

function Get-OptionalObjectValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-W365OwnershipManifestPath {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    return Join-Path (Join-Path $RepositoryRoot ".azure\$EnvironmentName") 'w365-ownership.json'
}

function Get-ViewerOwnershipManifestPath {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    return Join-Path (Join-Path $RepositoryRoot ".azure\$EnvironmentName") 'viewer-ownership.json'
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
        [Parameter(Mandatory)][hashtable]$Manifest,
        [scriptblock]$BeforeReplace
    )

    $directory = Split-Path -Parent $Path
    if (![string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ConvertTo-Json (Copy-W365ManifestValue -Value $Manifest) -Depth 80
    $temporaryPath = Join-Path $directory (
        '.{0}.{1}.tmp' -f @([IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [Text.UTF8Encoding]::new($false))
        if ($null -ne $BeforeReplace) {
            & $BeforeReplace
        }
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
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

function Set-AzdEnvironmentFileValues {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [scriptblock]$BeforeReplace
    )

    if (!(Test-Path -LiteralPath $Path)) {
        throw "azd environment file '$Path' was not found."
    }

    $lines = [System.Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $Path))
    $remaining = [ordered]@{}
    foreach ($entry in $Values.GetEnumerator()) {
        $remaining[[string]$entry.Key] = [string]$entry.Value
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $line.Substring(0, $separatorIndex).Trim()
        if ($remaining.Contains($name)) {
            $lines[$i] = '{0}="{1}"' -f @($name, [string]$remaining[$name])
            $remaining.Remove($name)
        }
    }

    foreach ($entry in $remaining.GetEnumerator()) {
        $lines.Add('{0}="{1}"' -f @([string]$entry.Key, [string]$entry.Value))
    }

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory (
        '.{0}.{1}.tmp' -f @([IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllLines(
            $temporaryPath,
            [string[]]$lines,
            [Text.UTF8Encoding]::new($false))
        if ($null -ne $BeforeReplace) {
            & $BeforeReplace $temporaryPath $Path
        }
        [IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}