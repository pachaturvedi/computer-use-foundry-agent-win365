#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path (Split-Path $PSScriptRoot)),
    [string]$ProductionRoot = (Join-Path $RepositoryRoot 'scripts'),
    [string]$TestRoot = $PSScriptRoot,
    [ValidateSet('Offline', 'Platform', 'Live')]
    [string[]]$Category = @('Offline')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$powerShellExecutable = (Get-Process -Id $PID).Path

foreach ($path in @($RepositoryRoot, $ProductionRoot, $TestRoot)) {
    if (!(Test-Path -LiteralPath $path -PathType Container)) {
        throw "PowerShell test driver path '$path' was not found."
    }
}

$powerShellFiles = @(
    Get-ChildItem -LiteralPath $ProductionRoot -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath $TestRoot -Recurse -File -Filter '*.ps1'
) | Sort-Object FullName -Unique

$parseFailures = @()
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors) | Out-Null
    foreach ($error in $errors) {
        $parseFailures += "$($file.FullName): $($error.Message)"
    }
}
if ($parseFailures.Count -gt 0) {
    throw "PowerShell parsing failed:`n$($parseFailures -join "`n")"
}

$testFiles = @(
    Get-ChildItem -LiteralPath $TestRoot -Recurse -File -Filter 'Test-*.ps1' |
        Sort-Object FullName
)
if ($testFiles.Count -eq 0) {
    throw "No Test-*.ps1 files were found under '$TestRoot'."
}

$tests = foreach ($file in $testFiles) {
    $markers = foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $match = [regex]::Match($line, '^\s*#\s*TestCategory:\s*(\S+)\s*$')
        if ($match.Success) {
            $match.Groups[1].Value
        }
        elseif ($line -notmatch '^\s*(#.*)?$') {
            break
        }
    }
    $markers = @($markers)
    if ($markers.Count -ne 1) {
        throw "Test '$($file.FullName)' must declare exactly one leading '# TestCategory: Offline|Platform|Live' marker."
    }
    if ($markers[0] -notin @('Offline', 'Platform', 'Live')) {
        throw "Test '$($file.FullName)' declares unknown category '$($markers[0])'."
    }

    [pscustomobject]@{
        File = $file
        Category = $markers[0]
    }
}

$selectedTests = @($tests | Where-Object Category -in $Category)
$excludedTests = @($tests | Where-Object Category -notin $Category)
Write-Host "Parsed $($powerShellFiles.Count) PowerShell files."
Write-Host "Selected $($selectedTests.Count) test(s): $($Category -join ', ')."
foreach ($test in $excludedTests) {
    Write-Host "Excluded [$($test.Category)] $($test.File.Name)"
}
if ($selectedTests.Count -eq 0) {
    throw "No tests matched category selection '$($Category -join ', ')'."
}

foreach ($test in $selectedTests) {
    $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $test.File.FullName)
    Write-Host ''
    Write-Host "Running [$($test.Category)] $relativePath"
    & $powerShellExecutable -NoLogo -NoProfile -File $test.File.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "PowerShell test '$relativePath' failed with exit code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host "PowerShell test driver passed $($selectedTests.Count) test(s)."
