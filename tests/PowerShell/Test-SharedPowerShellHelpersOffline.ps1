#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'scripts\AzdCommand.ps1')
. (Join-Path $root 'scripts\DotNetExecution.ps1')
. (Join-Path $root 'scripts\W365OwnershipManifest.ps1')

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "shared-powershell-helpers-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $fakeAzdPath = Join-Path $temporaryRoot 'fake-azd.cmd'
    @'
@echo off
if "%1"=="fail" exit /b 7
if "%1"=="capture" (
  echo first
  echo second
  exit /b 0
)
echo %*
'@ | Set-Content -LiteralPath $fakeAzdPath

    $azd = [pscustomobject]@{ Path = $fakeAzdPath; Version = [version]'9.9.9' }
    $forwarded = (Invoke-Azd -Azd $azd -Arguments @('alpha', 'beta') | Out-String).Trim()
    if ($forwarded -ne 'alpha beta') {
        throw "Invoke-Azd did not forward arguments; received '$forwarded'."
    }

    $captured = Invoke-Azd -Azd $azd -Arguments @('capture') -CaptureOutput
    if ($captured -notmatch 'first' -or $captured -notmatch 'second') {
        throw 'Invoke-Azd -CaptureOutput did not return the complete command output.'
    }

    $threw = $false
    try {
        Invoke-Azd -Azd $azd -Arguments @('fail') | Out-Null
    }
    catch {
        $threw = $_.Exception.Message -match 'exit code 7'
    }
    if (!$threw) {
        throw 'Invoke-Azd did not surface the nonzero azd exit code.'
    }

    $script:azdValue = '"quoted-value"'
    function azd {
        $global:LASTEXITCODE = 0
        return $script:azdValue
    }

    if ((Get-AzdRequiredValue -Name 'SAMPLE_VALUE') -ne 'quoted-value') {
        throw 'Get-AzdRequiredValue did not trim the quoted environment value.'
    }

    $script:azdValue = ''
    $threw = $false
    try {
        Get-AzdRequiredValue -Name 'MISSING_VALUE' | Out-Null
    }
    catch {
        $threw = $_.Exception.Message -match 'does not contain MISSING_VALUE'
    }
    if (!$threw) {
        throw 'Get-AzdRequiredValue accepted an empty environment value.'
    }

    $script:dotNetArguments = @()
    $script:dotNetExitCode = 0
    function dotnet {
        $script:dotNetArguments = @($args)
        $global:LASTEXITCODE = $script:dotNetExitCode
        return 'dotnet-output'
    }

    $dotNetOutput = (Invoke-DotNet -Arguments @('build', 'sample.slnx') | Out-String).Trim()
    if ($dotNetOutput -ne 'dotnet-output' -or
        ($script:dotNetArguments -join ' ') -ne 'build sample.slnx') {
        throw 'Invoke-DotNet did not forward arguments and output.'
    }

    $script:dotNetExitCode = 9
    $threw = $false
    try {
        Invoke-DotNet -Arguments @('test', 'sample.slnx') | Out-Null
    }
    catch {
        $threw = $_.Exception.Message -match 'exit code 9'
    }
    if (!$threw) {
        throw 'Invoke-DotNet did not surface the nonzero dotnet exit code.'
    }

    if ($null -ne (Get-OptionalObjectValue -Object $null -Name 'value')) {
        throw 'Get-OptionalObjectValue did not return null for a null object.'
    }
    if ((Get-OptionalObjectValue -Object @{ value = 'dictionary' } -Name 'value') -ne 'dictionary') {
        throw 'Get-OptionalObjectValue did not read a dictionary value.'
    }
    if ((Get-OptionalObjectValue -Object ([pscustomobject]@{ value = 'property' }) -Name 'value') -ne 'property') {
        throw 'Get-OptionalObjectValue did not read a PSCustomObject property.'
    }
    if ($null -ne (Get-OptionalObjectValue -Object @{ other = 'value' } -Name 'missing')) {
        throw 'Get-OptionalObjectValue did not return null for an absent value.'
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Shared PowerShell helper offline tests passed.'
