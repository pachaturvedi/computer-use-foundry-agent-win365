#Requires -Version 7.4
# TestCategory: Offline

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Initialize-AzdUpPhaseTwo.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "azd-up-phase-two-$([guid]::NewGuid())"
$binPath = Join-Path $tempRoot 'bin'
$callsPath = Join-Path $tempRoot 'calls.txt'
$identityCallsPath = Join-Path $tempRoot 'identity-calls.json'
$mockAzdPath = Join-Path $binPath 'azd.cmd'
$mockAzdScriptPath = Join-Path $binPath 'Mock-Azd.ps1'
$mockIdentityPath = Join-Path $tempRoot 'Mock-FoundryIdentity.ps1'
$mockProfilePath = Join-Path $tempRoot 'Mock-ProvisioningProfile.ps1'
$profileCallsPath = Join-Path $tempRoot 'profile-calls.json'
$previousPath = $env:Path
$previousCallsPath = $env:TEST_AZD_CALLS_PATH
$previousQuotaBehavior = $env:TEST_AZD_VIEWER_QUOTA_ONCE
$previousStateMode = $env:TEST_AZD_STATE_MODE
$previousViewerFailure = $env:TEST_AZD_VIEWER_FAILURE
$previousCredentialMode = $env:TEST_AZD_CREDENTIAL_MODE
$previousPersistedCertificateGate = $env:TEST_AZD_PERSISTED_CERT_GATE
$previousCertificateGate = $env:W365_CERTIFICATE_PROVISIONING_ACTIVE
$previousCertificatePreflightFailure = $env:TEST_CERTIFICATE_PREFLIGHT_FAILURE

$testCertificate = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=w365-blueprint-certificate',
    [System.Security.Cryptography.RSA]::Create(2048),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
).CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(1))
$testCertificateBase64Url = [Convert]::ToBase64String($testCertificate.RawData).Replace('+', '-').Replace('/', '_').TrimEnd('=')
$testCertificateKeyIdentifier = [Convert]::ToBase64String($testCertificate.GetCertHash())

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate') {
        if ($env:TEST_CERTIFICATE_PREFLIGHT_FAILURE -eq 'true') {
            $global:LASTEXITCODE = 1
            return ''
        }
        return 'https://sample-w365-vault.vault.azure.net/certificates/w365-blueprint-certificate/version'
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
        return 'https://sample-w365-vault.vault.azure.net/'
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        return 'mock-access-token'
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers)

    if ($Uri -like 'https://sample-w365-vault.vault.azure.net/certificates/*') {
        return @{ cer = $testCertificateBase64Url }
    }
    if ($Uri -like 'https://graph.microsoft.com/*') {
        return @{ keyCredentials = @(@{ customKeyIdentifier = $testCertificateKeyIdentifier }) }
    }
    throw "Unexpected REST request: $Method $Uri"
}

