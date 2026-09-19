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

function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
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
        return
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

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath $roleSetupPath -Value @'
param([string]$Environment, [switch]$IncludeViewer)
@{ environment = $Environment; includeViewer = $IncludeViewer.IsPresent } | ConvertTo-Json |
    Set-Content -LiteralPath $env:TEST_VIEWER_ROLE_CALL_PATH
'@
    $env:TEST_VIEWER_ROLE_CALL_PATH = $roleCallPath
    $blueprintSecret = ConvertTo-SecureString 'blueprint-value' -AsPlainText -Force
    $oidcSecret = ConvertTo-SecureString 'oidc-value' -AsPlainText -Force
    & (Join-Path $root 'scripts\Set-ViewerSecrets.ps1') `
        -BlueprintClientSecret $blueprintSecret `
        -ViewerOidcClientSecret $oidcSecret `
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
}
finally {
    Remove-Variable -Name viewerSecretWrites -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_VIEWER_ROLE_CALL_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Set-ViewerSecrets offline tests passed.'
