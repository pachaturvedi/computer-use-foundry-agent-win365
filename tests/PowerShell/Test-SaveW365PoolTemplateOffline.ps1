#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:scopes = @('CloudPC.Read.All')
    $script:connectCalls = 0
    $script:connectShouldFail = $false
    $script:timeoutFailuresRemaining = 0
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode)
        $script:connectCalls += 1
        if ($script:timeoutFailuresRemaining -gt 0) {
            $script:timeoutFailuresRemaining -= 1
            throw 'Authentication timed out after 120 seconds due to inactivity. Please try again.'
        }
        if ($script:connectShouldFail) {
            throw 'Simulated Graph interactive failure.'
        }
        if ($TenantId) {
            $script:tenant = $TenantId.ToString()
        }
        $script:scopes = $Scopes
    }
    function Get-MgContext {
        @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes }
    }
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers)
        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        if ($Method -ne 'GET') {
            throw "Unexpected method: $Method"
        }
        if ($path -ne 'beta/deviceManagement/virtualEndpoint/cloudPcPools/8607571b-2177-462c-bd6f-b8d1dac75333') {
            throw "Unexpected path: $path"
        }

        return @{
            '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
            id = '8607571b-2177-462c-bd6f-b8d1dac75333'
            displayName = 'su-cua-test'
            description = 'source description'
            billingConfiguration = @{ billingType = 'payAsYouGo'; billingPlanId = '66666666-6666-6666-6666-666666666666' }
            capabilities = @{ enableSingleSignOn = $false }
            cloudPcConfiguration = @{ imageId = 'gallery-image'; imageType = 'gallery'; osLocale = 'en-US' }
            networkConfiguration = @{ geographicLocationType = 'usCentral'; regionGroups = @(@{ regionGroup = 'usCentral'; regions = @('centralus') }) }
            scalingPolicy = @{ minimumCount = 2; maximumCount = 2 }
        }
    }
    function Get-ConnectCalls {
        $script:connectCalls
    }
    function Set-ConnectFailure {
        param([bool]$Value)
        $script:connectShouldFail = $Value
    }
    function Set-ConnectTimeoutFailures {
        param([int]$Value)
        $script:timeoutFailuresRemaining = $Value
    }
    function Reset-GraphState {
        $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:scopes = @()
        $script:connectCalls = 0
        $script:connectShouldFail = $false
        $script:timeoutFailuresRemaining = 0
    }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Get-ConnectCalls, Set-ConnectFailure, Set-ConnectTimeoutFailures, Reset-GraphState
}

$module | Import-Module -Global
$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$tempPath = Join-Path $env:TEMP 'w365-pool-template-test.json'
$script:AzCalls = 0
function global:az {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $argumentList = @($Arguments)
    if ($argumentList.Count -ge 3 -and $argumentList[0] -eq 'account' -and $argumentList[1] -eq 'get-access-token') {
        $script:AzCalls += 1
        return '{"tenant":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","accessToken":"offline-token"}'
    }

    throw "Unexpected az invocation: $($argumentList -join ' ')"
}
function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers)

    if ($Method -ne 'GET') {
        throw "Unexpected REST method: $Method"
    }
    if ($Uri -ne 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPcPools/8607571b-2177-462c-bd6f-b8d1dac75333') {
        throw "Unexpected REST URI: $Uri"
    }
    if ($Headers.Authorization -ne 'Bearer offline-token') {
        throw 'Azure CLI Graph token was not passed to the REST request.'
    }

    return [pscustomobject]@{
        '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
        id = '8607571b-2177-462c-bd6f-b8d1dac75333'
        displayName = 'su-cua-test'
        description = 'source description'
        billingConfiguration = [pscustomobject]@{ billingType = 'payAsYouGo'; billingPlanId = '66666666-6666-6666-6666-666666666666' }
        capabilities = [pscustomobject]@{ enableSingleSignOn = $false }
        cloudPcConfiguration = [pscustomobject]@{ imageId = 'gallery-image'; imageType = 'gallery'; osLocale = 'en-US' }
        networkConfiguration = [pscustomobject]@{ geographicLocationType = 'usCentral'; regionGroups = @([pscustomobject]@{ regionGroup = 'usCentral'; regions = @('centralus') }) }
        scalingPolicy = [pscustomobject]@{ minimumCount = 2; maximumCount = 2 }
    }
}
try {
    Reset-GraphState
    Set-Content -LiteralPath $tempPath -Value @'
{
  "foundry": {
    "agentName": "untouched-agent"
  },
  "w365": {
    "poolDisplayName": "old-name",
    "poolRegionGroup": "old-group"
  }
}
'@

    & "$scriptsRoot\Save-W365PoolTemplate.ps1" `
        -PoolIdOrUrl 'https://intune.microsoft.com/#view/Microsoft_Azure_CloudPC/CloudPCAgentPoolDetail.ReactView/poolId/8607571b-2177-462c-bd6f-b8d1dac75333' `
        -PoolDisplayName 'su-cua-test-clone' `
        -PoolDescription 'updated description' `
        -UseDeviceCode `
        -OutputPath $tempPath | Out-Null

    $saved = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if ($saved.foundry.agentName -ne 'untouched-agent') {
        throw 'Non-W365 config was modified.'
    }
    if ($saved.w365.poolDisplayName -ne 'su-cua-test-clone' -or
        $saved.w365.poolDescription -ne 'updated description' -or
        $saved.w365.poolBillingPlanId -ne '66666666-6666-6666-6666-666666666666' -or
        $saved.w365.poolGeographicLocationType -ne 'usCentral' -or
        $saved.w365.poolRegionGroup -ne 'usCentral' -or
        @($saved.w365.poolRegions) -join ',' -ne 'centralus' -or
        $saved.w365.poolMinimumCount -ne 2 -or
        $saved.w365.poolMaximumCount -ne 2 -or
        $saved.w365.poolTemplateSourceId -ne '8607571b-2177-462c-bd6f-b8d1dac75333') {
        throw 'Pool template values were not updated correctly.'
    }
    if ((Get-ConnectCalls) -ne 1) {
        throw 'Device-code mode should authenticate through Connect-MgGraph first.'
    }
    if ($script:AzCalls -ne 0) {
        throw 'Azure CLI must remain a fallback when device-code auth succeeds.'
    }

    Reset-GraphState
    $script:AzCalls = 0
    Set-ConnectTimeoutFailures -Value 1

    & "$scriptsRoot\Save-W365PoolTemplate.ps1" `
        -PoolIdOrUrl '8607571b-2177-462c-bd6f-b8d1dac75333' `
        -UseDeviceCode `
        -DeviceCodeMaxAttempts 2 `
        -OutputPath $tempPath | Out-Null

    if ((Get-ConnectCalls) -ne 2) {
        throw 'Device-code timeout retry should re-run Connect-MgGraph with a fresh code.'
    }
    if ($script:AzCalls -ne 0) {
        throw 'Azure CLI must not be used when a later device-code retry succeeds.'
    }

    Write-Output 'Offline pool template capture: create-or-update of deployment.local.json values passed.'
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath
    }

    Remove-Module Microsoft.Graph.Authentication
    Remove-Item Function:\global:az -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
}
