#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:scopes = @('CloudPC.Read.All')
    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome)
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
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest
}

$module | Import-Module -Global
$tempPath = Join-Path $env:TEMP 'w365-pool-template-test.json'
try {
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

    & "$PSScriptRoot\Save-W365PoolTemplate.ps1" `
        -PoolIdOrUrl 'https://intune.microsoft.com/#view/Microsoft_Azure_CloudPC/CloudPCAgentPoolDetail.ReactView/poolId/8607571b-2177-462c-bd6f-b8d1dac75333' `
        -PoolDisplayName 'su-cua-test-clone' `
        -PoolDescription 'updated description' `
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

    Write-Output 'Offline pool template capture: create-or-update of deployment.local.json values passed.'
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath
    }

    Remove-Module Microsoft.Graph.Authentication
}
