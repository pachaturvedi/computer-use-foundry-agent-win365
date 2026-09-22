#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Environment,
    [switch]$DeployViewer,
    [string]$IdentityScriptPath = (Join-Path $PSScriptRoot 'Get-FoundryIdentity.ps1'),
    [string]$ProvisioningProfileScriptPath = (Join-Path $PSScriptRoot 'Resolve-AzdUpProvisioningProfile.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$IsWindows) {
    throw 'The azd phase-two initializer is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

$azd = Get-W365AzdCommand
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}

Invoke-W365Azd -Azd $azd -Arguments @('env', 'select', $Environment) | Out-Null
$ownership = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_OWNERSHIP' -AllowMissing
if ([string]::IsNullOrWhiteSpace($ownership)) {
    $ownership = 'managed'
}
if ($ownership -ne 'managed') {
    throw "Automatic phase-two setup is limited to a dedicated managed Foundry project; environment '$Environment' uses ownership '$ownership'."
}

$projectEndpoint = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_PROJECT_ENDPOINT'
$agentName = Get-W365AzdValue -Azd $azd -Name 'FOUNDRY_AGENT_NAME' -AllowMissing
if ([string]::IsNullOrWhiteSpace($agentName)) {
    $agentName = 'win365-desktop-agent'
}
$agentVersion = Get-W365AzdValue -Azd $azd -Name 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
$credentialMode = Get-W365AzdValue -Azd $azd -Name 'W365_BLUEPRINT_CREDENTIAL_MODE' -AllowMissing
if ([string]::IsNullOrWhiteSpace($credentialMode)) {
    $credentialMode = 'client_secret'
}
if ($credentialMode -notin @('client_secret', 'managed_identity_federation', 'key_vault_certificate')) {
    throw "Unsupported W365_BLUEPRINT_CREDENTIAL_MODE '$credentialMode'."
}
$tenantIdValue = Get-W365AzdValue -Azd $azd -Name 'AZURE_TENANT_ID'
$tenantId = [guid]::Empty
if (![guid]::TryParse($tenantIdValue, [ref]$tenantId) -or $tenantId -eq [guid]::Empty) {
    throw "Azd environment '$Environment' does not contain a valid AZURE_TENANT_ID."
}

Write-W365ProvisioningStep "Discovering the phase-one Foundry principal for agent '$agentName' version '$agentVersion'."
$identityResult = @(& $IdentityScriptPath `
    -ProjectEndpoint $projectEndpoint `
    -AgentName $agentName `
    -AgentVersion $agentVersion `
    -TenantId $tenantId)
if ($LASTEXITCODE -ne 0) {
    throw 'Foundry identity discovery failed before phase-two provisioning.'
}
$identity = $identityResult | Select-Object -Last 1
$agentPrincipalId = [guid]::Empty
if ($null -eq $identity -or
    ![guid]::TryParse([string]$identity.AgentIdentityId, [ref]$agentPrincipalId) -or
    $agentPrincipalId -eq [guid]::Empty) {
    throw 'Foundry identity discovery did not return a valid agent object/principal ID.'
}

$phaseTwoValues = [ordered]@{
    ENABLE_W365 = 'true'
    DEPLOY_STATE = 'true'
    STATE_AGENT_PRINCIPAL_ID = $agentPrincipalId.ToString()
    DEPLOY_VIEWER = 'false'
    VIEWER_LIVE_ENABLED = 'false'
    W365_BLUEPRINT_CREDENTIAL_MODE = $credentialMode
}
Set-W365AzdValues -Azd $azd -Values $phaseTwoValues