try {
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
    Set-Content -LiteralPath $mockAzdScriptPath -Value @'
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CommandArgs
)
$global:LASTEXITCODE = 0
if ($CommandArgs[0] -eq 'version') {
    Write-Output 'azd version 99.0.0'
    return
}
Add-Content -LiteralPath $env:TEST_AZD_CALLS_PATH -Value ($CommandArgs -join ' ')
if ($CommandArgs[0] -eq 'provision') {
    Add-Content -LiteralPath $env:TEST_AZD_CALLS_PATH -Value (
        "certificate-gate=$($env:W365_CERTIFICATE_PROVISIONING_ACTIVE) before $($CommandArgs -join ' ')")
}
if ($env:TEST_AZD_VIEWER_QUOTA_ONCE -eq 'true' -and
    $CommandArgs -join ' ' -eq 'provision viewer --environment sample-dev --no-prompt') {
    $viewerCalls = @(Get-Content -LiteralPath $env:TEST_AZD_CALLS_PATH |
        Where-Object { $_ -eq 'provision viewer --environment sample-dev --no-prompt' })
    if ($viewerCalls.Count -eq 1) {
        Write-Output 'MaxNumberOfGlobalEnvironmentsInSubExceeded'
        exit 1
    }
}
if ($CommandArgs -join ' ' -eq 'provision viewer --environment sample-dev --no-prompt') {
    if ($env:VIEWER_PROVISIONING_ACTIVE -ne 'true') {
        Write-Output 'viewer provisioning was not phase-two active'
        exit 1
    }
    if ($env:TEST_AZD_VIEWER_FAILURE -eq 'generic') {
        Write-Output 'simulated viewer provider failure'
        exit 1
    }
    if ($env:TEST_AZD_VIEWER_FAILURE -eq 'quota-always') {
        Write-Output 'MaxNumberOfGlobalEnvironmentsInSubExceeded'
        exit 1
    }
}
if ($CommandArgs[0] -eq 'env' -and $CommandArgs[1] -eq 'get-value') {
    $storageName = if ($env:TEST_AZD_STATE_MODE -eq 'missing') { '' } else { 'samplestatestorage' }
    $sessionBlobUri = switch ($env:TEST_AZD_STATE_MODE) {
        'inconsistent' { 'https://differentstorage.blob.core.windows.net/desktop-state/slot.json' }
        'missing' { '' }
        'query' { 'https://samplestatestorage.blob.core.windows.net/desktop-state/slot.json?sig=unexpected' }
        'fragment' { 'https://samplestatestorage.blob.core.windows.net/desktop-state/slot.json#unexpected' }
        'port' { 'https://samplestatestorage.blob.core.windows.net:8443/desktop-state/slot.json' }
        'userinfo' { 'https://unexpected@samplestatestorage.blob.core.windows.net/desktop-state/slot.json' }
        'http' { 'http://samplestatestorage.blob.core.windows.net/desktop-state/slot.json' }
        'wrongpath' { 'https://samplestatestorage.blob.core.windows.net/desktop-state/other.json' }
        'casepath' { 'https://samplestatestorage.blob.core.windows.net/Desktop-State/slot.json' }
        'dotsegment' { 'https://samplestatestorage.blob.core.windows.net/desktop-state/extra/../slot.json' }
        'encoded' { 'https://samplestatestorage.blob.core.windows.net/desktop-state/%73lot.json' }
        default { 'https://samplestatestorage.blob.core.windows.net/desktop-state/slot.json' }
    }
    $values = @{
        FOUNDRY_PROJECT_OWNERSHIP = 'managed'
        FOUNDRY_PROJECT_ENDPOINT = 'https://sample.services.ai.azure.com/api/projects/sample-project'
        FOUNDRY_AGENT_NAME = 'win365-desktop-agent'
        AGENT_WIN365_DESKTOP_AGENT_VERSION = '1'
        AZURE_TENANT_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AZURE_SUBSCRIPTION_ID = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        DEPLOY_STATE = 'true'
        STATE_STORAGE_ACCOUNT_NAME = $storageName
        STATE_CONTAINER_NAME = 'desktop-state'
        SESSION_BLOB_URI = $sessionBlobUri
        W365_BLUEPRINT_CREDENTIAL_MODE = $env:TEST_AZD_CREDENTIAL_MODE
        W365_KEY_VAULT_NAME = 'sample-w365-vault'
        W365_CERTIFICATE_PROVISIONING_ACTIVE = $env:TEST_AZD_PERSISTED_CERT_GATE
    }
    Write-Output $values[$CommandArgs[2]]
}
'@
    Set-Content -LiteralPath $mockAzdPath -Value @"
