#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentName,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$ExpectedManifestSha256,
    [string]$EvidencePath,
    [switch]$RequireCleanupComplete
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$environmentFile = Join-Path (Join-Path $RepositoryRoot ".azure\$EnvironmentName") '.env'
if (!(Test-Path -LiteralPath $environmentFile -PathType Leaf)) {
    throw "Azd environment file '$environmentFile' was not found."
}

$environmentValues = Read-AzdEnvironmentFile -Path $environmentFile
$state = Get-W365ProvisioningState `
    -RepositoryRoot $RepositoryRoot `
    -EnvironmentName $EnvironmentName `
    -EnvironmentValues $environmentValues
if ($state.Name -ne 'Complete') {
    throw "W365 environment '$EnvironmentName' is '$($state.Name)', not Complete."
}
if ([string]$environmentValues['ENABLE_W365'] -ne 'true' -or
    [string]$environmentValues['W365_ENABLED'] -ne 'true') {
    throw "W365 environment '$EnvironmentName' is not enabled."
}

$agentVersion = [string]$environmentValues['AGENT_WIN365_DESKTOP_AGENT_VERSION']
if ($agentVersion -notmatch '^[0-9]+$') {
    throw "W365 environment '$EnvironmentName' does not contain a deployed hosted-agent version."
}

$manifestHash = (Get-FileHash -LiteralPath $state.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (![string]::IsNullOrWhiteSpace($ExpectedManifestSha256) -and
    $manifestHash -ne $ExpectedManifestSha256.Trim().ToLowerInvariant()) {
    throw "Ownership manifest changed during the acceptance rerun for '$EnvironmentName'."
}

$cleanup = if ($state.Manifest -is [System.Collections.IDictionary] -and
    $state.Manifest.Contains('cleanup')) {
    $state.Manifest['cleanup']
}
else {
    $null
}
$cleanupStatus = if ($cleanup -is [System.Collections.IDictionary] -and $cleanup.Contains('status')) {
    [string]$cleanup['status']
}
else {
    ''
}
$cleanupComplete = $cleanupStatus -eq 'completed'
if ($RequireCleanupComplete -and !$cleanupComplete) {
    throw "Ownership cleanup for '$EnvironmentName' is not complete."
}
if (!$RequireCleanupComplete -and $cleanupComplete) {
    throw "Ownership manifest for '$EnvironmentName' was already cleaned before deployment verification."
}

$agentUserPrincipalName = [string]$environmentValues['W365_AGENT_USER_PRINCIPAL_NAME']
$domain = ($agentUserPrincipalName -split '@', 2)[-1]
$domainKind = if ($domain.EndsWith('.onmicrosoft.com', [StringComparison]::OrdinalIgnoreCase)) {
    'MicrosoftProvided'
}
else {
    'VerifiedCustom'
}

$evidence = [ordered]@{
    schemaVersion = 1
    environment = $EnvironmentName
    state = $state.Name
    w365Enabled = $true
    hostedAgentVersionPresent = $true
    ownershipManifestPresent = $true
    ownershipManifestSha256 = $manifestHash
    agentUserDomainKind = $domainKind
    cleanupComplete = $cleanupComplete
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
}

if (![string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceDirectory = Split-Path -Parent $EvidencePath
    if (![string]::IsNullOrWhiteSpace($evidenceDirectory)) {
        New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
    }
    $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}

[pscustomobject]$evidence
