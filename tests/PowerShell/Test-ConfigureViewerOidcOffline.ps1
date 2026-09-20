#Requires -Version 7.4
# TestCategory: Offline
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$environmentName = "viewer-oidc-test-$([guid]::NewGuid().ToString('N'))"
$manifestDirectory = Join-Path $root ".azure\$environmentName"
$global:viewerOidcGraphCalls = [System.Collections.Generic.List[object]]::new()
$global:viewerOidcEnvValues = @{
    AZURE_ENV_NAME = $environmentName
    AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
    VIEWER_PUBLIC_URL = 'https://viewer.example.com'
    W365_KEY_VAULT_NAME = 'w365-vault'
    RESOURCE_PREFIX = 'sample-dev'
    VIEWER_CLIENT_ID = ''
}
$global:viewerOidcAzdSets = @{}
$global:viewerOidcKeyVaultWrite = $null

function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'get-value') {
        return [string]$global:viewerOidcEnvValues[$arguments[2]]
    }
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'set') {
        $global:viewerOidcAzdSets[$arguments[2]] = [string]$arguments[3]
        return
    }
    throw "Unexpected azd call: $($arguments -join ' ')"
}

function az {
    $arguments = @($args)
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'secret') {
        $global:LASTEXITCODE = 1
        return ''
    }
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
        return 'https://viewer-vault.vault.azure.net/'
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        return 'vault-token'
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

function Connect-MgGraph {}

function Get-MgContext {
    return [pscustomobject]@{
        TenantId = '11111111-1111-1111-1111-111111111111'
        AuthType = 'Delegated'
        Scopes = @('Application.ReadWrite.All', 'User.Read')
    }
}

function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body)

    $global:viewerOidcGraphCalls.Add([pscustomobject]@{
        Method = [string]$Method
        Uri = [string]$Uri
        Body = [string]$Body
    })
    $uriText = [string]$Uri
    if ($Method -eq 'GET' -and $uriText -match '/applications\?') {
        return @{ value = @() }
    }
    if ($Method -eq 'POST' -and $uriText.EndsWith('/applications')) {
        return @{
            id = '22222222-2222-2222-2222-222222222222'
            appId = '33333333-3333-3333-3333-333333333333'
            displayName = 'sample-dev-viewer'
            passwordCredentials = @()
        }
    }
    if ($Method -eq 'GET' -and $uriText -match '/servicePrincipals\?') {
        return @{ value = @() }
    }
    if ($Method -eq 'POST' -and $uriText.EndsWith('/servicePrincipals')) {
        return @{ id = '44444444-4444-4444-4444-444444444444' }
    }
    if ($Method -eq 'GET' -and $uriText -match '/me\?') {
        return @{ id = '55555555-5555-5555-5555-555555555555' }
    }
    if ($Method -eq 'POST' -and $uriText.EndsWith('/addPassword')) {
        return @{
            secretText = 'generated-secret'
            keyId = '66666666-6666-6666-6666-666666666666'
            endDateTime = [DateTimeOffset]::UtcNow.AddDays(90).ToString('o')
        }
    }
    throw "Unexpected Graph call: $Method $uriText"
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body)

    $global:viewerOidcKeyVaultWrite = [pscustomobject]@{
        Method = [string]$Method
        Uri = [string]$Uri
        Body = [string]$Body
    }
    return @{}
}

try {
    & (Join-Path $root 'scripts\Configure-ViewerOidc.ps1')

    if ($global:viewerOidcAzdSets.VIEWER_CLIENT_ID -ne '33333333-3333-3333-3333-333333333333' -or
        $global:viewerOidcAzdSets.OPERATOR_OBJECT_ID -ne '55555555-5555-5555-5555-555555555555') {
        throw 'OIDC configuration did not persist the expected non-secret IDs.'
    }
    if ($null -eq $global:viewerOidcKeyVaultWrite -or
        $global:viewerOidcKeyVaultWrite.Uri -notmatch '/secrets/w365-viewer-client-secret') {
        throw 'OIDC configuration did not write the generated credential to Key Vault.'
    }
    $manifestPath = Join-Path $manifestDirectory 'viewer-ownership.json'
    if (!(Test-Path -LiteralPath $manifestPath)) {
        throw 'OIDC configuration did not record its ownership manifest.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.application.redirectUri -ne 'https://viewer.example.com/signin-oidc') {
        throw 'OIDC configuration recorded the wrong redirect URI.'
    }
    if ($manifest.application.disposition -ne 'created' -or
        $manifest.application.credential.disposition -ne 'created' -or
        $manifest.application.servicePrincipal.disposition -ne 'created') {
        throw 'OIDC configuration did not record created ownership for the viewer application artifacts.'
    }
    $applicationCreate = $global:viewerOidcGraphCalls |
        Where-Object { $_.Method -eq 'POST' -and $_.Uri.EndsWith('/applications') } |
        Select-Object -First 1
    if ($null -eq $applicationCreate -or
        $applicationCreate.Body -notmatch 'https://viewer.example.com/signin-oidc') {
        throw 'OIDC application creation did not enforce the exact viewer callback.'
    }
}
finally {
    Remove-Item -LiteralPath $manifestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name viewerOidcGraphCalls, viewerOidcEnvValues, viewerOidcAzdSets, viewerOidcKeyVaultWrite `
        -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Configure-ViewerOidc offline tests passed.'
