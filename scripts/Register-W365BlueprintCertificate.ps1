#Requires -Version 7.4
<#
.SYNOPSIS
Registers the public bytes of the w365-blueprint-certificate Key Vault certificate as a trusted
keyCredential on the Foundry Agent ID Blueprint application, enabling key_vault_certificate mode.

.DESCRIPTION
Reads the Blueprint application's existing keyCredentials via Microsoft Graph, and — only if a
credential with the same certificate thumbprint is not already present — appends the new public
certificate and PATCHes the full array back (Graph requires a full read-modify-write; there is no
add-only endpoint for keyCredentials once other credentials already exist). Existing credentials
are never removed. Only the public certificate bytes are ever sent to Graph; this script never
requests, receives, or persists private key material.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$BlueprintId,
    [Parameter(Mandatory)][string]$PublicCertificateBase64,
    [switch]$UseDeviceCode,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$ConfirmResourceChanges
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$ConfirmResourceChanges) {
    throw 'Registering a Blueprint keyCredential mutates the Foundry Agent ID Blueprint application. Re-run with -ConfirmResourceChanges.'
}
if (!$PSCmdlet.ShouldProcess("$BlueprintId", 'Register blueprint certificate keyCredential')) { return }

$certificateBytes = [Convert]::FromBase64String($PublicCertificateBase64)
$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
# customKeyIdentifier is an Edm.Binary property; Graph expects/returns the raw SHA-1 hash bytes
# base64-encoded (not the hex Thumbprint string), so credentials can be matched deterministically
# on re-run without depending on Graph's undocumented auto-fill behavior when it is omitted.
$customKeyIdentifier = [Convert]::ToBase64String($certificate.GetCertHash())

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
# Least-privileged delegated scope for blueprint credential mutation per Microsoft Graph docs
# (agentIdentityBlueprint: update / addKey); this does not grant tenant-wide application write.
$scopes = @('AgentIdentityBlueprint.AddRemoveCreds.All')

function Test-GraphContext {
    param(
        $Context,
        [guid]$RequiredTenantId,
        [string[]]$RequiredScopes
    )

    if ($null -eq $Context) { return $false }
    if ($Context.TenantId -ne $RequiredTenantId.ToString()) { return $false }
    if ($Context.AuthType -ne 'Delegated') { return $false }
    $missingScopes = @($RequiredScopes | Where-Object { $_ -notin $Context.Scopes })
    return $missingScopes.Count -eq 0
}

$context = Get-MgContext
if (!(Test-GraphContext -Context $context -RequiredTenantId $TenantId -RequiredScopes $scopes)) {
    $connectParameters = @{
        TenantId = $TenantId
        Scopes = $scopes
        ClientTimeout = $GraphClientTimeoutSeconds
        ContextScope = 'Process'
        NoWelcome = $true
    }
    if ($UseDeviceCode) {
        $connectParameters.UseDeviceCode = $true
        $connectParameters.InformationAction = 'Continue'
        Write-Host ''
        Write-Host 'Microsoft Graph administrator sign-in is required to register the blueprint certificate.'
        Write-Host 'When the device code appears, open https://login.microsoft.com/device and sign in as an authorized tenant administrator.'
        Write-Host ''
    }
    Connect-MgGraph @connectParameters
    $context = Get-MgContext
}
if ($context.TenantId -ne $TenantId.ToString() -or $context.AuthType -ne 'Delegated') {
    throw 'A delegated Graph connection in the requested tenant is required.'
}
$missing = @($scopes | Where-Object { $_ -notin $context.Scopes })
if ($missing.Count) { throw "Missing Graph scopes: $($missing -join ', ')." }

function Graph([string]$Method, [string]$Path, $Body = $null) {
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://graph.microsoft.com/$Path" }
    if (!([uri]$uri).Host.Equals('graph.microsoft.com')) { throw 'Graph request resolved to an unexpected origin.' }
    $requestParameters = @{ Method = $Method; Uri = $uri; OutputType = 'Hashtable'; Headers = @{ 'OData-Version' = '4.0' } }
    if ($null -ne $Body) {
        $requestParameters.Body = ConvertTo-Json $Body -Depth 30 -Compress
        $requestParameters.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @requestParameters
}
function List([string]$Path) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($Path) {
        if (!$seen.Add($Path)) { throw 'Repeated Graph pagination cursor.' }
        $page = Graph GET $Path
        foreach ($item in $page.value) { $item }
        $Path = $page['@odata.nextLink']
    }
}
function SingleOrNone($Items, [string]$Label) {
    $all = @($Items)
    if ($all.Count -gt 1) { throw "Ambiguous $Label; multiple matches. Resolve manually; no arbitrary object will be reused." }
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}

$blueprint = SingleOrNone (List "v1.0/applications/microsoft.graph.agentIdentityBlueprint?`$filter=appId eq '$BlueprintId'") 'Foundry blueprint app ID'
if (!$blueprint) { throw 'Existing Foundry blueprint is unavailable. Complete phase 1 setup before registering a certificate.' }
# Blueprint-specific reads/updates (including keyCredentials) must target the derived-type segment
# per Microsoft Graph's agentIdentityBlueprint contract; the base /applications/{id} path does not
# apply blueprint-specific validation for this resource.
$bpPath = "v1.0/applications/$($blueprint.id)/microsoft.graph.agentIdentityBlueprint"
$blueprint = Graph GET "$bpPath`?`$select=id,appId,keyCredentials"
if ($blueprint.appId -ne $BlueprintId.ToString()) { throw 'Resolved blueprint does not match the supplied client ID.' }

$existingKeyCredentials = @($blueprint.keyCredentials)
$existingMatch = SingleOrNone @($existingKeyCredentials | Where-Object {
    [string]$_.customKeyIdentifier -eq $customKeyIdentifier
}) 'blueprint keyCredential with this certificate thumbprint'
if ($existingMatch) {
    Write-Host "Certificate thumbprint '$($certificate.Thumbprint)' is already registered as a keyCredential on the blueprint; no change made."
    return
}

$newKeyCredential = @{
    type = 'AsymmetricX509Cert'
    usage = 'Verify'
    key = $PublicCertificateBase64
    customKeyIdentifier = $customKeyIdentifier
    keyId = [guid]::NewGuid().ToString()
    displayName = 'w365-blueprint-certificate'
    startDateTime = $certificate.NotBefore.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    endDateTime = $certificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$updatedKeyCredentials = @($existingKeyCredentials) + $newKeyCredential
Graph PATCH $bpPath @{ keyCredentials = $updatedKeyCredentials } | Out-Null

Write-Host "Registered certificate thumbprint '$($certificate.Thumbprint)' as a keyCredential on blueprint '$BlueprintId'. Existing credentials were preserved."
