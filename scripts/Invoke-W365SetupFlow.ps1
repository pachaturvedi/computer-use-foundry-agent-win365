#Requires -Version 7.4
<#
.SYNOPSIS
Binds the deployed Foundry identities to Windows 365 and redeploys the agent.

.DESCRIPTION
Discovers the exact hosted-agent version, verifies Blob state and the selected credential mode, reconciles Entra/W365 setup through Setup-W365.ps1, persists ownership and identifiers, and deploys the enabled agent.


Key inputs: Environment and TenantId plus optional agent-user, pool, credential-federation, Graph, billing, confirmation, and packaging settings.

.OUTPUTS
W365 identifiers, ownership manifest, updated azd environment values, and a new immutable hosted-agent version.

.NOTES
Tenant-mutating workflow. It requires explicit billing and resource-change confirmation and never creates replacement Foundry identities.
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [guid]$TenantId = [guid]::Empty,
    [ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')][string]$AgentUserPrincipalName,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$AgentUserDomain,
    [string]$AgentName,
    [string]$AgentVersion,
    [guid]$PoolId = [guid]::Empty,
    [string]$PoolIdOrUrl,
    [string]$PoolDisplayName,
    [string]$PoolDescription,
    [guid]$PoolBillingPlanId = [guid]::Empty,
    [ValidateSet('payAsYouGo')][string]$PoolBillingType = 'payAsYouGo',
    [string]$PoolGeographicLocationType,
    [string]$PoolRegionGroup,
    [string[]]$PoolRegions,
    [string]$PoolImageId,
    [ValidateSet('gallery', 'custom')][string]$PoolImageType = 'gallery',
    [string]$PoolOsLocale = 'en-US',
    [ValidateRange(1, 200)][int]$PoolMinimumCount = 1,
    [ValidateRange(1, 200)][int]$PoolMaximumCount = 1,
    [switch]$PoolEnableSingleSignOn,
    [guid]$HostedRuntimeIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeHostedRuntimeFederation,
    [guid]$ViewerManagedIdentityObjectId = [guid]::Empty,
    [switch]$AuthorizeViewerFederation,
    [switch]$BillingConfirmed,
    [switch]$UseDeviceCode,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$ConfirmResourceChanges,
    [switch]$SkipPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$IsWindows) {
    throw 'This W365 setup flow is Windows-only. Use PowerShell 7.4 or later on Windows.'
}
Assert-W365ResourceApproval -EnableW365:$true -ConfirmResourceChanges:$ConfirmResourceChanges

$root = Split-Path $PSScriptRoot
$azd = Get-W365AzdCommand
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}

