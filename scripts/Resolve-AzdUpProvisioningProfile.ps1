#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot) 'config\deployment.defaults.json'),
    [string]$W365DiscoveryScriptPath = (Join-Path $PSScriptRoot 'Get-W365DiscoveryOptions.ps1'),
    [string]$ViewerDiscoveryScriptPath = (Join-Path $PSScriptRoot 'Get-ViewerManagedEnvironments.ps1'),
    [ValidateSet('prompt', 'existing', 'new', 'skip')][string]$W365Mode = 'prompt',
    [ValidateSet('prompt', 'new', 'existing', 'skip')][string]$ViewerMode = 'prompt',
    [guid]$PoolId = [guid]::Empty,
    [guid]$BillingPlanId = [guid]::Empty,
    [string]$ManagedEnvironmentResourceId,
    [switch]$ViewerOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Test-StrictBoolean {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    if ($Value -notin @('true', 'false')) {
        throw "Expected a strict true/false value, received '$Value'."
    }

    return $Value -eq 'true'
}

function Select-ProfileOption {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Options,
        [Parameter(Mandatory)][scriptblock]$Display,
        [int]$DefaultIndex = 0
    )

    if ($Options.Count -eq 0) {
        throw "No compatible $Label options were discovered."
    }

    Write-Host ''
    Write-Host "Select ${Label}:"
    for ($index = 0; $index -lt $Options.Count; $index++) {
        $marker = if ($index -eq $DefaultIndex) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), (& $Display $Options[$index]), $marker)
    }

    while ($true) {
        $answer = Read-Host "Enter 1-$($Options.Count), or press Enter for $($DefaultIndex + 1)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Options[$DefaultIndex]
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

function Resolve-PromptMode {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Modes,
        [Parameter(Mandatory)][string[]]$Descriptions,
        [Parameter(Mandatory)][string]$DefaultMode
    )

    Write-Host ''
    Write-Host "${Label}:"
    for ($index = 0; $index -lt $Modes.Count; $index++) {
        $marker = if ($Modes[$index] -eq $DefaultMode) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($index + 1), $Descriptions[$index], $marker)
    }

    while ($true) {
        $defaultIndex = [array]::IndexOf($Modes, $DefaultMode)
        $answer = Read-Host "Enter 1-$($Modes.Count), or press Enter for $($defaultIndex + 1)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultMode
        }

        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and
            $selection -ge 1 -and
            $selection -le $Modes.Count) {
            return $Modes[$selection - 1]
        }

        Write-Warning "Enter a number from 1 to $($Modes.Count), or press Enter for the default."
    }
}

function Get-DiscoveryResult {
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $json = & $ScriptPath -TenantId $TenantId -UseDeviceCode -AsJson
    if (!$?) {
        throw 'Read-only Windows 365 discovery failed.'
    }

    return ($json | Out-String | ConvertFrom-Json -Depth 20)
}

$environmentPath = Join-Path $RepositoryRoot ".azure\$Environment\.env"
$environmentValues = Read-AzdEnvironmentFile -Path $environmentPath
$config = Read-DeploymentConfigFile -Path $ConfigPath
$updates = [ordered]@{}
$nonInteractive = Test-StrictBoolean -Value ([string]$env:AZD_NON_INTERACTIVE)

