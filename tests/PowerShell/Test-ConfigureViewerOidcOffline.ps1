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
    RESOURCE_PREFIX = 'sample-dev'
    VIEWER_CLIENT_ID = ''
    VIEWER_IDENTITY_PRINCIPAL_ID = '66666666-6666-6666-6666-666666666666'
}
$global:viewerOidcAzdSets = @{}

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

function Connect-MgGraph { param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode, $InformationAction) }
function Get-MgContext {
    [pscustomobject]@{
        TenantId = '11111111-1111-1111-1111-111111111111'
        AuthType = 'Delegated'
        Scopes = @('Application.ReadWrite.All', 'User.Read')
    }
}
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body)
    $global:viewerOidcGraphCalls.Add([pscustomobject]@{
        Method = [string]$Method; Uri = [string]$Uri; Body = [string]$Body
    })
    $uriText = [string]$Uri
    if ($Method -eq 'GET' -and $uriText -match '/applications\?') { return @{ value = @() } }
    if ($Method -eq 'POST' -and $uriText.EndsWith('/applications')) {
        return @{ id = '22222222-2222-2222-2222-222222222222'; appId = '33333333-3333-3333-3333-333333333333'; displayName = 'sample-dev-viewer' }
    }
    if ($Method -eq 'GET' -and $uriText -match '/servicePrincipals\?') { return @{ value = @() } }
    if ($Method -eq 'POST' -and $uriText.EndsWith('/servicePrincipals')) { return @{ id = '44444444-4444-4444-4444-444444444444' } }
    if ($Method -eq 'GET' -and $uriText -match '/me\?') { return @{ id = '55555555-5555-5555-5555-555555555555' } }
    if ($Method -eq 'GET' -and $uriText -match '/federatedIdentityCredentials') { return @{ value = @() } }
    if ($Method -eq 'POST' -and $uriText -match '/federatedIdentityCredentials$') {
        return @{ id = '77777777-7777-7777-7777-777777777777'; name = 'w365-viewer-66666666-6666-6666-6666-666666666666' }
    }
    throw "Unexpected Graph call: $Method $uriText"
}

try {
    & (Join-Path $root 'scripts\Configure-ViewerOidc.ps1')
    if ($global:viewerOidcAzdSets.VIEWER_CLIENT_ID -ne '33333333-3333-3333-3333-333333333333' -or
        $global:viewerOidcAzdSets.OPERATOR_OBJECT_ID -ne '55555555-5555-5555-5555-555555555555') {
        throw 'OIDC configuration did not persist the expected non-secret IDs.'
    }
    if ($global:viewerOidcGraphCalls.Body -match 'secretText|passwordCredential') {
        throw 'OIDC configuration attempted to create or store a client secret.'
    }
    $ficCreate = $global:viewerOidcGraphCalls |
        Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/federatedIdentityCredentials$' } |
        Select-Object -First 1
    if ($null -eq $ficCreate -or $ficCreate.Body -notmatch
        'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0' -or
        $ficCreate.Body -notmatch '66666666-6666-6666-6666-666666666666' -or
        $ficCreate.Body -notmatch 'api://AzureADTokenExchange') {
        throw 'OIDC configuration did not create the exact viewer UAMI federation.'
    }
    $manifest = Get-Content (Join-Path $manifestDirectory 'viewer-ownership.json') -Raw | ConvertFrom-Json
    if ($manifest.graph.federatedIdentityCredentials.'w365-viewer-66666666-6666-6666-6666-666666666666'.disposition -ne 'created') {
        throw 'OIDC configuration did not record FIC ownership.'
    }
}
finally {
    Remove-Item -LiteralPath $manifestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name viewerOidcGraphCalls, viewerOidcEnvValues, viewerOidcAzdSets -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Configure-ViewerOidc offline tests passed.'
