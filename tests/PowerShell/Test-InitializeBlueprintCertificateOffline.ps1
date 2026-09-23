#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Initialize-W365BlueprintCertificate.ps1'

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

# A self-signed cert generated purely in-memory for test purposes; used only to produce
# well-formed public 'cer' bytes for the mocked Key Vault REST response. No private key
# material from this test certificate is ever read by the script under test.
$testCertificate = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=w365-blueprint-certificate',
    [System.Security.Cryptography.RSA]::Create(2048),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
).CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
$testCertificateDerBase64Url = [Convert]::ToBase64String($testCertificate.RawData).Replace('+', '-').Replace('/', '_').TrimEnd('=')

$global:testCertificateExists = $false
$global:testCreateCalled = $false
$global:testRoleGranted = $true
$global:testRoleDeleted = $false
$global:testPolicyCompatible = $true

function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'select') { return }
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'get-value') {
        switch ($arguments[2]) {
            'AZURE_SUBSCRIPTION_ID' { return '11111111-1111-1111-1111-111111111111' }
            'W365_KEY_VAULT_NAME' { return 'sample-w365-vault' }
            default { return '' }
        }
    }
    throw "Unexpected azd call: $($arguments -join ' ')"
}

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
        if ($arguments -contains 'id') {
            return '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample-rg/providers/Microsoft.KeyVault/vaults/sample-w365-vault'
        }
        return 'https://sample-w365-vault.vault.azure.net/'
    }
    if ($arguments[0] -eq 'ad' -and $arguments[1] -eq 'signed-in-user') {
        return '77777777-7777-7777-7777-777777777777'
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        if ($global:testRoleGranted) {
            return '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/aaaa'
        }
        return ''
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'create') {
        return '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/temporary'
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'delete') {
        $global:testRoleDeleted = $true
        return
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'show') {
        if ($global:testCertificateExists) {
            if ($arguments -contains 'policy') {
                if ($global:testPolicyCompatible) {
                    return '{"keyProperties":{"exportable":false,"keySize":2048,"keyType":"RSA"},"x509CertificateProperties":{"keyUsage":["digitalSignature"]}}'
                }
                return '{"keyProperties":{"exportable":true,"keySize":2048,"keyType":"RSA"},"x509CertificateProperties":{"keyUsage":["digitalSignature"]}}'
            }
            return 'https://sample-w365-vault.vault.azure.net/certificates/w365-blueprint-certificate/version'
        }
        $global:LASTEXITCODE = 1
        return ''
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'create') {
        $global:testCreateCalled = $true
        $global:testCertificateExists = $true
        return
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'list') {
        return
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'pending') {
        return 'completed'
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        return 'vault-token'
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers)

    if ($Uri -notmatch '^https://sample-w365-vault\.vault\.azure\.net/certificates/w365-blueprint-certificate\?api-version=7\.4$') {
        throw "Unexpected certificate read URI: $Uri"
    }
    return @{ cer = $testCertificateDerBase64Url }
}

try {
    Assert-Throws {
        & $scriptPath -Confirm:$false
    } 'Certificate initialization created a certificate without -ConfirmResourceChanges.'
    if ($global:testCreateCalled) {
        throw 'Certificate creation ran without explicit resource-change confirmation.'
    }

    $result = & $scriptPath -ConfirmResourceChanges -Confirm:$false
    if (!$global:testCreateCalled) {
        throw 'Certificate was not created on first run.'
    }
    if ($result.CertificateName -ne 'w365-blueprint-certificate' -or
        $result.VaultName -ne 'sample-w365-vault' -or
        [string]::IsNullOrWhiteSpace($result.PublicCertificateBase64)) {
        throw 'Certificate initialization did not return the expected public certificate metadata.'
    }
    [Convert]::FromBase64String($result.PublicCertificateBase64) | Out-Null

    $global:testCreateCalled = $false
    $reuseResult = & $scriptPath -ConfirmResourceChanges -Confirm:$false
    if ($global:testCreateCalled) {
        throw 'Re-running without -Rotate created a new certificate instead of reusing the existing one.'
    }
    if ($reuseResult.PublicCertificateBase64 -ne $result.PublicCertificateBase64) {
        throw 'Reusing an existing certificate returned different public bytes.'
    }

    $global:testPolicyCompatible = $false
    Assert-Throws {
        & $scriptPath -ConfirmResourceChanges -Confirm:$false
    } 'An incompatible exportable certificate policy was reused.'
    $global:testPolicyCompatible = $true

    $global:testCreateCalled = $false
    $rotateResult = & $scriptPath -Rotate -ConfirmResourceChanges -Confirm:$false
    if (!$global:testCreateCalled) {
        throw '-Rotate did not issue a new certificate.'
    }
    if ($null -eq $rotateResult.PublicCertificateBase64) {
        throw 'Rotation did not return public certificate metadata.'
    }

    $global:testRoleGranted = $false
    $temporaryRoleResult = & $scriptPath -ConfirmResourceChanges -Confirm:$false
    if (!$global:testRoleDeleted -or $null -eq $temporaryRoleResult.PublicCertificateBase64) {
        throw 'A temporary Key Vault Certificates Officer assignment was not revoked after certificate reuse.'
    }
    Assert-Throws {
        & $scriptPath -Confirm:$false
    } 'Missing Key Vault Certificates Officer role was not enforced without -ConfirmResourceChanges.'
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\azd -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Variable -Name testCertificateExists, testCreateCalled, testRoleGranted, testRoleDeleted, testPolicyCompatible -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Initialize-W365BlueprintCertificate offline tests passed.'