Push-Location $root
try {
    if ($Environment) {
        Write-W365ProvisioningStep "Selecting azd environment '$Environment'."
        Invoke-W365Azd -Azd $azd -Arguments @('env', 'select', $Environment) | Out-Null
    }

    & (Join-Path (Split-Path $PSScriptRoot) 'tests\PowerShell\Test-AzdPrerequisites.ps1') -RequireLogin
    if ($LASTEXITCODE -ne 0) {
        throw 'azd prerequisite validation failed.'
    }

    $environmentName = Get-W365AzdValue -Azd $azd -Name 'AZURE_ENV_NAME'
    $projectEndpoint = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_ENDPOINT'
    if ([string]::IsNullOrWhiteSpace($projectEndpoint)) {
        throw 'FOUNDRY_PROJECT_ENDPOINT is empty. Deploy the Foundry bootstrap before running W365 setup.'
    }

    $resolvedAgentName = if (![string]::IsNullOrWhiteSpace($AgentName)) {
        $AgentName
    }
    else {
        $configuredAgentName = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_AGENT_NAME' -AllowMissing
        if ([string]::IsNullOrWhiteSpace($configuredAgentName)) {
            'win365-desktop-agent'
        }
        else {
            $configuredAgentName
        }
    }

    $resolvedAgentVersion = if (![string]::IsNullOrWhiteSpace($AgentVersion)) {
        $AgentVersion
    }
    else {
        Get-W365AzdValue -Azd $azd -Name 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedAgentVersion)) {
        throw 'AGENT_WIN365_DESKTOP_AGENT_VERSION is empty. Deploy the hosted agent before running W365 setup.'
    }

    $resolvedTenantId = Resolve-W365TenantId -Azd $azd -ExplicitTenantId $TenantId
    Write-W365ProvisioningStep "Discovering Foundry identity for agent '$resolvedAgentName' version '$resolvedAgentVersion'."
    $identityResult = @(& (Join-Path $PSScriptRoot 'Get-FoundryIdentity.ps1') `
        -ProjectEndpoint $projectEndpoint `
        -AgentName $resolvedAgentName `
        -AgentVersion $resolvedAgentVersion `
        -TenantId $resolvedTenantId)
    if ($LASTEXITCODE -ne 0) {
        throw 'Foundry identity discovery failed.'
    }
    $identity = $identityResult | Select-Object -Last 1
    if ($null -eq $identity) {
        throw 'Foundry identity discovery returned no result.'
    }
    $discoveredTenantId = [guid]::Empty
    $discoveredBlueprintId = [guid]::Empty
    $discoveredAgentIdentityId = [guid]::Empty
    if (![guid]::TryParse([string]$identity.TenantId, [ref]$discoveredTenantId) -or $discoveredTenantId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid tenant ID.'
    }
    if (![guid]::TryParse([string]$identity.BlueprintId, [ref]$discoveredBlueprintId) -or $discoveredBlueprintId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid blueprint ID.'
    }
    if (![guid]::TryParse([string]$identity.AgentIdentityId, [ref]$discoveredAgentIdentityId) -or $discoveredAgentIdentityId -eq [guid]::Empty) {
        throw 'Foundry identity discovery did not return a valid agent identity ID.'
    }

    $activationValues = [ordered]@{}
    foreach ($name in @(
        'DEPLOY_STATE',
        'SESSION_BLOB_URI',
        'STATE_AGENT_PRINCIPAL_ID',
        'OPERATOR_TENANT_ID',
        'OPERATOR_OBJECT_ID',
        'HOSTED_ALLOWED_USER_ID',
        'W365_BLUEPRINT_CREDENTIAL_MODE',
        'W365_KEY_VAULT_NAME'
    )) {
        $activationValues[$name] = Get-W365AzdValue -Azd $azd -Name $name -AllowMissing
    }
    $activation = Assert-W365ActivationPrerequisites `
        -EnvironmentValues $activationValues `
        -ExpectedAgentIdentityId $discoveredAgentIdentityId `
        -HostedRuntimeIdentityObjectId $HostedRuntimeIdentityObjectId `
        -AuthorizeHostedRuntimeFederation:$AuthorizeHostedRuntimeFederation
    $subscriptionId = [guid](Get-W365AzdValue -Azd $azd -Name 'AZURE_SUBSCRIPTION_ID')
    Assert-W365StateResourceReady `
        -SubscriptionId $subscriptionId `
        -SessionBlobUri ([uri][string]$activationValues['SESSION_BLOB_URI']) `
        -ExpectedAgentIdentityId $discoveredAgentIdentityId | Out-Null
    if ($activation.CredentialMode -eq 'client_secret') {
        Assert-W365BlueprintSecretReady `
            -SubscriptionId $subscriptionId `
            -KeyVaultName $activation.KeyVaultName
    }
    if ($activation.CredentialMode -eq 'key_vault_certificate') {
        Assert-W365BlueprintCertificateReady `
            -SubscriptionId $subscriptionId `
            -KeyVaultName $activation.KeyVaultName `
            -TenantId $discoveredTenantId `
            -BlueprintId $discoveredBlueprintId
    }

    Write-W365ProvisioningStep "Running W365 setup for azd environment '$environmentName'."
    $setupArguments = @{
        TenantId = $discoveredTenantId
        BlueprintId = $discoveredBlueprintId
        AgentIdentityId = $discoveredAgentIdentityId
        BillingConfirmed = $BillingConfirmed
        GraphClientTimeoutSeconds = $GraphClientTimeoutSeconds
        Confirm = $false
    }
    foreach ($name in @('AgentUserPrincipalName', 'AgentUserDomain')) {
        if ($PSBoundParameters.ContainsKey($name) -and
            ![string]::IsNullOrWhiteSpace([string]$PSBoundParameters[$name])) {
            $setupArguments[$name] = $PSBoundParameters[$name]
        }
    }
    foreach ($name in @(
        'PoolId', 'PoolIdOrUrl', 'PoolDisplayName', 'PoolDescription', 'PoolBillingPlanId', 'PoolBillingType',
        'PoolGeographicLocationType', 'PoolRegionGroup', 'PoolRegions', 'PoolImageId', 'PoolImageType',
        'PoolOsLocale', 'PoolMinimumCount', 'PoolMaximumCount', 'HostedRuntimeIdentityObjectId',
        'ViewerManagedIdentityObjectId')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $setupArguments[$name] = $PSBoundParameters[$name]
        }
    }
    foreach ($switchName in @('PoolEnableSingleSignOn', 'AuthorizeHostedRuntimeFederation', 'AuthorizeViewerFederation', 'UseDeviceCode')) {
        if ($PSBoundParameters.ContainsKey($switchName) -and $PSBoundParameters[$switchName]) {
            $setupArguments[$switchName] = $true
        }
    }
    & (Join-Path $PSScriptRoot 'Setup-W365.ps1') @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'W365 setup failed.'
    }

    Write-W365ProvisioningStep 'Redeploying the hosted agent with the persisted W365 configuration.'
    $deployArguments = @{
        Mode = 'DeployAgent'
        Environment = $environmentName
        ConfirmResourceChanges = $true
        # Persist a fresh session against the phase-two version. Without this, azd can reuse the
        # bootstrap version's saved session after azd up, which would still return w365_not_configured.
        SmokeInvoke = $true
    }
    if ($SkipPackage) {
        $deployArguments.SkipPackage = $true
    }
    & (Join-Path $PSScriptRoot 'Invoke-AzdDeployment.ps1') @deployArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Hosted agent redeployment failed.'
    }
}
finally {
    Pop-Location
}