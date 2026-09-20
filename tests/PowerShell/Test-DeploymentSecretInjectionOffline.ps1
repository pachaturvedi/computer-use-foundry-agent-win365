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
    "Set-AzdSecretValue -Name 'W365_CLIENT_SECRET' -Value `$secret",
    '$script:w365ClientSecretPersistedForDeployment = $true',
    '& $azd.Path env set W365_CLIENT_SECRET ''''',
    "'--version', `$agentVersion",
    "'--new-session'"
)) {
    if ($script -notmatch [regex]::Escape($required)) {
        throw "Deployment wrapper is missing required W365 secret or version-pinning behavior '$required'."
    }
}

$optionalValueStart = $script.IndexOf('function Get-AzdOptionalValue {')
$vaultHelperStart = $script.IndexOf('function Get-W365KeyVaultName {')
if ($optionalValueStart -lt 0 -or $vaultHelperStart -lt 0 -or $vaultHelperStart -lt $optionalValueStart) {
    throw 'W365 Key Vault name resolution must be a top-level helper after optional azd value resolution.'
}

Write-Output 'Offline deployment secret injection: temporary azd secret handoff and version-pinned smoke invocation are present.'
