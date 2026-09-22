#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [switch]$UseDeviceCode,
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 2,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$AsJson,
    [switch]$Configure,
    [guid]$DefaultBillingPlanId = [guid]::Empty,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (!$IsWindows) {
    throw 'W365 discovery is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Select-DiscoveryOption {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Options,
        [Parameter(Mandatory)][scriptblock]$Display,
        [Parameter(Mandatory)][scriptblock]$Identity,
        [string]$DefaultIdentity
    )

    if ($Options.Count -eq 0) {
        throw "No tenant-supported $Label options were discovered."
    }

    $defaultIndex = 0
    $defaultFound = [string]::IsNullOrWhiteSpace($DefaultIdentity)
    if (![string]::IsNullOrWhiteSpace($DefaultIdentity)) {
        for ($index = 0; $index -lt $Options.Count; $index++) {
            if ((& $Identity $Options[$index]) -eq $DefaultIdentity) {
                $defaultIndex = $index
                $defaultFound = $true
                break
            }
        }
    }
    if (!$defaultFound) {
        Write-Warning "Configured $Label '$DefaultIdentity' is not currently available. The first discovered option is selected by default."
    }

    Write-Host ''
    Write-Host "Select ${Label}:"
    for ($index = 0; $index -lt $Options.Count; $index++) {
        $marker = if ($index -eq $defaultIndex) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), (& $Display $Options[$index]), $marker)
    }

    while ($true) {
        $answer = Read-Host "Enter 1-$($Options.Count), or press Enter for $($defaultIndex + 1)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Options[$defaultIndex]
        }

        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and
            $selection -ge 1 -and
            $selection -le $Options.Count) {
            return $Options[$selection - 1]
        }

        Write-Warning "Enter a number from 1 to $($Options.Count), or press Enter for the default."
    }
}

function Test-IsDeviceCodeTimeoutError {
    param([Parameter(Mandatory)]$ErrorRecord)

    return [string]$ErrorRecord.Exception.Message -match 'Authentication timed out after 120 seconds due to inactivity'
}

function Connect-DiscoveryGraph {
    param(
        [Parameter(Mandatory)][hashtable]$ConnectParameters,
        [switch]$UseDeviceCode,
        [ValidateRange(1, 5)][int]$MaxAttempts
    )

    if (!$UseDeviceCode) {
        Connect-MgGraph @ConnectParameters
        return
    }

    Write-Host ''
    Write-Host 'Microsoft Graph sign-in is required for read-only W365 discovery.'
    Write-Host 'When the device code appears:'
    Write-Host '  1. Open https://login.microsoft.com/device in a browser.'
    Write-Host '  2. Enter the displayed code and sign in with an authorized tenant account.'
    Write-Host '  3. Complete the prompt within 120 seconds; this command waits for the result.'
    Write-Host ''

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($MaxAttempts -gt 1) {
                Write-Host "Starting Microsoft Graph device-code sign-in attempt $attempt of $MaxAttempts..."
            }
            Connect-MgGraph @ConnectParameters
            return
        }
        catch {
            if (!(Test-IsDeviceCodeTimeoutError -ErrorRecord $_) -or $attempt -eq $MaxAttempts) {
                throw
            }
            Write-Warning 'Microsoft Graph device-code sign-in timed out. Retrying with a fresh code...'
        }
    }
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scope = 'CloudPC.Read.All'
$context = Get-MgContext
$hasRequiredContext = $null -ne $context -and
    $context.AuthType -eq 'Delegated' -and
    $context.TenantId -eq $TenantId.ToString() -and
    $scope -in $context.Scopes

