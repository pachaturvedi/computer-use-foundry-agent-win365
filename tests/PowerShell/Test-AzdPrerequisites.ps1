#Requires -Version 7.4
# TestCategory: Platform
[CmdletBinding()]
param(
    [switch]$RequireLogin
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This readiness check is Windows-only. Run it from PowerShell 7.4 or later on Windows.'
}

$root = Split-Path (Split-Path $PSScriptRoot)
$manifestPath = Join-Path $root 'azure.yaml'

function Convert-Version {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([a-zA-Z]+)(?:\.(\d+))?)?$') {
        throw "Unsupported semantic version '$Value'."
    }
    [pscustomobject]@{
        Core = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        Label = $Matches[4]
        LabelVersion = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
    }
}

function Test-VersionAtLeast {
    param(
        [Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][string]$Required
    )

    $actual = Convert-Version $Installed
    $minimum = Convert-Version $Required
    if ($actual.Core -gt $minimum.Core) { return $true }
    if ($actual.Core -lt $minimum.Core) { return $false }
    if (!$minimum.Label) { return !$actual.Label }
    if (!$actual.Label) { return $true }
    return $actual.Label -eq $minimum.Label -and $actual.LabelVersion -ge $minimum.LabelVersion
}

function Get-AzdPaths {
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
        if (![string]::IsNullOrWhiteSpace($path) -and (Test-Path $path) -and !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    return $azdPaths
}

$azdPaths = @(Get-AzdPaths)
if ($azdPaths.Count -eq 0) {
    throw 'Azure Developer CLI (azd) is not installed or is not on PATH.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw
if ($manifest -notmatch "(?m)^\s*azd:\s*'>=([^']+)'") {
    throw 'azure.yaml does not declare a minimum azd version.'
}
$requiredAzd = $Matches[1]

$azdCandidates = $azdPaths |
    ForEach-Object {
        $output = & $_ version 2>$null
        if ($LASTEXITCODE -eq 0 -and $output -match 'azd version\s+([^\s]+)') {
            [pscustomobject]@{
                Path = $_
                Version = $Matches[1]
                ParsedVersion = (Convert-Version $Matches[1]).Core
            }
        }
    } |
    Sort-Object ParsedVersion -Descending

$azdCandidate = $azdCandidates |
    Where-Object { Test-VersionAtLeast -Installed $_.Version -Required $requiredAzd } |
    Select-Object -First 1
if (!$azdCandidate) {
    $installed = ($azdCandidates | ForEach-Object Version) -join ', '
    throw "azd $requiredAzd or later is required; installed versions are: $installed. Upgrade azd, reopen PowerShell, and retry."
}
$azdPath = $azdCandidate.Path
$installedAzd = $azdCandidate.Version
$defaultAzdPath = (Get-Command azd -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if ($azdPath -ne $defaultAzdPath) {
    $azdDirectory = Split-Path $azdPath
    Write-Warning "PATH resolves an older azd before $azdPath. This check will use azd $installedAzd. Before direct azd commands in this PowerShell session, run: `$env:Path = '$azdDirectory;' + `$env:Path"
}

$extensionRequirements = [regex]::Matches(
    $manifest,
    "(?m)^\s{4}([a-z0-9.]+):\s*'>=([^']+)'")
if ($extensionRequirements.Count -eq 0) {
    throw 'azure.yaml does not declare required Foundry extensions.'
}
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
try {
    $extensionOutput = & $azdPath ext list --output json
    $extensionExitCode = $LASTEXITCODE
}
finally {
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
}
if ($extensionExitCode -ne 0) {
    throw 'Unable to list azd extensions.'
}
$extensions = $extensionOutput | ConvertFrom-Json
$validatedExtensions = foreach ($requirement in $extensionRequirements) {
    $extensionId = $requirement.Groups[1].Value
    $requiredExtension = $requirement.Groups[2].Value
    $extension = $extensions | Where-Object id -eq $extensionId
    if (!$extension -or !$extension.installedVersion) {
        throw "Missing azd extension $extensionId. Run: azd ext install microsoft.foundry"
    }
    if (!(Test-VersionAtLeast -Installed $extension.installedVersion -Required $requiredExtension)) {
        throw "$extensionId $requiredExtension or later is required; installed version is $($extension.installedVersion)."
    }
    "$extensionId $($extension.installedVersion)"
}

if ($RequireLogin) {
    $previousUserAgent = $env:AZURE_DEV_USER_AGENT
    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
    try {
        & $azdPath auth login --check-status | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'azd authentication is missing or expired. Run azd auth login and retry.'
        }
    }
    finally {
        $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    }
}

Write-Host "azd readiness passed: azd $installedAzd, $($validatedExtensions -join ', ')."
if (!$RequireLogin) {
    Write-Host 'Authentication was not checked. Add -RequireLogin before deployment.'
}