@echo off
pwsh -NoProfile -File "$mockAzdScriptPath" %*
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath $mockProfilePath -Value @'
param(
    [string]$Environment,
    [switch]$ViewerOnly,
    [string]$ViewerMode
)
@{
    environment = $Environment
    viewerOnly = $ViewerOnly.IsPresent
    viewerMode = $ViewerMode
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_PROFILE_CALLS_PATH
'@
    Set-Content -LiteralPath $mockIdentityPath -Value @'
param(
    [uri]$ProjectEndpoint,
    [string]$AgentName,
    [string]$AgentVersion,
    [guid]$TenantId
)
@{
    projectEndpoint = $ProjectEndpoint.AbsoluteUri
    agentName = $AgentName
    agentVersion = $AgentVersion
    tenantId = $TenantId.ToString()
} | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_IDENTITY_CALLS_PATH
[pscustomobject]@{
    TenantId = $TenantId
    BlueprintId = [guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    AgentIdentityId = [guid]'cccccccc-cccc-cccc-cccc-cccccccccccc'
}
'@

    $env:Path = "$binPath;$previousPath"
    $env:TEST_AZD_CALLS_PATH = $callsPath
    $env:TEST_IDENTITY_CALLS_PATH = $identityCallsPath
    $env:TEST_PROFILE_CALLS_PATH = $profileCallsPath

    $stateKeyVaultTemplate = Get-Content -LiteralPath (Join-Path $root 'infra\state\keyvault.bicep') -Raw
    $viewerTemplate = Get-Content -LiteralPath (Join-Path $root 'infra\viewer.bicep') -Raw
    if ($stateKeyVaultTemplate -notmatch
        'agentCertificateRoleAssignmentEnabled\s*=\s*\(certificateProvisioningActive \|\| certificateRbacReady\)' -or
        $viewerTemplate -notmatch
        "certificateEnabled\s*=\s*blueprintCredentialMode == 'key_vault_certificate'\s*&&\s*certificateConfigurationReady") {
        throw 'Certificate-scoped state/viewer RBAC is not gated by orchestration readiness.'
    }

    & $scriptPath `
        -Environment 'sample-dev' `
        -IdentityScriptPath $mockIdentityPath

    $identityCall = Get-Content -LiteralPath $identityCallsPath -Raw | ConvertFrom-Json
    if ($identityCall.projectEndpoint -ne 'https://sample.services.ai.azure.com/api/projects/sample-project' -or
        $identityCall.agentName -ne 'win365-desktop-agent' -or
        $identityCall.agentVersion -ne '1' -or
        $identityCall.tenantId -ne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') {
        throw 'Phase-two initialization did not discover the exact deployed Foundry identity.'
    }

    $calls = @(Get-Content -LiteralPath $callsPath)
    $requiredCalls = @(
        'env select sample-dev',
        'env set ENABLE_W365 true',
        'env set DEPLOY_STATE true',
        'env set STATE_AGENT_PRINCIPAL_ID cccccccc-cccc-cccc-cccc-cccccccccccc',
        'env set DEPLOY_VIEWER false',
        'env set VIEWER_LIVE_ENABLED false',
        'env set W365_BLUEPRINT_CREDENTIAL_MODE key_vault_certificate',
        'env set W365_BLUEPRINT_ID bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        'env set W365_AGENT_OBJECT_ID cccccccc-cccc-cccc-cccc-cccccccccccc',
        'provision state --environment sample-dev --no-prompt',
        'certificate-gate=false before provision state --environment sample-dev --no-prompt'
    )
    foreach ($requiredCall in $requiredCalls) {
        if ($requiredCall -notin $calls) {
            throw "Phase-two initialization did not issue required command: $requiredCall"
        }
    }
    $stateIndex = [array]::IndexOf($calls, 'provision state --environment sample-dev --no-prompt')
    if ($stateIndex -lt 0 -or
        'provision viewer --environment sample-dev --no-prompt' -in $calls -or
        'env set DEPLOY_VIEWER true' -in $calls) {
        throw 'Base phase-two initialization provisioned the viewer before certificate readiness.'
    }
    if ([array]::IndexOf($calls, 'env get-value STATE_STORAGE_ACCOUNT_NAME') -le $stateIndex -or
        [array]::IndexOf($calls, 'env get-value SESSION_BLOB_URI') -le $stateIndex) {
        throw 'Phase-two initialization did not reload state outputs before viewer provisioning.'
    }
    Remove-Item -LiteralPath $callsPath -ErrorAction SilentlyContinue
    & $scriptPath `
        -Environment 'sample-dev' `
        -FinalizeCredentialAccess `
        -DeployViewer `
        -IdentityScriptPath $mockIdentityPath
    $finalizeCalls = @(Get-Content -LiteralPath $callsPath)
    $finalStateIndex = [array]::IndexOf($finalizeCalls, 'provision state --environment sample-dev --no-prompt')
    $viewerIndex = [array]::IndexOf($finalizeCalls, 'provision viewer --environment sample-dev --no-prompt')
    if ($finalStateIndex -lt 0 -or $viewerIndex -le $finalStateIndex -or
        'certificate-gate=true before provision state --environment sample-dev --no-prompt' -notin $finalizeCalls -or
        'certificate-gate=true before provision viewer --environment sample-dev --no-prompt' -notin $finalizeCalls) {
        throw 'Credential finalization did not apply certificate RBAC before provisioning the viewer.'
    }

    Remove-Item -LiteralPath $callsPath -ErrorAction SilentlyContinue
    $env:TEST_AZD_CREDENTIAL_MODE = 'client_secret'
    & $scriptPath -Environment 'sample-dev' -IdentityScriptPath $mockIdentityPath
    $explicitModeCalls = @(Get-Content -LiteralPath $callsPath)
    if ('env set W365_BLUEPRINT_CREDENTIAL_MODE client_secret' -notin $explicitModeCalls -or
        'env set W365_BLUEPRINT_CREDENTIAL_MODE key_vault_certificate' -in $explicitModeCalls) {
        throw 'Phase-two initialization did not preserve an explicitly configured credential mode.'
    }
    $env:TEST_AZD_CREDENTIAL_MODE = ''

    foreach ($stateMode in @('missing', 'inconsistent', 'query', 'fragment', 'port', 'userinfo', 'http', 'wrongpath', 'casepath', 'dotsegment', 'encoded')) {
        Remove-Item -LiteralPath $callsPath -ErrorAction SilentlyContinue
        $env:TEST_AZD_STATE_MODE = $stateMode
        $stateRejected = $false
        try {
            & $scriptPath `
                -Environment 'sample-dev' `
                -IdentityScriptPath $mockIdentityPath
        }
        catch {
            $stateRejected = $_.Exception.Message -match 'Viewer provisioning was not started'
        }
        if (!$stateRejected) {
            throw "Phase-two initialization accepted $stateMode shared-state outputs."
        }
        $rejectedCalls = @(Get-Content -LiteralPath $callsPath)
        if ('env set DEPLOY_VIEWER true' -in $rejectedCalls -or
            'provision viewer --environment sample-dev --no-prompt' -in $rejectedCalls) {
            throw "Phase-two initialization enabled or provisioned the viewer for $stateMode shared state."
        }
    }
    $env:TEST_AZD_STATE_MODE = 'valid'

    Remove-Item -LiteralPath $callsPath -ErrorAction SilentlyContinue
    $env:TEST_CERTIFICATE_PREFLIGHT_FAILURE = 'true'
    $preflightFailureRejected = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -FinalizeCredentialAccess `
            -DeployViewer `
            -IdentityScriptPath $mockIdentityPath
    }
    catch {
        $preflightFailureRejected = $true
    }
    $preflightFailureCalls = @(Get-Content -LiteralPath $callsPath)
    if (!$preflightFailureRejected -or
        'provision state --environment sample-dev --no-prompt' -in $preflightFailureCalls -or
        'provision viewer --environment sample-dev --no-prompt' -in $preflightFailureCalls) {
        throw 'Certificate readiness failure did not stop before state RBAC and viewer provisioning.'
    }
    $env:TEST_CERTIFICATE_PREFLIGHT_FAILURE = ''

    foreach ($failureMode in @('generic', 'quota-always')) {
        Remove-Item -LiteralPath $callsPath, $profileCallsPath -ErrorAction SilentlyContinue
        $env:TEST_AZD_VIEWER_FAILURE = $failureMode
        $viewerFailureRejected = $false
        try {
            & $scriptPath `
                -Environment 'sample-dev' `
                -FinalizeCredentialAccess `
                -DeployViewer `
                -IdentityScriptPath $mockIdentityPath `
                -ProvisioningProfileScriptPath $mockProfilePath
        }
        catch {
            $viewerFailureRejected = $true
        }
        if (!$viewerFailureRejected) {
            throw "Phase-two initialization accepted $failureMode viewer provisioning failure."
        }
        if (![string]::IsNullOrEmpty($env:VIEWER_PROVISIONING_ACTIVE)) {
            throw "Phase-two initialization did not clear transient viewer activation after $failureMode failure."
        }
        if (![string]::IsNullOrEmpty($env:W365_CERTIFICATE_PROVISIONING_ACTIVE)) {
            throw "Phase-two initialization did not clear transient certificate activation after $failureMode failure."
        }
    }
    $env:TEST_AZD_VIEWER_FAILURE = ''

    Remove-Item -LiteralPath $callsPath, $profileCallsPath -ErrorAction SilentlyContinue
    $env:TEST_AZD_VIEWER_QUOTA_ONCE = 'true'
    & $scriptPath `
        -Environment 'sample-dev' `
        -FinalizeCredentialAccess `
        -DeployViewer `
        -IdentityScriptPath $mockIdentityPath `
        -ProvisioningProfileScriptPath $mockProfilePath
    $quotaCalls = @(Get-Content -LiteralPath $callsPath)
    if (@($quotaCalls | Where-Object {
        $_ -eq 'provision viewer --environment sample-dev --no-prompt'
    }).Count -ne 2) {
        throw 'ACA managed-environment quota recovery did not retry only the viewer layer.'
    }
    $profileCall = Get-Content -LiteralPath $profileCallsPath -Raw | ConvertFrom-Json
    if ($profileCall.environment -ne 'sample-dev' -or
        !$profileCall.viewerOnly -or
        $profileCall.viewerMode -ne 'existing') {
        throw 'ACA managed-environment quota recovery did not request explicit existing-environment selection.'
    }

    Remove-Item -LiteralPath $callsPath -ErrorAction SilentlyContinue
    $env:TEST_AZD_PERSISTED_CERT_GATE = 'true'
    $persistedGateRejected = $false
    try {
        & $scriptPath -Environment 'sample-dev' -IdentityScriptPath $mockIdentityPath
    }
    catch {
        $persistedGateRejected = $_.Exception.Message -match 'orchestration-owned'
    }
    $persistedGateProvisionedState = (Test-Path -LiteralPath $callsPath) -and
        ('provision state --environment sample-dev --no-prompt' -in @(Get-Content -LiteralPath $callsPath))
    if (!$persistedGateRejected -or $persistedGateProvisionedState) {
        throw 'Phase-two initialization accepted an unsafe persisted certificate activation gate.'
    }

    Write-Host 'azd up phase-two initialization offline test passed.'
}
finally {
    $env:Path = $previousPath
    $env:TEST_AZD_CALLS_PATH = $previousCallsPath
    $env:TEST_AZD_VIEWER_QUOTA_ONCE = $previousQuotaBehavior
    $env:TEST_AZD_STATE_MODE = $previousStateMode
    $env:TEST_AZD_VIEWER_FAILURE = $previousViewerFailure
    $env:TEST_AZD_CREDENTIAL_MODE = $previousCredentialMode
    $env:TEST_AZD_PERSISTED_CERT_GATE = $previousPersistedCertificateGate
    $env:W365_CERTIFICATE_PROVISIONING_ACTIVE = $previousCertificateGate
    $env:TEST_CERTIFICATE_PREFLIGHT_FAILURE = $previousCertificatePreflightFailure
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_IDENTITY_CALLS_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_PROFILE_CALLS_PATH -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
