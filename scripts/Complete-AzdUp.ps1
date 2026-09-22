#Requires -Version 7.4
<#
.SYNOPSIS
Completes phase-two setup after the initial azd deployment.

.DESCRIPTION
Orchestrates provisioning-profile selection, shared state, optional viewer bootstrap, W365 setup, viewer activation, guarded agent redeployment, and the final deployment summary.


Key inputs: Repository paths and optional script overrides; AZURE_ENV_NAME and values from the selected azd environment.

.OUTPUTS
Console progress and updated non-secret azd environment values.

.NOTES
Mutating orchestrator. It requires explicit approvals in the delegated setup scripts and never prints credentials.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot) 'config\deployment.defaults.json'),
    [string]$ProvisioningProfileScriptPath = (Join-Path $PSScriptRoot 'Resolve-AzdUpProvisioningProfile.ps1'),
    [string]$PhaseTwoPreparationScriptPath = (Join-Path $PSScriptRoot 'Initialize-AzdUpPhaseTwo.ps1'),
    [string]$W365SetupScriptPath = (Join-Path $PSScriptRoot 'Invoke-W365SetupFlow.ps1'),
    [string]$ViewerBootstrapScriptPath = (Join-Path $PSScriptRoot 'Deploy-ViewerBootstrap.ps1'),
    [string]$ViewerSecretsScriptPath = (Join-Path $PSScriptRoot 'Set-ViewerSecrets.ps1'),
    [string]$ViewerActivationScriptPath = (Join-Path $PSScriptRoot 'Enable-ViewerLive.ps1'),
    [string]$AgentDeploymentScriptPath = (Join-Path $PSScriptRoot 'Invoke-AzdDeployment.ps1'),
    [string]$DeploymentSummaryScriptPath = (Join-Path $PSScriptRoot 'Show-DeploymentSummary.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Test-EnabledValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    if ($Value -notin @('true', 'false')) {
        throw "Expected a strict true/false value, received '$Value'."
    }

    return $Value -eq 'true'
}

function Import-AzdEnvironmentValues {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $environmentPath = Join-Path (Join-Path $Root ".azure\$EnvironmentName") '.env'
    $values = Read-AzdEnvironmentFile -Path $environmentPath
    foreach ($entry in $values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }

    return $values
}

function Resolve-PostUpFlag {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$DefaultValue,
        [switch]$AllowProcessValue
    )

    if ($EnvironmentValues.Contains($Name) -and
        ![string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$Name])) {
        return Test-EnabledValue -Value ([string]$EnvironmentValues[$Name])
    }
    if ($AllowProcessValue) {
        $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if (![string]::IsNullOrWhiteSpace($processValue)) {
            return Test-EnabledValue -Value $processValue
        }
    }

    return $DefaultValue
}

function Confirm-W365PostUpChanges {
    if (Test-EnabledValue -Value $env:W365_RESOURCE_CHANGES_CONFIRMED) {
        return
    }
    if (Test-EnabledValue -Value $env:AZD_NON_INTERACTIVE) {
        throw 'W365 resource changes require interactive approval. For protected automation, set W365_RESOURCE_CHANGES_CONFIRMED=true only for this process.'
    }

    Write-Host ''
    Write-Host 'Windows 365 enablement can create or update an Entra agent user,'
    Write-Host 'a billable Cloud PC agent pool, its assignment, and Graph consent.'
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') {
        throw 'Windows 365 resource changes were not approved.'
    }
}

function Confirm-ViewerLiveActivation {
    if (Test-EnabledValue -Value $env:VIEWER_LIVE_CHANGES_CONFIRMED) {
        return
    }
    if (Test-EnabledValue -Value $env:AZD_NON_INTERACTIVE) {
        throw 'Live viewer activation requires interaction. For protected automation, set VIEWER_LIVE_CHANGES_CONFIRMED=true only for this process.'
    }

    Write-Host ''
    Write-Host 'The viewer hook will create or update one Entra OIDC application,'
    Write-Host 'store its OIDC secret and the existing blueprint secret in the same Key Vault,'
    Write-Host 'and enable the authenticated ACA live-view and take-control routes.'
    $answer = Read-Host 'Type YES to configure the live viewer'
    if ($answer -cne 'YES') {
        throw 'Live viewer activation was not approved.'
    }
}

