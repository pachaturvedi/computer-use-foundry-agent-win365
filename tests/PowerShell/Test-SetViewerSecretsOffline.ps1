#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "viewer-secret-test-$([guid]::NewGuid())"
$roleSetupPath = Join-Path $tempRoot 'Mock-RoleSetup.ps1'
$roleCallPath = Join-Path $tempRoot 'role-call.json'
$global:viewerSecretWrites = [System.Collections.Generic.List[string]]::new()
$savedSecretShowMode = $env:TEST_VIEWER_SECRET_SHOW_MODE
$env:TEST_VIEWER_SECRET_SHOW_MODE = 'missing'
$savedNonInteractive = $env:AZD_NON_INTERACTIVE

function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'select') {
        return
    }
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'get-value') {
        switch ($arguments[2]) {
            'W365_KEY_VAULT_NAME' { return 'single-w365-vault' }
            'AZURE_TENANT_ID' { return '11111111-1111-1111-1111-111111111111' }
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
            return '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample-rg/providers/Microsoft.KeyVault/vaults/single-w365-vault'
        }
        return 'https://single-w365-vault.vault.azure.net/'
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'secret') {
        $global:LASTEXITCODE = 1
        if ($env:TEST_VIEWER_SECRET_SHOW_MODE -eq 'access-denied') {
            return 'Forbidden: caller is not authorized to read this secret.'
        }
        if ($env:TEST_VIEWER_SECRET_SHOW_MODE -eq 'near-match') {
            return 'Provider wrapper reported that a secret alias was not found.'
        }
        return 'SecretNotFound: the requested secret was not found.'
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        return 'vault-token'
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body)

    $global:viewerSecretWrites.Add([string]$Uri)
    return @{}
}

function Read-Host {
    throw 'Read-Host was invoked unexpectedly.'
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath $roleSetupPath -Value @'
param([string]$Environment, [switch]$IncludeViewer)
@{ environment = $Environment; includeViewer = $IncludeViewer.IsPresent } | ConvertTo-Json |
    Set-Content -LiteralPath $env:TEST_VIEWER_ROLE_CALL_PATH
if ($env:TEST_VIEWER_ROLE_GRANTS_ACCESS -eq 'true') {
    $env:TEST_VIEWER_SECRET_SHOW_MODE = 'missing'
}
'@
    $env:TEST_VIEWER_ROLE_CALL_PATH = $roleCallPath
    $blueprintSecret = ConvertTo-SecureString 'blueprint-value' -AsPlainText -Force
    $oidcSecret = ConvertTo-SecureString 'oidc-value' -AsPlainText -Force
    & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
        -BlueprintClientSecret $blueprintSecret `
        -ViewerOidcClientSecret $oidcSecret `
        -BootstrapOperatorAccess `
        -RoleSetupScriptPath $roleSetupPath

    if (!(Test-Path -LiteralPath $roleCallPath)) {
        throw 'The secret hook did not invoke centralized Key Vault RBAC setup.'
    }
    if ($global:viewerSecretWrites.Count -ne 2) {
        throw "Expected two writes to one Key Vault, received $($global:viewerSecretWrites.Count)."
    }
    foreach ($uri in $global:viewerSecretWrites) {
        if ($uri -notmatch '^https://single-w365-vault\.vault\.azure\.net/secrets/') {
            throw "A secret was written outside the single W365 Key Vault: $uri"
        }
    }
    $writtenUris = $global:viewerSecretWrites -join "`n"
    if ($writtenUris -notmatch '/w365-blueprint-client-secret\?' -or
        $writtenUris -notmatch '/w365-viewer-client-secret\?') {
        throw 'The single Key Vault did not receive both required secret names.'
    }

    $env:AZD_NON_INTERACTIVE = 'true'
    Remove-Item -LiteralPath $roleCallPath -Force
    $env:TEST_VIEWER_SECRET_SHOW_MODE = 'access-denied'
    $env:TEST_VIEWER_ROLE_GRANTS_ACCESS = 'true'
    $freshVaultMessage = ''
    try {
        & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
            -Environment 'sample-dev' `
            -BlueprintOnly `
            -BootstrapOperatorAccess `
            -RoleSetupScriptPath $roleSetupPath
    }
    catch {
        $freshVaultMessage = $_.Exception.Message
    }
    if ($freshVaultMessage -notmatch 'Blueprint client secret is missing' -or
        !(Test-Path -LiteralPath $roleCallPath) -or
        $global:viewerSecretWrites.Count -ne 2) {
        throw "Fresh-vault operator bootstrap did not reach the recoverable missing-secret state: $freshVaultMessage"
    }
    Remove-Item -LiteralPath $roleCallPath -Force
    $env:TEST_VIEWER_ROLE_GRANTS_ACCESS = ''
    $env:TEST_VIEWER_SECRET_SHOW_MODE = 'missing'
    $nonInteractiveFailed = $false
    $nonInteractiveMessage = ''
    try {
        & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
            -Environment 'sample-dev' `
            -BlueprintOnly `
            -RoleSetupScriptPath $roleSetupPath
    }
    catch {
        $nonInteractiveMessage = $_.Exception.Message
        $nonInteractiveFailed = $_.Exception.Message -match 'Blueprint client secret is missing' -and
            $_.Exception.Message -match 'Set-ViewerSecrets.ps1' -and
            $_.Exception.Message -match 'attempt-scoped protected Invoke-AzdUp.ps1 block' -and
            $_.Exception.Message -match 'docs\\W365-SETUP.md'
    }
    if (!$nonInteractiveFailed) {
        throw "Non-interactive secret setup did not return exact retry guidance: $nonInteractiveMessage"
    }
    if (Test-Path -LiteralPath $roleCallPath) {
        throw 'Non-interactive missing-secret validation mutated Key Vault RBAC.'
    }

    $env:TEST_VIEWER_SECRET_SHOW_MODE = 'access-denied'
    $accessFailureMessage = ''
    try {
        & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
            -Environment 'sample-dev' `
            -BlueprintOnly `
            -RoleSetupScriptPath $roleSetupPath
    }
    catch {
        $accessFailureMessage = $_.Exception.Message
    }
    if ($accessFailureMessage -notmatch 'Unable to determine whether secret' -or
        $accessFailureMessage -notmatch 'Verify Azure authentication' -or
        (Test-Path -LiteralPath $roleCallPath) -or
        $global:viewerSecretWrites.Count -ne 2) {
        throw "Key Vault access failure was treated as a missing secret or caused mutation: $accessFailureMessage"
    }

    $env:TEST_VIEWER_SECRET_SHOW_MODE = 'near-match'
    $nearMatchMessage = ''
    try {
        & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
            -Environment 'sample-dev' `
            -BlueprintOnly `
            -RoleSetupScriptPath $roleSetupPath
    }
    catch {
        $nearMatchMessage = $_.Exception.Message
    }
    if ($nearMatchMessage -notmatch 'Unable to determine whether secret' -or
        (Test-Path -LiteralPath $roleCallPath) -or
        $global:viewerSecretWrites.Count -ne 2) {
        throw "A generic secret-not-found message was accepted as Azure SecretNotFound: $nearMatchMessage"
    }
}
finally {
    $env:AZD_NON_INTERACTIVE = $savedNonInteractive
    $env:TEST_VIEWER_SECRET_SHOW_MODE = $savedSecretShowMode
    Remove-Item Env:\TEST_VIEWER_ROLE_GRANTS_ACCESS -ErrorAction SilentlyContinue
    Remove-Variable -Name viewerSecretWrites -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_VIEWER_ROLE_CALL_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Set-ViewerSecrets offline tests passed.'
