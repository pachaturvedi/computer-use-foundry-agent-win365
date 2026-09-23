#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$stateVault = Get-Content -LiteralPath (Join-Path $root 'infra\state\keyvault.bicep') -Raw
$stateMain = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.bicep') -Raw
$stateParameters = Get-Content -LiteralPath (Join-Path $root 'infra\state\main.parameters.json') -Raw
$viewer = Get-Content -LiteralPath (Join-Path $root 'infra\viewer.bicep') -Raw
$viewerMain = Get-Content -LiteralPath (Join-Path $root 'infra\viewer\main.bicep') -Raw
$deployment = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-AzdDeployment.ps1') -Raw
$activation = Get-Content -LiteralPath (Join-Path $root 'scripts\Enable-ViewerLive.ps1') -Raw

if ($stateVault -notmatch '\(certificateProvisioningActive \|\| certificateRbacReady\)' -or
    $viewer -notmatch '\(certificateProvisioningActive \|\| certificateRbacReady\)' -or
    $stateMain -notmatch "certificateRbacReady:\s*toLower\(w365Enabled\) == 'true'" -or
    $viewerMain -notmatch "certificateRbacReady:\s*toLower\(w365Enabled\) == 'true'" -or
    $stateParameters -notmatch '\$\{W365_ENABLED=false\}') {
    throw 'Certificate RBAC readiness is not derived from transient fresh-flow activation or established W365 completion.'
}

if ($viewer -notmatch 'fail\(' -or
    $viewer -notmatch 'key_vault_certificate viewer provisioning requires the orchestration-owned certificate readiness gate') {
    throw 'Fresh certificate-mode viewer provisioning no longer fails closed before readiness.'
}

if ($deployment -notmatch "'provision'" -or $deployment -notmatch "'--preview'" -or
    $activation -notmatch "'provision', 'viewer'") {
    throw 'Deployment preview/redeploy or live viewer activation no longer uses the shared Bicep readiness contract.'
}

Write-Host 'Certificate viewer provisioning offline tests passed for fresh, preview, activation, and established rerun paths.'
