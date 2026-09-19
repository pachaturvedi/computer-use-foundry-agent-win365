#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
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
        '1. Build (only if changed) and push the viewer image, then wait for the ACA viewer health check.'
    } else {
        '1. Skip viewer image build and health check because DEPLOY_VIEWER is not true.'
    }))
    $steps.Add($(if ($EnableW365 -and !$W365Enabled) {
        '2. Run interactive Windows 365 setup: Entra agent user, Cloud PC pool, and consent.'
    } elseif ($W365Enabled) {
        '2. Verify the existing Windows 365 environment is already complete.'
    } else {
        '2. Skip Windows 365 setup because ENABLE_W365 is not true.'
    }))
    $steps.Add($(if ($ViewerEnabled -and $W365Enabled -and !$ViewerLiveEnabled) {
        '3. Activate the authenticated live viewer if OIDC/screen-share prerequisites are already set; otherwise warn what is missing.'
    } else {
        '3. Skip live-viewer activation.'
    }))
    $steps.Add('4. Redeploy the hosted agent only if a new viewer URL became available during this run.')
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

Show-PostUpPlan `
    -ViewerEnabled (Test-EnabledValue -Value $env:DEPLOY_VIEWER) `
    -W365Enabled (Test-EnabledValue -Value $env:W365_ENABLED) `
    -EnableW365 (Test-EnabledValue -Value $env:ENABLE_W365) `
    -ViewerLiveEnabled (Test-EnabledValue -Value $env:VIEWER_LIVE_ENABLED)

$viewerUrlBefore = [string]$env:VIEWER_PUBLIC_URL
Write-SampleVerbose -Component 'postup' -Message 'Running viewer bootstrap before enabled W365 deployment.'
Write-SampleDebug -Component 'postup' -Message "Viewer URL existed before bootstrap: $(![string]::IsNullOrWhiteSpace($viewerUrlBefore))."
& $ViewerBootstrapScriptPath

$environmentName = [string]$env:AZURE_ENV_NAME
$currentValues = if (![string]::IsNullOrWhiteSpace($environmentName)) {
    Import-AzdEnvironmentValues -Root $RepositoryRoot -EnvironmentName $environmentName
}
else {
    @{}
}
$deployViewer = Test-EnabledValue -Value ([string]$currentValues['DEPLOY_VIEWER'])
$credentialMode = [string]$currentValues['W365_BLUEPRINT_CREDENTIAL_MODE']
$w365VaultName = [string]$currentValues['W365_KEY_VAULT_NAME']
if ([string]::IsNullOrWhiteSpace($w365VaultName)) {
    $w365VaultName = [string]$currentValues['VIEWER_KEY_VAULT_NAME']
}
$requiresBlueprintSecret = $credentialMode -eq 'client_secret' -and (
    (Test-EnabledValue -Value $env:ENABLE_W365) -or
    (Test-EnabledValue -Value ([string]$currentValues['W365_ENABLED']))
)
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

$enableW365 = Test-EnabledValue -Value $env:ENABLE_W365
$w365SetupRan = $false
if ($enableW365) {
    if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
        throw 'ENABLE_W365=true requires AZURE_ENV_NAME.'
    }
    $environmentName = $env:AZURE_ENV_NAME
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
        Confirm-W365PostUpChanges
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
        }
    }

    if ($w365EnabledAfter -and
        !$w365SetupRan -and
        ![string]::IsNullOrWhiteSpace($viewerUrlAfter) -and
        $viewerUrlAfter -ne $viewerUrlBefore) {
        Write-Host "Viewer URL '$viewerUrlAfter' was added; redeploying the hosted agent so live-view links are available."
        $previousPostUpGuard = $env:W365_POSTUP_IN_PROGRESS
        $env:W365_POSTUP_IN_PROGRESS = 'true'
        try {
            & $AgentDeploymentScriptPath `
                -Mode DeployAgent `
                -Environment $environmentName `
                -ConfirmResourceChanges
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'W365_POSTUP_IN_PROGRESS',
                $previousPostUpGuard,
                'Process')
        }
    }

    & $DeploymentSummaryScriptPath -RepositoryRoot $RepositoryRoot -Environment $environmentName
    if (!$?) {
        throw 'Deployment summary failed.'
    }
}
