#Requires -Version 7.4
# TestCategory: Platform
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
    $script:lastContextScope = ''
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, $ClientTimeout, [switch]$NoWelcome, [switch]$UseDeviceCode)
        $script:connectCalls += 1
        $script:lastContextScope = $ContextScope
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

        if ($path -eq 'beta/deviceManagement/virtualEndpoint/cloudPcPools') {
            return @{
                value = @(
                    @{
                        '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
                        id = '8607571b-2177-462c-bd6f-b8d1dac75333'
                        displayName = 'w365a-billingplan'
                        billingConfiguration = @{ billingType = 'payAsYouGo'; billingPlanId = '66666666-6666-6666-6666-666666666666' }
                        cloudPcConfiguration = @{ imageId = 'gallery-image' }
                        networkConfiguration = @{ geographicLocationType = 'usCentral'; regionGroups = @(@{ regionGroup = 'usCentral'; regions = @('centralus') }) }
                    }
                )
            }
        }
        if ($path -eq 'beta/deviceManagement/virtualEndpoint/supportedRegions') {
            return @{
                value = @(
                    @{
                        id = 'centralus'
                        displayName = 'Central US'
                        regionStatus = 'available'
                        supportedSolution = 'windows365'
                        regionGroup = 'usCentral'
                        geographicLocationType = 'usCentral'
                    },
                    @{
                        id = 'blocked-region'
                        displayName = 'Blocked'
                        regionStatus = 'restricted'
                    }
                )
            }
        }
        if ($path -eq 'beta/deviceManagement/virtualEndpoint/galleryImages') {
            return @{
                value = @(
                    @{
                        id = 'gallery-image'
                        displayName = 'Windows 11 Enterprise 25H2'
                        skuDisplayName = '25H2'
                        recommendedSku = 'light'
                        status = 'supported'
                        expirationDate = '2028-01-01'
                    },
                    @{
                        id = 'expired-image'
                        displayName = 'Expired'
                        status = 'expired'
                    }
                )
            }
        }
        if ($path -eq 'beta/deviceManagement/virtualEndpoint/cloudPcPools/8607571b-2177-462c-bd6f-b8d1dac75333') {
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

        throw "Unexpected path: $path"
    }
    function Get-ConnectCalls {
        $script:connectCalls
    }
    function Get-LastContextScope {
        $script:lastContextScope
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
        $script:lastContextScope = ''
    }
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Get-ConnectCalls, Get-LastContextScope, Set-ConnectFailure, Set-ConnectTimeoutFailures, Reset-GraphState
}

$module | Import-Module -Global
$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$tempPath = Join-Path ([IO.Path]::GetTempPath()) 'w365-pool-template-test.json'
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
    if ((Get-LastContextScope) -ne 'Process') {
        throw 'Direct Graph authentication must use a process-scoped context.'
    }

    Reset-GraphState
    Set-ConnectTimeoutFailures -Value 1

    & "$scriptsRoot\Save-W365PoolTemplate.ps1" `
        -PoolIdOrUrl '8607571b-2177-462c-bd6f-b8d1dac75333' `
        -UseDeviceCode `
        -DeviceCodeMaxAttempts 2 `
        -OutputPath $tempPath | Out-Null

    if ((Get-ConnectCalls) -ne 2) {
        throw 'Device-code timeout retry should re-run Connect-MgGraph with a fresh code.'
    }

    Reset-GraphState
    Set-ConnectFailure -Value $true
    $directFailureReported = $false
    try {
        & "$scriptsRoot\Save-W365PoolTemplate.ps1" `
            -PoolIdOrUrl '8607571b-2177-462c-bd6f-b8d1dac75333' `
            -UseDeviceCode `
            -DeviceCodeMaxAttempts 1 `
            -OutputPath $tempPath | Out-Null
    }
    catch {
        $directFailureReported = $_.Exception.Message -like '*Direct delegated Microsoft Graph sign-in failed*' -and
            $_.Exception.Message -like '*CloudPC.Read.All*' -and
            $_.Exception.Message -like '*Azure CLI tokens are intentionally not used*'
    }
    if (!$directFailureReported) {
        throw 'Direct Graph authentication failures did not provide actionable consent guidance.'
    }

    Reset-GraphState
    Set-ConnectTimeoutFailures -Value 1
    $options = & "$scriptsRoot\Get-W365DiscoveryOptions.ps1" `
        -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
        -UseDeviceCode `
        -DeviceCodeMaxAttempts 2
    if (@($options.pools).Count -ne 1 -or
        $options.pools[0].billingPlanId -ne '66666666-6666-6666-6666-666666666666' -or
        @($options.regions).Count -ne 1 -or
        $options.regions[0].id -ne 'centralus' -or
        @($options.galleryImages).Count -ne 1 -or
        $options.galleryImages[0].id -ne 'gallery-image') {
        throw 'Read-only W365 discovery did not return filtered pools, regions, and images.'
    }
    if ((Get-ConnectCalls) -ne 2) {
        throw 'Read-only discovery should retry a timed-out device-code prompt with a fresh code.'
    }

    $global:W365DiscoveryReadHostResponses = [Collections.Generic.Queue[string]]::new()
    $global:W365DiscoveryReadHostResponses.Enqueue('')
    $global:W365DiscoveryReadHostResponses.Enqueue('')
    $global:W365DiscoveryReadHostResponses.Enqueue('')
    function global:Read-Host {
        param([string]$Prompt)
        if ($global:W365DiscoveryReadHostResponses.Count -eq 0) {
            throw "Unexpected selection prompt: $Prompt"
        }
        return $global:W365DiscoveryReadHostResponses.Dequeue()
    }

    & "$scriptsRoot\Get-W365DiscoveryOptions.ps1" `
        -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
        -UseDeviceCode `
        -Configure `
        -DefaultBillingPlanId '66666666-6666-6666-6666-666666666666' `
        -OutputPath $tempPath

    $configured = Get-Content -LiteralPath $tempPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20
    if ($global:W365DiscoveryReadHostResponses.Count -ne 0 -or
        $configured.w365.poolBillingPlanId -ne '66666666-6666-6666-6666-666666666666' -or
        $configured.w365.poolRegions[0] -ne 'centralus' -or
        $configured.w365.poolImageId -ne 'gallery-image' -or
        $configured.w365.poolMinimumCount -ne 1 -or
        $configured.w365.poolMaximumCount -ne 1) {
        throw 'Guided discovery did not accept and save the configured defaults.'
    }

    Write-Output 'Offline W365 discovery and pool template capture: direct delegated Graph auth passed.'
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath
    }

    Remove-Module Microsoft.Graph.Authentication
    Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
    Remove-Variable W365DiscoveryReadHostResponses -Scope Global -ErrorAction SilentlyContinue
}
