#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$prePrScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Validate-PrePr.ps1') -Raw
$setupScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Setup-Local.ps1') -Raw
$dotNetExecution = Get-Content -LiteralPath (Join-Path $root 'scripts\DotNetExecution.ps1') -Raw
$workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\ci.yml') -Raw
$contributing = Get-Content -LiteralPath (Join-Path $root 'CONTRIBUTING.md') -Raw

foreach ($required in @(
    "'restore', `$solution",
    "'format', `$solution, '--verify-no-changes'",
    "'build', `$solution, '--configuration', 'Release'",
    "'test', `$solution, '--configuration', 'Release', '--no-build'",
    '& $powerShellTests'
)) {
    if ($prePrScript -notmatch [regex]::Escape($required)) {
        throw "Pre-PR validation script is missing required validation step '$required'."
    }
}

if ($dotNetExecution -notmatch [regex]::Escape('dotnet @Arguments') -or
    $dotNetExecution -notmatch [regex]::Escape("failed with exit code `$LASTEXITCODE") -or
    $prePrScript -notmatch [regex]::Escape("Join-Path `$PSScriptRoot 'DotNetExecution.ps1'") -or
    $setupScript -notmatch [regex]::Escape("Join-Path `$PSScriptRoot 'DotNetExecution.ps1'") -or
    $setupScript -notmatch [regex]::Escape("& `$prePrValidationScript") -or
    $workflow -notmatch [regex]::Escape('run: ./scripts/Validate-PrePr.ps1') -or
    $contributing -notmatch [regex]::Escape('pwsh -NoProfile -File .\scripts\Validate-PrePr.ps1')) {
    throw 'The local setup path, CI workflow, and contributor guide must use the shared pre-PR validation gate.'
}

Write-Output 'Offline pre-PR validation: shared local, CI, and contributor gates are aligned.'