$previousUserAgent = $env:AZURE_DEV_USER_AGENT
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
try {
    Write-W365ProvisioningStep "Provisioning shared Blob state for agent principal '$agentPrincipalId'."
    Invoke-W365Azd -Azd $azd -Arguments @(
        'provision', 'state', '--environment', $Environment, '--no-prompt'
    ) | Out-Null

    $stateValues = [ordered]@{
        DEPLOY_STATE = Get-W365AzdValue -Azd $azd -Name 'DEPLOY_STATE'
        STATE_STORAGE_ACCOUNT_NAME = Get-W365AzdValue -Azd $azd -Name 'STATE_STORAGE_ACCOUNT_NAME'
        STATE_CONTAINER_NAME = Get-W365AzdValue -Azd $azd -Name 'STATE_CONTAINER_NAME'
        SESSION_BLOB_URI = Get-W365AzdValue -Azd $azd -Name 'SESSION_BLOB_URI'
    }
    $missingStateValues = @($stateValues.GetEnumerator() | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.Value)
    } | ForEach-Object Key)
    if ($stateValues.DEPLOY_STATE -ne 'true' -or $missingStateValues.Count -gt 0) {
        $missingSummary = if ($missingStateValues.Count -gt 0) {
            " Missing outputs: $($missingStateValues -join ', ')."
        }
        else {
            ''
        }
        throw "Shared state provisioning completed without usable Blob state.$missingSummary Viewer provisioning was not started."
    }

    $sessionBlobUri = $null
    if (![uri]::TryCreate(
            [string]$stateValues.SESSION_BLOB_URI,
            [UriKind]::Absolute,
            [ref]$sessionBlobUri) -or
        $sessionBlobUri.Scheme -ne [Uri]::UriSchemeHttps -or
        !$sessionBlobUri.IsDefaultPort -or
        $sessionBlobUri.Host -ne "$($stateValues.STATE_STORAGE_ACCOUNT_NAME).blob.core.windows.net" -or
        $sessionBlobUri.AbsolutePath -cne "/$($stateValues.STATE_CONTAINER_NAME)/slot.json" -or
        ![string]::IsNullOrEmpty($sessionBlobUri.UserInfo) -or
        ![string]::IsNullOrEmpty($sessionBlobUri.Query) -or
        ![string]::IsNullOrEmpty($sessionBlobUri.Fragment)) {
        throw 'Shared state provisioning returned inconsistent STATE_STORAGE_ACCOUNT_NAME, STATE_CONTAINER_NAME, and SESSION_BLOB_URI values. Viewer provisioning was not started.'
    }

    if ($DeployViewer) {
        Set-W365AzdValues -Azd $azd -Values ([ordered]@{
            DEPLOY_VIEWER = 'true'
        })
        $previousViewerProvisioningActive = $env:VIEWER_PROVISIONING_ACTIVE
        $env:VIEWER_PROVISIONING_ACTIVE = 'true'
        try {
            Write-W365ProvisioningStep 'Provisioning the ACA viewer bootstrap after shared state is ready.'
            try {
                Invoke-W365Azd -Azd $azd -Arguments @(
                    'provision', 'viewer', '--environment', $Environment, '--no-prompt'
                ) | Out-Null
            }
            catch {
                $quotaFailure = $_.Exception.Message -match
                    'MaxNumberOfGlobalEnvironmentsInSubExceeded|managed environment.{0,80}(quota|capacity)|quota.{0,80}managed environment'
                if (!$quotaFailure -or $env:AZD_NON_INTERACTIVE -eq 'true') {
                    throw
                }

                Write-Warning 'A new ACA managed environment could not be created because of a subscription quota or capacity limit.'
                & $ProvisioningProfileScriptPath `
                    -Environment $Environment `
                    -ViewerOnly `
                    -ViewerMode existing
                if (!$?) {
                    throw 'Existing ACA managed-environment selection failed after the creation quota error.'
                }
                Invoke-W365Azd -Azd $azd -Arguments @(
                    'provision', 'viewer', '--environment', $Environment, '--no-prompt'
                ) | Out-Null
            }
        }
        finally {
            $env:VIEWER_PROVISIONING_ACTIVE = $previousViewerProvisioningActive
        }
    }
}
finally {
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
}

Write-Host "Phase-two Azure prerequisites are ready for '$Environment'."
