#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This bootstrap is Windows-only. Use Windows with PowerShell 7.4 or later.'
}

$root = Split-Path $PSScriptRoot
$solution = Join-Path $root 'Win365FoundrySample.slnx'
$envExample = Join-Path $root '.env.example'
$envFile = Join-Path $root '.env'

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK is not installed or dotnet is not on PATH. Install the .NET 10 SDK, reopen PowerShell, and retry.'
}

$hasDotNet10 = dotnet --list-sdks | Where-Object { $_ -match '^10\.' }
if (!$hasDotNet10) {
    throw 'The .NET 10 SDK is required. Install it, reopen PowerShell, and retry.'
}
$resolvedSdk = dotnet --version
if ($LASTEXITCODE -ne 0 -or $resolvedSdk -notmatch '^10\.') {
    throw "This repository must resolve to a .NET 10 SDK, but dotnet selected '$resolvedSdk'. Check global.json and your SDK installation."
}
Write-Host "Using .NET SDK $resolvedSdk."

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    $visualStudioVersion = & $vswhere -latest -products * -property installationVersion
    if ($visualStudioVersion -and [version]$visualStudioVersion -lt [version]'18.0') {
        Write-Warning "Visual Studio $visualStudioVersion uses MSBuild 17 and cannot load the .NET 10 SDK. It may report MSB4236 ('Microsoft.NET.Sdk' or 'Microsoft.NET.Sdk.Web' could not be found) even when dotnet --info lists .NET 10. Use this CLI workflow or upgrade to Visual Studio 2026 version 18.0 or newer."
    }
}

if (!(Test-Path -LiteralPath $envFile)) {
    Copy-Item -LiteralPath $envExample -Destination $envFile
    Write-Host 'Created .env from .env.example.'
}
else {
    Write-Host 'Using existing .env.'
}

$localSettings = @{}
foreach ($line in [IO.File]::ReadAllLines($envFile)) {
    if ($line.Trim() -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
        $localSettings[$Matches[1]] = $Matches[2].Trim().Trim('"', "'")
    }
}
if ($localSettings['SAMPLE_LOCAL_MODE'] -ne 'true' -or $localSettings['W365_ENABLED'] -ne 'false') {
    throw 'Local bootstrap requires SAMPLE_LOCAL_MODE=true and W365_ENABLED=false in .env.'
}

Push-Location $root
try {
    Write-Host 'Restoring packages...'
    Invoke-DotNet @('restore', $solution)

    Write-Host 'Verifying C# formatting...'
    Invoke-DotNet @('format', $solution, '--verify-no-changes', '--no-restore', '--verbosity', 'minimal')

    Write-Host 'Building the solution...'
    Invoke-DotNet @('build', $solution, '--configuration', 'Release', '--no-restore')

    if (!$SkipTests) {
        Write-Host 'Running offline tests...'
        Invoke-DotNet @('test', $solution, '--configuration', 'Release', '--no-build', '--no-restore')
        & (Join-Path (Split-Path $PSScriptRoot) 'tests\PowerShell\Invoke-PowerShellTests.ps1')
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host 'Local setup is ready.'
Write-Host 'Start the sample with:'
Write-Host '  pwsh -NoProfile -File .\scripts\Start-Local.ps1'
