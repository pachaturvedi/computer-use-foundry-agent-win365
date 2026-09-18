#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$driverPath = Join-Path $PSScriptRoot 'Invoke-PowerShellTests.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("powershell-driver-{0}" -f ([guid]::NewGuid()))
$productionRoot = Join-Path $tempRoot 'scripts'
$testRoot = Join-Path $tempRoot 'tests\PowerShell\Nested'
$runLog = Join-Path $tempRoot 'run.log'
$powerShellExecutable = (Get-Process -Id $PID).Path

try {
    New-Item -ItemType Directory -Path $productionRoot, $testRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $productionRoot 'Valid.ps1') -Value "'valid'"
    Set-Content -LiteralPath (Join-Path $testRoot 'Test-B-Offline.ps1') -Value @"
# TestCategory: Offline
Add-Content -LiteralPath '$runLog' -Value 'B'
"@
    Set-Content -LiteralPath (Join-Path $testRoot 'Test-A-Offline.ps1') -Value @"
# TestCategory: Offline
Add-Content -LiteralPath '$runLog' -Value 'A'
"@
    Set-Content -LiteralPath (Join-Path $testRoot 'Test-Platform.ps1') -Value @'
# TestCategory: Platform
throw 'Platform test must not run during offline validation.'
'@

    & $powerShellExecutable -NoLogo -NoProfile -File $driverPath `
        -RepositoryRoot $tempRoot `
        -ProductionRoot $productionRoot `
        -TestRoot (Split-Path $testRoot)
    if ($LASTEXITCODE -ne 0) {
        throw "Nested offline driver run failed with exit code $LASTEXITCODE."
    }
    $runs = @(Get-Content -LiteralPath $runLog)
    if (($runs -join ',') -ne 'A,B') {
        throw "Offline tests were not discovered recursively in deterministic order: '$($runs -join ',')'."
    }

    $unclassifiedPath = Join-Path $testRoot 'Test-Unclassified.ps1'
    Set-Content -LiteralPath $unclassifiedPath -Value "'unclassified'"
    & $powerShellExecutable -NoLogo -NoProfile -File $driverPath `
        -RepositoryRoot $tempRoot `
        -ProductionRoot $productionRoot `
        -TestRoot (Split-Path $testRoot) 2>$null
    if ($LASTEXITCODE -eq 0) {
        throw 'The driver accepted a test without explicit category metadata.'
    }
    Remove-Item -LiteralPath $unclassifiedPath

    $invalidScriptPath = Join-Path $productionRoot 'Invalid.ps1'
    Set-Content -LiteralPath $invalidScriptPath -Value 'if ('
    & $powerShellExecutable -NoLogo -NoProfile -File $driverPath `
        -RepositoryRoot $tempRoot `
        -ProductionRoot $productionRoot `
        -TestRoot (Split-Path $testRoot) 2>$null
    if ($LASTEXITCODE -eq 0) {
        throw 'The driver accepted a PowerShell parse failure.'
    }
    Remove-Item -LiteralPath $invalidScriptPath

    $failingTestPath = Join-Path $testRoot 'Test-Failing-Offline.ps1'
    Set-Content -LiteralPath $failingTestPath -Value @'
# TestCategory: Offline
throw 'Expected child failure.'
'@
    $failureOutput = & $powerShellExecutable -NoLogo -NoProfile -File $driverPath `
        -RepositoryRoot $tempRoot `
        -ProductionRoot $productionRoot `
        -TestRoot (Split-Path $testRoot) 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        throw 'The driver ignored a failing child test.'
    }
    if ($failureOutput -notmatch [regex]::Escape('Test-Failing-Offline.ps1')) {
        throw "The driver failure did not identify the failing child test: $failureOutput"
    }

    Write-Output 'Offline PowerShell test driver: discovery, order, exclusion, parsing, metadata, and failure propagation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
