#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$script = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-AzdDeployment.ps1') -Raw

foreach ($required in @(
    'function Get-W365KeyVaultName {',
    'function Assert-W365AgentKeyVaultAccessConfigured {',
    'function Assert-W365AgentCertificateKeyVaultAccessConfigured {',
    "'--version', `$agentVersion",
    "'--new-session'"
)) {
    if ($script -notmatch [regex]::Escape($required)) {
        throw "Deployment wrapper is missing required W365 Key Vault access or version-pinning behavior '$required'."
    }
}

foreach ($retired in @(
    'Set-W365ClientSecretForDeployment',
    '$env:W365_CLIENT_SECRET =',
    'w365ClientSecretInjected'
)) {
    if ($script -match [regex]::Escape($retired)) {
        throw "Deployment wrapper must not inject W365_CLIENT_SECRET ('$retired' found); the hosted agent fetches it directly from Key Vault using its own identity."
    }
}

$optionalValueStart = $script.IndexOf('function Get-AzdOptionalValue {')
$vaultHelperStart = $script.IndexOf('function Get-W365KeyVaultName {')
if ($optionalValueStart -lt 0 -or $vaultHelperStart -lt 0 -or $vaultHelperStart -lt $optionalValueStart) {
    throw 'W365 Key Vault name resolution must be a top-level helper after optional azd value resolution.'
}

Write-Output 'Offline deployment secret injection: W365_CLIENT_SECRET is no longer injected by the wrapper, Key Vault access is confirmed pre-deploy, and version-pinned smoke invocation is present.'