if (!$hasRequiredContext) {
    $connectParameters = @{
        TenantId = $TenantId
        Scopes = @($scope)
        ContextScope = 'Process'
        ClientTimeout = $GraphClientTimeoutSeconds
        NoWelcome = $true
    }
    if ($UseDeviceCode) {
        $connectParameters.UseDeviceCode = $true
        $connectParameters.InformationAction = 'Continue'
    }

    try {
        Connect-DiscoveryGraph `
            -ConnectParameters $connectParameters `
            -UseDeviceCode:$UseDeviceCode `
            -MaxAttempts $DeviceCodeMaxAttempts
    }
    catch {
        throw @"
Direct delegated Microsoft Graph sign-in failed.
Consent to CloudPC.Read.All is required for read-only W365 discovery.
Rerun with -UseDeviceCode and complete the displayed code promptly.
Azure CLI tokens are intentionally not used for Microsoft Graph discovery.

$($_.Exception.Message)
"@
    }

    $context = Get-MgContext
    if ($null -eq $context -or
        $context.AuthType -ne 'Delegated' -or
        $context.TenantId -ne $TenantId.ToString() -or
        $scope -notin $context.Scopes) {
        throw 'Microsoft Graph authentication did not establish the required delegated CloudPC.Read.All context.'
    }
}

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Path)

    $uri = "https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/$Path"
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri $uri `
        -OutputType Hashtable `
        -Headers @{ 'OData-Version' = '4.0' }
    return @($response.value)
}

$pools = @(Get-GraphCollection -Path 'cloudPcPools' |
    Where-Object { $_.'@odata.type' -eq '#microsoft.graph.cloudPcAgentPool' } |
    ForEach-Object {
        $regionGroups = @($_.networkConfiguration.regionGroups)
        [pscustomobject]@{
            displayName = [string]$_.displayName
            poolId = [string]$_.id
            billingPlanId = [string]$_.billingConfiguration.billingPlanId
            billingType = [string]$_.billingConfiguration.billingType
            geographicLocationType = [string]$_.networkConfiguration.geographicLocationType
            regionGroup = if ($regionGroups.Count -eq 1) { [string]$regionGroups[0].regionGroup } else { '' }
            regions = if ($regionGroups.Count -eq 1) { @($regionGroups[0].regions) } else { @() }
            imageId = [string]$_.cloudPcConfiguration.imageId
        }
    } |
    Sort-Object displayName)

$regions = @(Get-GraphCollection -Path 'supportedRegions' |
    Where-Object { [string]$_.regionStatus -eq 'available' } |
    ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            regionName = [string]$_.displayName
            geographicLocationType = [string]$_.geographicLocationType
            regionGroup = [string]$_.regionGroup
            supportedSolution = [string]$_.supportedSolution
        }
    } |
    Group-Object geographicLocationType, regionGroup, regionName |
    ForEach-Object { $_.Group[0] } |
    Sort-Object regionGroup, regionName)

$images = @(Get-GraphCollection -Path 'galleryImages' |
    Where-Object { [string]$_.status -eq 'supported' } |
    ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            displayName = [string]$_.displayName
            skuDisplayName = [string]$_.skuDisplayName
            recommendedSku = [string]$_.recommendedSku
            expirationDate = [string]$_.expirationDate
        }
    } |
    Sort-Object displayName)

$result = [pscustomobject]@{
    tenantId = $TenantId.ToString()
    pools = $pools
    regions = $regions
    galleryImages = $images
}

if ($Configure) {
    if ($AsJson) {
        throw '-Configure and -AsJson cannot be used together.'
    }

    $repositoryRoot = Split-Path $PSScriptRoot
    $defaults = Read-DeploymentConfigFile -Path (Join-Path $repositoryRoot 'config\deployment.defaults.json')
    $acceptanceDefaults = $defaults.w365AcceptanceDefaults
    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path $repositoryRoot 'config\deployment.local.json'
    }
    elseif ([IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath
    }
    else {
        Join-Path $repositoryRoot $OutputPath
    }
    $localConfig = if (Test-Path -LiteralPath $resolvedOutputPath) {
        Read-DeploymentConfigFile -Path $resolvedOutputPath
    }
    else {
        @{}
    }
    if (!$localConfig.ContainsKey('w365') -or !($localConfig.w365 -is [hashtable])) {
        $localConfig.w365 = @{}
    }

    $configuredBillingPlanId = if ($DefaultBillingPlanId -ne [guid]::Empty) {
        $DefaultBillingPlanId.ToString()
    }
    elseif ($localConfig.w365.ContainsKey('poolBillingPlanId')) {
        [string]$localConfig.w365.poolBillingPlanId
    }
    else {
        ''
    }
    $billingPlans = @($pools |
        Where-Object { ![string]::IsNullOrWhiteSpace($_.billingPlanId) } |
        Group-Object billingPlanId |
        ForEach-Object {
            [pscustomobject]@{
                billingPlanId = [string]$_.Name
                billingType = [string]$_.Group[0].billingType
                sourcePools = @($_.Group.displayName)
            }
        } |
        Sort-Object billingPlanId)
    $selectedBillingPlan = Select-DiscoveryOption `
        -Label 'billing plan' `
        -Options $billingPlans `
        -DefaultIdentity $configuredBillingPlanId `
        -Identity { param($option) $option.billingPlanId } `
        -Display {
            param($option)
            "$($option.billingPlanId) [$($option.billingType)] from pool(s): $($option.sourcePools -join ', ')"
        }

    $defaultRegion = if ($localConfig.w365.ContainsKey('poolRegions') -and @($localConfig.w365.poolRegions).Count -gt 0) {
        [string](@($localConfig.w365.poolRegions)[0])
    }
    else {
        [string](@($acceptanceDefaults.poolRegions)[0])
    }
    $selectedRegion = Select-DiscoveryOption `
        -Label 'W365 region' `
        -Options $regions `
        -DefaultIdentity $defaultRegion `
        -Identity { param($option) $option.regionName } `
        -Display {
            param($option)
            "$($option.regionName); geography: $($option.geographicLocationType); group: $($option.regionGroup)"
        }

    $defaultImage = if ($localConfig.w365.ContainsKey('poolImageId')) {
        [string]$localConfig.w365.poolImageId
    }
    else {
        [string]$acceptanceDefaults.poolImageId
    }
    $selectedImage = Select-DiscoveryOption `
        -Label 'gallery image' `
        -Options $images `
        -DefaultIdentity $defaultImage `
        -Identity { param($option) $option.id } `
        -Display {
            param($option)
            "$($option.displayName) [$($option.id)]"
        }

    $localConfig.w365.poolBillingPlanId = $selectedBillingPlan.billingPlanId
    $localConfig.w365.poolBillingType = $selectedBillingPlan.billingType
    $localConfig.w365.poolGeographicLocationType = $selectedRegion.geographicLocationType
    $localConfig.w365.poolRegionGroup = $selectedRegion.regionGroup
    $localConfig.w365.poolRegions = @($selectedRegion.regionName)
    $localConfig.w365.poolImageId = $selectedImage.id
    $localConfig.w365.poolImageType = 'gallery'
    $localConfig.w365.poolMinimumCount = 1
    $localConfig.w365.poolMaximumCount = 1

    $directory = Split-Path -Parent $resolvedOutputPath
    if (![string]::IsNullOrWhiteSpace($directory) -and !(Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $localConfig | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8

    Write-Host ''
    Write-Host "Saved selected W365 profile to $resolvedOutputPath"
    Write-Host "  Billing plan: $($selectedBillingPlan.billingPlanId)"
    Write-Host "  Region:       $($selectedRegion.regionName)"
    Write-Host "  Image:        $($selectedImage.id)"
}
elseif ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $result
}
