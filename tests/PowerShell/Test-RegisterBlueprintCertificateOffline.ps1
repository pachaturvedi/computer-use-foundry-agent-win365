#Requires -Version 7.4
# TestCategory: Offline
# All Graph endpoints are mocked. Unexpected calls fail.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testCertificate = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=w365-blueprint-certificate',
    [System.Security.Cryptography.RSA]::Create(2048),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
).CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
$testCertificateBase64 = [Convert]::ToBase64String($testCertificate.RawData)
$testCustomKeyIdentifier = [Convert]::ToBase64String($testCertificate.GetCertHash())

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:blueprintId = '11111111-1111-1111-1111-111111111111'
    $script:tenant = ''
    $script:scopes = @()
    $script:patchCount = 0
    $script:lastKeyCredentials = @()
    $script:ledger = @{
        Blueprint = @{ id = 'blueprint-object'; appId = $script:blueprintId; keyCredentials = @(
            @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; customKeyIdentifier = 'UNRELATEDTHUMBPRINT'; displayName = 'unrelated' }
        ) }
    }

    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, $ClientTimeout, [switch]$NoWelcome, [switch]$UseDeviceCode)
        $script:tenant = $TenantId.ToString(); $script:scopes = $Scopes
    }
    function Get-MgContext { @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes } }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)
        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($Method -eq 'GET') {
            if ($path.StartsWith('v1.0/applications/microsoft.graph.agentIdentityBlueprint?')) {
                return @{ value = @($script:ledger.Blueprint) }
            }
            if ($path.StartsWith('v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint?')) {
                return $script:ledger.Blueprint
            }
        }
        if ($Method -eq 'PATCH' -and $path -eq 'v1.0/applications/blueprint-object/microsoft.graph.agentIdentityBlueprint') {
            if ($bodyObject.Keys.Count -ne 1 -or !$bodyObject.ContainsKey('keyCredentials')) {
                throw 'Attempted to modify blueprint properties other than keyCredentials.'
            }
            $script:patchCount++
            $script:lastKeyCredentials = $bodyObject.keyCredentials
            $script:ledger.Blueprint.keyCredentials = $bodyObject.keyCredentials
            return
        }
        throw "Unexpected mocked Graph request: $Method $path"
    }
    function Get-PatchCount { $script:patchCount }
    function Get-LastKeyCredentials { $script:lastKeyCredentials }
    function Get-RequestedScopes { $script:scopes }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Get-PatchCount, Get-LastKeyCredentials, Get-RequestedScopes
}
$module | Import-Module -Global

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'scripts\Register-W365BlueprintCertificate.ps1'
$tenantId = [guid]'22222222-2222-2222-2222-222222222222'
$blueprintId = [guid]'11111111-1111-1111-1111-111111111111'

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (!$threw) {
        throw $Message
    }
}

try {
    Assert-Throws {
        & $scriptPath -TenantId $tenantId -BlueprintId $blueprintId -PublicCertificateBase64 $testCertificateBase64 -Confirm:$false
    } 'Certificate registration ran without -ConfirmResourceChanges.'
    if ((Get-PatchCount) -ne 0) {
        throw 'A PATCH was issued without explicit resource-change confirmation.'
    }

    & $scriptPath -TenantId $tenantId -BlueprintId $blueprintId -PublicCertificateBase64 $testCertificateBase64 -ConfirmResourceChanges -Confirm:$false
    if ((Get-PatchCount) -ne 1) {
        throw 'Registration did not PATCH the blueprint exactly once.'
    }
    $requestedScopes = @(Get-RequestedScopes)
    if ($requestedScopes.Count -ne 1 -or $requestedScopes[0] -ne 'AgentIdentityBlueprint.AddRemoveCreds.All') {
        throw 'Registration did not request the least-privileged AgentIdentityBlueprint.AddRemoveCreds.All Graph scope.'
    }
    $updated = @(Get-LastKeyCredentials)
    if ($updated.Count -ne 2) {
        throw 'Registration did not preserve the existing keyCredential while adding the new one.'
    }
    if (@($updated | Where-Object { $_.customKeyIdentifier -eq 'UNRELATEDTHUMBPRINT' }).Count -ne 1) {
        throw 'Registration removed an unrelated existing keyCredential.'
    }
    $newCredential = $updated | Where-Object { $_.customKeyIdentifier -ne 'UNRELATEDTHUMBPRINT' }
    if ($null -eq $newCredential -or
        $newCredential.type -ne 'AsymmetricX509Cert' -or
        $newCredential.usage -ne 'Verify' -or
        $newCredential.key -ne $testCertificateBase64 -or
        $newCredential.customKeyIdentifier -ne $testCustomKeyIdentifier) {
        throw 'The new keyCredential was not registered with the expected certificate shape.'
    }

    & $scriptPath -TenantId $tenantId -BlueprintId $blueprintId -PublicCertificateBase64 $testCertificateBase64 -ConfirmResourceChanges -Confirm:$false
    if ((Get-PatchCount) -ne 1) {
        throw 'Re-registering an already-present certificate thumbprint issued a redundant PATCH.'
    }
}
finally {
    Remove-Module Microsoft.Graph.Authentication -Force -ErrorAction SilentlyContinue
}

Write-Host 'Register-W365BlueprintCertificate offline tests passed.'