function Show-PostUpPlan {
    param(
        [bool]$ViewerEnabled,
        [bool]$W365Enabled,
        [bool]$EnableW365,
        [bool]$ViewerLiveEnabled
    )

    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add($(if ($ViewerEnabled) {
        '1. After the Foundry principal is known, provision shared Blob state and the ACA viewer bootstrap.'
    } else {
        '1. After the Foundry principal is known, provision shared Blob state without the optional viewer.'
    }))
    $steps.Add($(if ($EnableW365 -and !$W365Enabled) {
        '2. Build and verify the viewer image, then run interactive Windows 365 setup.'
    } elseif ($W365Enabled) {
        '2. Verify the existing Windows 365 environment and viewer deployment.'
    } else {
        '2. Skip Windows 365 setup because ENABLE_W365 is not true.'
    }))
    $steps.Add($(if ($ViewerEnabled -and $W365Enabled -and !$ViewerLiveEnabled) {
        '3. Activate the authenticated live viewer when OIDC and screen-share prerequisites are present.'
    } else {
        '3. Skip live-viewer activation.'
    }))
    $steps.Add('4. Redeploy the same hosted-agent name after W365 setup and again if viewer activation changes its runtime configuration.')
    $steps.Add('5. Print the final deployment summary table.')

    Write-SampleVerbose -Component 'postup' -Message 'postup plan (runs after azd provision, before this hook exits):'
    foreach ($step in $steps) {
        Write-SampleVerbose -Component 'postup' -Message "  $step"
    }
}

if (Test-EnabledValue -Value $env:W365_POSTUP_IN_PROGRESS) {
    Write-Host 'Nested W365 postup execution skipped.'
    return
}

$environmentName = [string]$env:AZURE_ENV_NAME
if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw 'The azd postup hook requires AZURE_ENV_NAME.'
}
$currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
$defaults = Read-DeploymentConfigFile -Path $ConfigPath
if (!$defaults.ContainsKey('freshDeployment') -or !($defaults.freshDeployment -is [hashtable])) {
    throw "Configuration file '$ConfigPath' must define freshDeployment defaults."
}
$projectOwnership = [string]$currentValues['FOUNDRY_PROJECT_OWNERSHIP']
if ([string]::IsNullOrWhiteSpace($projectOwnership)) {
    $projectOwnership = 'managed'
}
$freshManagedEnvironment = $projectOwnership -eq 'managed'
$enableW365 = Resolve-PostUpFlag `
    -EnvironmentValues $currentValues `
    -Name 'ENABLE_W365' `
    -DefaultValue ($freshManagedEnvironment -and [bool]$defaults.freshDeployment.enableW365) `
    -AllowProcessValue