if (!$ViewerOnly) {
    $enableW365 = Test-StrictBoolean -Value ([string]$environmentValues['ENABLE_W365'])
    if (!$environmentValues.Contains('ENABLE_W365') -or
        [string]::IsNullOrWhiteSpace([string]$environmentValues['ENABLE_W365'])) {
        $enableW365 = [bool]$config.freshDeployment.enableW365
        $updates['ENABLE_W365'] = $enableW365.ToString().ToLowerInvariant()
        $environmentValues['ENABLE_W365'] = $updates['ENABLE_W365']
    }

    if ($enableW365) {
        $hasExistingPool = ![string]::IsNullOrWhiteSpace([string]$environmentValues['W365_POOL_ID'])
        $configuredBillingPlanId = [guid]::Empty
        $hasBillingPlan = [guid]::TryParse(
            [string]$environmentValues['W365_POOL_BILLING_PLAN_ID'],
            [ref]$configuredBillingPlanId) -and
            $configuredBillingPlanId -ne [guid]::Empty

        if (!$hasExistingPool -and !$hasBillingPlan) {
            $tenantId = [guid]::Empty
            if (![guid]::TryParse([string]$environmentValues['AZURE_TENANT_ID'], [ref]$tenantId) -or
                $tenantId -eq [guid]::Empty) {
                $tenantValue = (& az account show --query tenantId --output tsv 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or
                    ![guid]::TryParse($tenantValue, [ref]$tenantId) -or
                    $tenantId -eq [guid]::Empty) {
                    throw "Azd environment '$Environment' does not contain a valid AZURE_TENANT_ID, and Azure CLI could not resolve one."
                }
                $updates['AZURE_TENANT_ID'] = $tenantId.ToString()
                $environmentValues['AZURE_TENANT_ID'] = $updates['AZURE_TENANT_ID']
            }

            $configuredW365Mode = [string]$environmentValues['W365_ONBOARDING_MODE']
            if ($W365Mode -eq 'prompt' -and
                $configuredW365Mode -in @('existing', 'new', 'skip')) {
                $W365Mode = $configuredW365Mode
            }
            if ($W365Mode -eq 'prompt') {
                if ($nonInteractive) {
                    throw 'Non-interactive W365 setup requires W365_POOL_ID or W365_POOL_BILLING_PLAN_ID before azd up.'
                }
                $W365Mode = Resolve-PromptMode `
                    -Label 'Windows 365 provisioning' `
                    -Modes @('existing', 'new', 'skip') `
                    -Descriptions @(
                        'Reuse an existing Windows 365 agent pool',
                        'Create a new Windows 365 agent pool',
                        'Skip Windows 365 and deploy only the Foundry bootstrap'
                    ) `
                    -DefaultMode 'new'
            }

            if ($W365Mode -eq 'skip') {
                $updates['W365_ONBOARDING_MODE'] = 'skip'
                $updates['ENABLE_W365'] = 'false'
                $updates['DEPLOY_VIEWER'] = 'false'
                $updates['VIEWER_HOSTING_MODE'] = 'skip'
                Set-AzdEnvironmentFileValues -Path $environmentPath -Values $updates
                Write-Host "Windows 365 and the viewer were skipped for azd environment '$Environment'."
                return
            }

            $discovery = Get-DiscoveryResult -TenantId $tenantId -ScriptPath $W365DiscoveryScriptPath
            if ($W365Mode -eq 'existing') {
                $pools = @($discovery.pools)
                $selectedPool = if ($PoolId -ne [guid]::Empty) {
                    @($pools | Where-Object { [string]$_.poolId -eq $PoolId.ToString() })
                }
                elseif ($pools.Count -eq 1) {
                    @($pools[0])
                }
                else {
                    @(Select-ProfileOption `
                        -Label 'Windows 365 agent pool' `
                        -Options $pools `
                        -Display { param($option) "$($option.displayName) [$($option.poolId)]" })
                }
                if ($selectedPool.Count -ne 1) {
                    throw "Windows 365 pool '$PoolId' was not discovered uniquely in tenant '$tenantId'."
                }

                $updates['W365_ONBOARDING_MODE'] = 'existing'
                $updates['W365_POOL_ID'] = [string]$selectedPool[0].poolId
            }
            else {
                $billingPlans = @($discovery.pools |
                    Where-Object { ![string]::IsNullOrWhiteSpace([string]$_.billingPlanId) } |
                    Group-Object billingPlanId |
                    ForEach-Object {
                        [pscustomobject]@{
                            billingPlanId = [string]$_.Name
                            billingType = [string]$_.Group[0].billingType
                            sourcePools = @($_.Group.displayName)
                        }
                    } |
                    Sort-Object billingPlanId)
                $selectedBillingPlan = if ($BillingPlanId -ne [guid]::Empty) {
                    @($billingPlans | Where-Object {
                        [string]$_.billingPlanId -eq $BillingPlanId.ToString()
                    })
                }
                elseif ($billingPlans.Count -eq 1) {
                    @($billingPlans[0])
                }
                elseif ($billingPlans.Count -gt 1) {
                    @(Select-ProfileOption `
                        -Label 'Windows 365 billing plan' `
                        -Options $billingPlans `
                        -Display {
                            param($option)
                            "$($option.billingPlanId) from pool(s): $($option.sourcePools -join ', ')"
                        })
                }
                else {
                    @()
                }

                if ($selectedBillingPlan.Count -eq 0) {
                    if ($nonInteractive) {
                        throw 'No billing plan was discoverable. Set W365_POOL_BILLING_PLAN_ID before non-interactive azd up.'
                    }
                    $enteredBillingPlan = Read-Host 'Enter the tenant Windows 365 pay-as-you-go billing-plan GUID'
                    $parsedBillingPlan = [guid]::Empty
                    if (![guid]::TryParse($enteredBillingPlan, [ref]$parsedBillingPlan) -or
                        $parsedBillingPlan -eq [guid]::Empty) {
                        throw 'The Windows 365 billing-plan ID must be a non-empty GUID.'
                    }
                    $selectedBillingPlan = @([pscustomobject]@{
                        billingPlanId = $parsedBillingPlan.ToString()
                        billingType = 'payAsYouGo'
                    })
                }
                elseif ($selectedBillingPlan.Count -ne 1) {
                    throw "Windows 365 billing plan '$BillingPlanId' was not discovered uniquely."
                }

                $acceptanceDefaults = $config.w365AcceptanceDefaults
                $defaultRegion = [string]@($acceptanceDefaults.poolRegions)[0]
                $regions = @($discovery.regions)
                $selectedRegion = @($regions | Where-Object {
                    [string]$_.id -eq $defaultRegion -or
                    [string]$_.regionName -eq $defaultRegion
                })
                if ($selectedRegion.Count -ne 1) {
                    $selectedRegion = @(Select-ProfileOption `
                        -Label 'Windows 365 region' `
                        -Options $regions `
                        -Display {
                            param($option)
                            "$($option.regionName); geography: $($option.geographicLocationType); group: $($option.regionGroup)"
                        })
                }

                $images = @($discovery.galleryImages)
                $defaultImage = [string]$acceptanceDefaults.poolImageId
                $selectedImage = @($images | Where-Object { [string]$_.id -eq $defaultImage })
                if ($selectedImage.Count -ne 1) {
                    $selectedImage = @(Select-ProfileOption `
                        -Label 'Windows 365 gallery image' `
                        -Options $images `
                        -Display { param($option) "$($option.displayName) [$($option.id)]" })
                }

                $updates['W365_ONBOARDING_MODE'] = 'new'
                $updates['W365_POOL_ID'] = ''
                $updates['W365_POOL_BILLING_PLAN_ID'] = [string]$selectedBillingPlan[0].billingPlanId
                $updates['W365_POOL_BILLING_TYPE'] = if ([string]::IsNullOrWhiteSpace([string]$selectedBillingPlan[0].billingType)) {
                    'payAsYouGo'
                } else {
                    [string]$selectedBillingPlan[0].billingType
                }
                $updates['W365_POOL_GEOGRAPHIC_LOCATION_TYPE'] = [string]$selectedRegion[0].geographicLocationType
                $updates['W365_POOL_REGION_GROUP'] = [string]$selectedRegion[0].regionGroup
                $updates['W365_POOL_REGIONS'] = [string]$selectedRegion[0].regionName
                $updates['W365_POOL_IMAGE_ID'] = [string]$selectedImage[0].id
                $updates['W365_POOL_IMAGE_TYPE'] = 'gallery'
                $updates['W365_POOL_OS_LOCALE'] = 'en-US'
                $updates['W365_POOL_MINIMUM_COUNT'] = '1'
                $updates['W365_POOL_MAXIMUM_COUNT'] = '1'
                $updates['W365_POOL_ENABLE_SINGLE_SIGN_ON'] = 'false'
            }
        }
    }
}

