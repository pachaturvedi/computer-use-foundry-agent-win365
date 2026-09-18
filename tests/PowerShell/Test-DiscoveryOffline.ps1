#Requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$module = New-Module -Name FoundryOfflineCli -ScriptBlock {
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:missing = $false
    $script:calls = 0
    function az {
        $script:calls++
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
            return @{ tenantId = $script:tenant } | ConvertTo-Json
        }
        if ($args[0] -eq 'rest' -and $args[1] -eq '--method' -and $args[2] -eq 'get') {
            if ($args -notcontains 'https://ai.azure.com' -or
                $args -notcontains 'https://sample.services.ai.azure.com/api/projects/sample/agents/agent/versions/1?api-version=2025-11-15-preview') {
                throw 'Discovery used an unexpected resource or URL.'
            }
            if ($script:missing) { return '{}' }
            return @{
                blueprint = @{ client_id = '11111111-1111-1111-1111-111111111111' }
                instance_identity = @{ principal_id = '22222222-2222-2222-2222-222222222222'; client_id = '33333333-3333-3333-3333-333333333333' }
            } | ConvertTo-Json
        }
        throw 'Discovery attempted an unexpected Azure CLI operation.'
    }
    Export-ModuleMember -Function az
}
$module | Import-Module -Global
try {
    $parameters = @{
        ProjectEndpoint = 'https://sample.services.ai.azure.com/api/projects/sample'
        AgentName = 'agent'; AgentVersion = '1'; TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    }
    $ids = & "$scriptsRoot\Get-FoundryIdentity.ps1" @parameters
    if ($ids.BlueprintId -ne [guid]'11111111-1111-1111-1111-111111111111' -or
        $ids.AgentIdentityId -ne [guid]'22222222-2222-2222-2222-222222222222') { throw 'Discovery returned the wrong ID types.' }
    & $module { $script:tenant = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
    $rejected = $false
    try { & "$scriptsRoot\Get-FoundryIdentity.ps1" @parameters | Out-Null } catch { $rejected = $true }
    if (!$rejected -or (& $module { $script:calls }) -ne 3) { throw 'Cross-tenant discovery made a Foundry request.' }
    & $module { $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; $script:missing = $true }
    $rejected = $false
    try { & "$scriptsRoot\Get-FoundryIdentity.ps1" @parameters | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Discovery invented missing identity metadata.' }
    $before = & $module { $script:calls }
    $parameters.ProjectEndpoint = 'https://untrusted.example/api/projects/sample'
    $rejected = $false
    try { & "$scriptsRoot\Get-FoundryIdentity.ps1" @parameters | Out-Null } catch { $rejected = $true }
    if (!$rejected -or (& $module { $script:calls }) -ne $before) { throw 'Discovery accepted an untrusted endpoint.' }
    Write-Output 'Offline discovery: read-only metadata, distinct IDs, tenant binding, missing metadata and untrusted endpoint rejection passed.'
}
finally { Remove-Module FoundryOfflineCli }