$deployViewer = Resolve-PostUpFlag `
    -EnvironmentValues $currentValues `
    -Name 'DEPLOY_VIEWER' `
    -DefaultValue ($enableW365 -and [bool]$defaults.freshDeployment.deployViewer)
$w365AlreadyEnabled = Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED'])

Show-PostUpPlan `
    -ViewerEnabled $deployViewer `
    -W365Enabled $w365AlreadyEnabled `
    -EnableW365 $enableW365 `
    -ViewerLiveEnabled (Test-EnabledValue -Value ([string]$currentValues['VIEWER_LIVE_ENABLED']))

if ($enableW365 -and !$w365AlreadyEnabled) {
    Confirm-W365PostUpChanges
    Write-SampleVerbose -Component 'postup' -Message 'Resolving Windows 365 and ACA choices after the Foundry bootstrap is available.'
    & $ProvisioningProfileScriptPath -Environment $environmentName -RepositoryRoot $RepositoryRoot
    if (!$?) {
        throw 'Post-bootstrap provisioning profile resolution failed.'
    }
    $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
    $enableW365 = Test-EnabledValue -Value ([string]$currentValues['ENABLE_W365'])
    $deployViewer = [string]$currentValues['VIEWER_HOSTING_MODE'] -in @('new', 'existing')
}

if ($enableW365 -and !$w365AlreadyEnabled) {
    Write-SampleVerbose -Component 'postup' -Message 'Preparing shared state and viewer infrastructure after phase-one identity discovery.'
    & $PhaseTwoPreparationScriptPath `
        -Environment $environmentName `
        -DeployViewer:$deployViewer
    if (!$?) {
        throw 'Phase-two Azure prerequisite provisioning failed.'
    }
    $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
}

$viewerUrlBefore = [string]$currentValues['VIEWER_PUBLIC_URL']
Write-SampleVerbose -Component 'postup' -Message 'Running viewer bootstrap before enabled W365 deployment.'
Write-SampleDebug -Component 'postup' -Message "Viewer URL existed before bootstrap: $(![string]::IsNullOrWhiteSpace($viewerUrlBefore))."
& $ViewerBootstrapScriptPath

$currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
$deployViewer = Test-EnabledValue -Value ([string]$currentValues['DEPLOY_VIEWER'])
$credentialMode = [string]$currentValues['W365_BLUEPRINT_CREDENTIAL_MODE']
$w365VaultName = [string]$currentValues['W365_KEY_VAULT_NAME']
if ([string]::IsNullOrWhiteSpace($w365VaultName)) {
    $w365VaultName = [string]$currentValues['VIEWER_KEY_VAULT_NAME']
}
$requiresBlueprintSecret = $credentialMode -eq 'client_secret' -and (
    $enableW365 -or (Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED'])))
if ($requiresBlueprintSecret) {
    if ([string]::IsNullOrWhiteSpace($w365VaultName)) {
        throw 'State provisioning did not produce W365_KEY_VAULT_NAME before blueprint secret configuration.'
    }
    Write-SampleVerbose -Component 'postup' -Message 'Ensuring the blueprint client secret exists in the shared W365 Key Vault.'
    Write-SampleDebug -Component 'postup' -Message "Credential mode=$credentialMode; vault=$w365VaultName."
    & $ViewerSecretsScriptPath -Environment $environmentName -BlueprintOnly
    if (!$?) {
        throw 'Blueprint secret storage failed.'
    }
}

$hostedAgentPossible = $enableW365 -or
    (Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED']))
if ($hostedAgentPossible -and ![string]::IsNullOrWhiteSpace($environmentName)) {
    Write-SampleVerbose -Component 'postup' -Message 'Resolving hosted-agent operator defaults (OPERATOR_TENANT_ID, OPERATOR_OBJECT_ID, HOSTED_ALLOWED_USER_ID) before any hosted-agent deployment.'
    $environmentFilePath = Join-Path (Join-Path $RepositoryRoot ".azure\$environmentName") '.env'
    $currentValues = Resolve-W365HostedAgentOperatorDefaults -EnvironmentFilePath $environmentFilePath -EnvironmentValues $currentValues
}

$w365SetupRan = $false
if ($enableW365) {
    $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
    $w365AlreadyEnabled = Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED'])
    if ($w365AlreadyEnabled) {
        $state = Get-W365ProvisioningState `
            -RepositoryRoot $RepositoryRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $currentValues
        if ($state.Name -ne 'Complete') {
            throw "W365_ENABLED=true but environment '$environmentName' is not complete."
        }

        Write-Host "W365 environment '$environmentName' is already complete; setup redeployment skipped."
    }
    else {
        $previousPostUpGuard = $env:W365_POSTUP_IN_PROGRESS
        $env:W365_POSTUP_IN_PROGRESS = 'true'
        try {
            $setupArguments = @{
                Environment = $environmentName
                BillingConfirmed = $true
                ConfirmResourceChanges = $true
                UseDeviceCode = $true
            }
            $configuredTenantId = [guid]::Empty
            if (![guid]::TryParse([string]$currentValues['AZURE_TENANT_ID'], [ref]$configuredTenantId) -or
                $configuredTenantId -eq [guid]::Empty) {
                throw "Azd environment '$environmentName' does not contain a valid AZURE_TENANT_ID."
            }
            $setupArguments.TenantId = $configuredTenantId
            $configuredPrincipalName = [string]$currentValues['W365_AGENT_USER_PRINCIPAL_NAME']
            if (![string]::IsNullOrWhiteSpace($configuredPrincipalName)) {
                $setupArguments.AgentUserPrincipalName = $configuredPrincipalName
            }
            $configuredDomain = [string]$currentValues['W365_AGENT_USER_DOMAIN']
            if (![string]::IsNullOrWhiteSpace($configuredDomain)) {
                $setupArguments.AgentUserDomain = $configuredDomain
            }
            $poolId = [guid]::Empty
            if ([guid]::TryParse([string]$currentValues['W365_POOL_ID'], [ref]$poolId) -and
                $poolId -ne [guid]::Empty) {
                $setupArguments.PoolId = $poolId
            }
            $billingPlanId = [guid]::Empty
            if ([guid]::TryParse([string]$currentValues['W365_POOL_BILLING_PLAN_ID'], [ref]$billingPlanId) -and
                $billingPlanId -ne [guid]::Empty) {
                $setupArguments.PoolBillingPlanId = $billingPlanId
            }
            foreach ($mapping in @(
                @{ Environment = 'W365_POOL_BILLING_TYPE'; Parameter = 'PoolBillingType' },
                @{ Environment = 'W365_POOL_GEOGRAPHIC_LOCATION_TYPE'; Parameter = 'PoolGeographicLocationType' },
                @{ Environment = 'W365_POOL_REGION_GROUP'; Parameter = 'PoolRegionGroup' },
                @{ Environment = 'W365_POOL_IMAGE_ID'; Parameter = 'PoolImageId' },
                @{ Environment = 'W365_POOL_IMAGE_TYPE'; Parameter = 'PoolImageType' },
                @{ Environment = 'W365_POOL_OS_LOCALE'; Parameter = 'PoolOsLocale' }
            )) {
                $value = [string]$currentValues[$mapping.Environment]
                if (![string]::IsNullOrWhiteSpace($value)) {
                    $setupArguments[$mapping.Parameter] = $value
                }
            }
            $regions = @(([string]$currentValues['W365_POOL_REGIONS']).Split(
                ',',
                [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries))
            if ($regions.Count -gt 0) {
                $setupArguments.PoolRegions = $regions
            }
            foreach ($mapping in @(
                @{ Environment = 'W365_POOL_MINIMUM_COUNT'; Parameter = 'PoolMinimumCount' },
                @{ Environment = 'W365_POOL_MAXIMUM_COUNT'; Parameter = 'PoolMaximumCount' }
            )) {
                $value = 0
                if ([int]::TryParse([string]$currentValues[$mapping.Environment], [ref]$value)) {
                    $setupArguments[$mapping.Parameter] = $value
                }
            }
            if ([string]$currentValues['W365_POOL_ENABLE_SINGLE_SIGN_ON'] -eq 'true') {
                $setupArguments.PoolEnableSingleSignOn = $true
            }
            & $W365SetupScriptPath @setupArguments
            $w365SetupRan = $true
        }
        catch {
            $manifestPath = Get-W365OwnershipManifestPath `
                -RepositoryRoot $RepositoryRoot `
                -EnvironmentName $environmentName
            Write-Warning "The bootstrap agent remains W365-disabled. If resources were created, ownership evidence is retained at '$manifestPath'."
            throw
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'W365_POSTUP_IN_PROGRESS',
                $previousPostUpGuard,
                'Process')
        }

        $currentValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
        $state = Get-W365ProvisioningState `
            -RepositoryRoot $RepositoryRoot `
            -EnvironmentName $environmentName `
            -EnvironmentValues $currentValues
        if ($state.Name -ne 'Complete') {
            throw "W365 setup returned successfully, but environment '$environmentName' did not reach Complete state."
        }

        Write-Host "W365 setup and final hosted-agent deployment completed for '$environmentName'."
    }
}
else {
    Write-Host 'W365 setup skipped because ENABLE_W365 is not true.'
}

if (![string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
    $environmentName = $env:AZURE_ENV_NAME
    $updatedValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
    $viewerUrlAfter = [string]$updatedValues['VIEWER_PUBLIC_URL']
    $w365EnabledAfter = Test-EnabledValue -Value ([string]$updatedValues['W365_ENABLED'])
    $viewerLiveEnabled = Test-EnabledValue -Value ([string]$updatedValues['VIEWER_LIVE_ENABLED'])
    $deployViewer = Test-EnabledValue -Value ([string]$updatedValues['DEPLOY_VIEWER'])
    $viewerLiveActivated = $false

    if ($deployViewer -and $w365EnabledAfter -and !$viewerLiveEnabled) {
        $liveRequired = @(
            'VIEWER_PUBLIC_URL',
            'W365_KEY_VAULT_NAME',
            'SCREENSHARE_SDK_URL',
            'SCREENSHARE_FRAME_ORIGINS',
            'SCREENSHARE_APP_URL'
        )
        $missing = @($liveRequired | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$updatedValues[$_])
        })
        if ($missing.Count -gt 0) {
            Write-Warning "Viewer remains in bootstrap mode. Set these values and rerun azd up: $($missing -join ', ')."
        }
        else {
            Write-SampleVerbose -Component 'postup' -Message 'All live viewer prerequisites are present; requesting activation approval.'
            Write-SampleDebug -Component 'postup' -Message "Environment=$environmentName; viewerUrl=$viewerUrlAfter."
            Confirm-ViewerLiveActivation
            & $ViewerActivationScriptPath -Environment $environmentName
            if (!$?) {
                throw 'Live viewer activation failed.'
            }
            $updatedValues = Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
            $viewerUrlAfter = [string]$updatedValues['VIEWER_PUBLIC_URL']
            $viewerLiveActivated = Test-EnabledValue -Value ([string]$updatedValues['VIEWER_LIVE_ENABLED'])
        }
    }

    $viewerConfigurationChanged = $viewerLiveActivated -or (
        !$w365SetupRan -and $viewerUrlAfter -ne $viewerUrlBefore)
    if ($w365EnabledAfter -and
        ![string]::IsNullOrWhiteSpace($viewerUrlAfter) -and
        $viewerConfigurationChanged) {
        $agentRequired = @('OPERATOR_TENANT_ID', 'OPERATOR_OBJECT_ID', 'HOSTED_ALLOWED_USER_ID')
        $agentMissing = @($agentRequired | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$updatedValues[$_])
        })
        if ($agentMissing.Count -gt 0) {
            Write-Warning "Skipping hosted-agent redeploy: the running container would crash on startup without $($agentMissing -join ', '). Set these values (see 'Bind the hosted operator' in docs/DEPLOYMENT.md) and rerun azd up."
        }
        else {
            $redeployReason = if ($viewerLiveActivated -and $w365SetupRan) {
                "Viewer '$viewerUrlAfter' was activated after W365 setup"
            }
            elseif ($viewerLiveActivated) {
                "Viewer URL '$viewerUrlAfter' was activated"
            }
            else {
                "Viewer URL '$viewerUrlAfter' was added"
            }
            Write-Host "$redeployReason; redeploying the hosted agent so live-view links are available."
            $previousPostUpGuard = $env:W365_POSTUP_IN_PROGRESS
            $env:W365_POSTUP_IN_PROGRESS = 'true'
            try {
                & $AgentDeploymentScriptPath `
                    -Mode DeployAgent `
                    -Environment $environmentName `
                    -ConfirmResourceChanges `
                    -SmokeInvoke
            }
            finally {
                [Environment]::SetEnvironmentVariable(
                    'W365_POSTUP_IN_PROGRESS',
                    $previousPostUpGuard,
                    'Process')
            }
        }
    }

    & $DeploymentSummaryScriptPath -RepositoryRoot $RepositoryRoot -Environment $environmentName
    if (!$?) {
        throw 'Deployment summary failed.'
    }
}