foreach ($entry in $updates.GetEnumerator()) {
    $environmentValues[[string]$entry.Key] = [string]$entry.Value
}

$w365StillEnabled = Test-StrictBoolean -Value ([string]$environmentValues['ENABLE_W365'])
if (!$environmentValues.Contains('ENABLE_W365') -or
    [string]::IsNullOrWhiteSpace([string]$environmentValues['ENABLE_W365'])) {
    $w365StillEnabled = [bool]$config.freshDeployment.enableW365
}

if ($w365StillEnabled) {
    $configuredViewerMode = [string]$environmentValues['VIEWER_HOSTING_MODE']
    if ($ViewerMode -eq 'prompt' -and
        $configuredViewerMode -in @('new', 'existing', 'skip')) {
        $ViewerMode = $configuredViewerMode
    }
    if ($ViewerMode -eq 'prompt') {
        if ($nonInteractive) {
            $ViewerMode = 'new'
        }
        else {
            $ViewerMode = Resolve-PromptMode `
                -Label 'Viewer hosting' `
                -Modes @('new', 'existing', 'skip') `
                -Descriptions @(
                    'Create a new dedicated Azure Container Apps managed environment',
                    'Reuse an existing Azure Container Apps managed environment',
                    'Do not deploy the viewer'
                ) `
                -DefaultMode 'new'
        }
    }

    if ($ViewerMode -eq 'existing') {
        $resolvedResourceId = $ManagedEnvironmentResourceId
        if ([string]::IsNullOrWhiteSpace($resolvedResourceId)) {
            $subscriptionId = [guid]::Empty
            if (![guid]::TryParse([string]$environmentValues['AZURE_SUBSCRIPTION_ID'], [ref]$subscriptionId) -or
                $subscriptionId -eq [guid]::Empty) {
                $subscriptionValue = (& az account show --query id --output tsv 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or
                    ![guid]::TryParse($subscriptionValue, [ref]$subscriptionId) -or
                    $subscriptionId -eq [guid]::Empty) {
                    throw "Azd environment '$Environment' does not contain a valid AZURE_SUBSCRIPTION_ID, and Azure CLI could not resolve one."
                }
                $updates['AZURE_SUBSCRIPTION_ID'] = $subscriptionId.ToString()
                $environmentValues['AZURE_SUBSCRIPTION_ID'] = $updates['AZURE_SUBSCRIPTION_ID']
            }

            $json = & $ViewerDiscoveryScriptPath -SubscriptionId $subscriptionId -SucceededOnly -AsJson
            if (!$?) {
                throw 'Azure Container Apps managed-environment discovery failed.'
            }
            $candidates = @(($json | Out-String | ConvertFrom-Json -Depth 10))
            $selectedEnvironment = if ($candidates.Count -eq 1) {
                $candidates[0]
            }
            else {
                Select-ProfileOption `
                    -Label 'Azure Container Apps managed environment' `
                    -Options $candidates `
                    -Display {
                        param($option)
                        "$($option.Name) in $($option.ResourceGroup) / $($option.Location); $($option.ContainerAppCount) app(s)"
                    }
            }
            $resolvedResourceId = [string]$selectedEnvironment.ResourceId
        }

        Assert-ViewerManagedEnvironmentResourceId -ResourceId $resolvedResourceId
        if (!$ViewerOnly) {
            $updates['DEPLOY_VIEWER'] = 'false'
        }
        $updates['VIEWER_HOSTING_MODE'] = 'existing'
        $updates['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] = $resolvedResourceId
    }
    elseif ($ViewerMode -eq 'skip') {
        $updates['DEPLOY_VIEWER'] = 'false'
        $updates['VIEWER_HOSTING_MODE'] = 'skip'
        $updates['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] = ''
    }
    else {
        if (!$ViewerOnly) {
            $updates['DEPLOY_VIEWER'] = 'false'
        }
        $updates['VIEWER_HOSTING_MODE'] = 'new'
        $updates['VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID'] = ''
    }
}

if ($updates.Count -gt 0) {
    Set-AzdEnvironmentFileValues -Path $environmentPath -Values $updates
    foreach ($entry in $updates.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
}

Write-Host "Post-bootstrap provisioning choices are ready for azd environment '$Environment'."
