#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$root = Split-Path $PSScriptRoot
$solution = Join-Path $root 'Win365FoundrySample.slnx'
$powerShellTests = Join-Path $root 'tests\PowerShell\Invoke-PowerShellTests.ps1'

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK is not installed or dotnet is not on PATH.'
}
if (!(Test-Path -LiteralPath $solution)) {
    throw "Solution '$solution' was not found."
}
if (!(Test-Path -LiteralPath $powerShellTests)) {
    throw "PowerShell test driver '$powerShellTests' was not found."
}

Push-Location $root
try {
    Write-Host 'Restoring packages...'
    Invoke-DotNet @('restore', $solution)

    Write-Host 'Verifying C# formatting...'
    Invoke-DotNet @('format', $solution, '--verify-no-changes', '--no-restore', '--verbosity', 'minimal')

    Write-Host 'Building the Release solution...'
    Invoke-DotNet @('build', $solution, '--configuration', 'Release', '--no-restore')

    Write-Host 'Running .NET tests...'
    Invoke-DotNet @('test', $solution, '--configuration', 'Release', '--no-build', '--no-restore')

    Write-Host 'Running all offline PowerShell tests...'
    & $powerShellTests
    if ($LASTEXITCODE -ne 0) {
        throw "Offline PowerShell validation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Write-Host 'Pre-PR validation passed.'
