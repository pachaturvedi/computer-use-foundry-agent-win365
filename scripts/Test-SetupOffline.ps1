#Requires -Version 7.5
# Exercises the real setup script against an in-memory Graph module. No network calls.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:ledger = @{ Blueprint = $null; Principal = $null; Agent = $null; User = $null; Grants = @(); Inheritance = @(); Assignments = @(); Creates = 0 }
    $script:scopes = @()
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome)
        $script:tenant = $TenantId.ToString(); $script:scopes = $Scopes
    }
    function Get-MgContext { @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes } }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)
        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }
        if ($Method -eq 'GET') {
            if ($path -like 'v1.0/me?*') { return @{ id = 'operator' } }
            if ($path -match "^v1.0/servicePrincipals\?\`$filter=appId eq '([^']+)'") {
                $id = $Matches[1]
                if ($id -eq 'blueprint-app') { return @{ value = @($script:ledger.Principal | Where-Object { $_ }) } }
                $names = switch ($id) {
                    'da81128c-e5b5-4f9e-8d89-50d906f107c5' { @('Tools.ListInvoke.All') }
                    'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1' { @('McpServersMetadata.Read.All') }
                    '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5' { @('Computer.See', 'Computer.Control') }
                    default { throw "Unknown mocked resource $id" }
                }
                return @{ value = @(@{ id = "sp-$id"; appId = $id; oauth2PermissionScopes = @($names | ForEach-Object { @{ id = "scope-$_"; value = $_; isEnabled = $true } }) }) }
            }
            if ($path -like '*cloudPcPools/*/assignments') { return @{ value = $script:ledger.Assignments } }
            if ($path -like '*cloudPcPools/*') { return @{ '@odata.type' = '#microsoft.graph.cloudPcAgentPool' } }
            if ($path.StartsWith('v1.0/applications/microsoft.graph.agentIdentityBlueprint?')) { return @{ value = @($script:ledger.Blueprint | Where-Object { $_ }) } }
            if ($path -eq 'v1.0/applications/blueprint-object/owners') { return @{ value = @(@{ id = 'operator' }) } }
            if ($path -like 'v1.0/applications/blueprint-object?*') { return $script:ledger.Blueprint }
            if ($path -like 'v1.0/oauth2PermissionGrants?*') { return @{ value = $script:ledger.Grants } }
            if ($path -like '*/inheritablePermissions') { return @{ value = $script:ledger.Inheritance } }
            if ($path -like 'v1.0/servicePrincipals/microsoft.graph.agentIdentity?*') { return @{ value = @($script:ledger.Agent | Where-Object { $_ }) } }
            if ($path -like 'beta/users/microsoft.graph.agentUser?*') { return @{ value = @($script:ledger.User | Where-Object { $_ }) } }
        }
        if ($Method -eq 'PATCH') {
            if ($path -eq 'v1.0/applications/blueprint-object') {
                foreach ($key in $bodyObject.Keys) { $script:ledger.Blueprint[$key] = $bodyObject[$key] }
                return
            }
            if ($path -like 'v1.0/oauth2PermissionGrants/*') {
                $grant = $script:ledger.Grants | Where-Object { $_.id -eq $path.Split('/')[-1] }
                $grant.scope = $bodyObject.scope; return
            }
        }
        if ($Method -eq 'POST') {
            $script:ledger.Creates++
            switch -Wildcard ($path) {
                'v1.0/applications' {
                    $script:ledger.Blueprint = @{ id = 'blueprint-object'; appId = 'blueprint-app'; keyCredentials = @(); requiredResourceAccess = @() }
                    return $script:ledger.Blueprint
                }
                'v1.0/servicePrincipals' {
                    $script:ledger.Principal = @{ id = 'blueprint-sp'; appId = 'blueprint-app' }
                    return $script:ledger.Principal
                }
                'v1.0/oauth2PermissionGrants' {
                    $bodyObject.id = "grant-$($script:ledger.Grants.Count)"; $script:ledger.Grants += $bodyObject; return $bodyObject
                }
                '*/inheritablePermissions' { $script:ledger.Inheritance += $bodyObject; return $bodyObject }
                'v1.0/servicePrincipals/microsoft.graph.agentIdentity' {
                    $bodyObject.id = 'agent'; $script:ledger.Agent = $bodyObject; return $bodyObject
                }
                'beta/users/microsoft.graph.agentUser' {
                    $bodyObject.id = 'agent-user'; $script:ledger.User = $bodyObject; return $bodyObject
                }
                '*/assignments' { $script:ledger.Assignments += $bodyObject; return $bodyObject }
            }
        }
        throw "Unexpected mocked Graph request: $Method $path"
    }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest
}
$module | Import-Module -Global
$path = Join-Path ([IO.Path]::GetTempPath()) ("w365-public-test-" + [guid]::NewGuid() + '.cer')
$rsa = [Security.Cryptography.RSA]::Create(2048)
try {
    $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=offline-test', $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddHours(1))
    try { [IO.File]::WriteAllBytes($path, $cert.RawData) } finally { $cert.Dispose() }
    $args = @{
        TenantId = [guid]::Empty; Name = 'offline-sample'; AgentUserPrincipalName = 'agent@example.com'
        CertificatePublicPath = $path; PoolId = [guid]::Empty; BillingConfirmed = $true; Confirm = $false
    }
    & "$PSScriptRoot\Setup-W365.ps1" @args | Out-Null
    $first = & $module { $script:ledger.Creates }
    & "$PSScriptRoot\Setup-W365.ps1" @args | Out-Null
    $second = & $module { $script:ledger.Creates }
    if ($first -ne 11 -or $second -ne $first) { throw "Setup was not idempotent: first=$first second=$second" }
    & $module {
        if ($script:ledger.Blueprint.keyCredentials.Count -ne 1 -or $script:ledger.Grants.Count -ne 3 -or
            $script:ledger.Inheritance.Count -ne 3 -or $script:ledger.Assignments.Count -ne 1) { throw 'Unexpected provisioning result.' }
        $script:ledger.Agent.agentIdentityBlueprintId = 'different-blueprint'
    }
    $rejected = $false
    try { & "$PSScriptRoot\Setup-W365.ps1" @args | Out-Null }
    catch { if ($_.Exception.Message -notlike '*different blueprint*') { throw }; $rejected = $true }
    if (!$rejected) { throw 'Setup adopted an agent from another blueprint.' }
    Write-Output 'Offline setup: identity creation, consent/inheritance, idempotent rerun and parent mismatch passed.'
}
finally {
    $rsa.Dispose()
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Remove-Module Microsoft.Graph.Authentication
}
