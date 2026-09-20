#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'ProvisionFoundry', 'DeployAgent', 'DeployAll')]
    [string]$Mode = 'Validate',
    [string]$Environment,
    [string]$ConfigPath,
    [switch]$ConfirmResourceChanges,
    [switch]$SkipPackage,
    [switch]$SmokeInvoke,
    [string]$SmokeInvokePrompt = 'Smoke test only: reply with the single word OK. Do not open any application, acquire any desktop, or call any tool.'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$IsWindows) {
    throw 'This deployment workflow is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

$root = Split-Path $PSScriptRoot
$logDirectory = Join-Path $root '.azure\logs'
$logPath = Join-Path $logDirectory (
    '{0:yyyyMMdd-HHmmss}-{1}.log' -f [DateTimeOffset]::Now, $Mode.ToLowerInvariant())
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$azdPaths = [System.Collections.Generic.List[string]]::new()
foreach ($command in @(Get-Command azd -All -ErrorAction SilentlyContinue)) {
    if ($null -ne $command -and !$azdPaths.Contains($command.Source)) {
        $azdPaths.Add($command.Source)
    }
}
foreach ($path in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Azure Dev CLI\azd.exe'),
    (Join-Path $env:ProgramFiles 'Azure Dev CLI\azd.exe')
)) {
    if (![string]::IsNullOrWhiteSpace($path) -and (Test-Path $path) -and !$azdPaths.Contains($path)) {
        $azdPaths.Add($path)
    }
}

$azdCandidates = $azdPaths |
    ForEach-Object {
        $versionOutput = & $_ version 2>$null
        if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'azd version\s+(\d+\.\d+\.\d+)') {
            [pscustomobject]@{ Path = $_; Version = [version]$Matches[1] }
        }
    } |
    Sort-Object Version -Descending
$azd = $azdCandidates | Where-Object Version -ge ([version]'1.32.0') | Select-Object -First 1
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}

function Write-DeploymentEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('STEP', 'DECISION', 'COMMAND', 'RESULT')]
        [string]$Kind,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host ('[{0:HH:mm:ss}] [{1}] {2}' -f [DateTimeOffset]::Now, $Kind, $Message)
}

function Invoke-Azd {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    Write-DeploymentEvent COMMAND "azd $($Arguments -join ' ')"
    $output = & $azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }
    $output | Write-Host
}

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    return (Invoke-Azd -Arguments @('env', 'get-value', $Name) -CaptureOutput)
}

function Get-AzdOptionalValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = & $azd.Path env get-value $Name 2>$null
    if ($LASTEXITCODE -eq 0) {
        return ($value | Out-String).Trim()
    }

    return ''
}

function Get-W365KeyVaultName {
    $vaultName = Get-AzdOptionalValue 'W365_KEY_VAULT_NAME'
    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        $vaultName = Get-AzdOptionalValue 'VIEWER_KEY_VAULT_NAME'
    }
    return $vaultName
}

function Assert-LiveViewerConfiguration {
    $liveEnabled = Get-AzdOptionalValue 'VIEWER_LIVE_ENABLED'
    if ($liveEnabled -ne 'true') {
        Write-DeploymentEvent DECISION 'Viewer remains in bootstrap mode because VIEWER_LIVE_ENABLED is not true.'
        return
    }

    $required = @(
        'VIEWER_PUBLIC_URL',
        'VIEWER_CLIENT_ID',
        'OPERATOR_TENANT_ID',
        'OPERATOR_OBJECT_ID',
        'W365_TENANT_ID',
        'W365_BLUEPRINT_ID',
        'W365_AGENT_ID',
        'W365_AGENT_OBJECT_ID',
        'W365_AGENT_USER_ID',
        'SCREENSHARE_SDK_URL',
        'SCREENSHARE_FRAME_ORIGINS',
        'SCREENSHARE_APP_URL',
        'W365_KEY_VAULT_NAME',
        'W365_BLUEPRINT_CREDENTIAL_MODE'
    )
    $missing = @($required | Where-Object {
        [string]::IsNullOrWhiteSpace((Get-AzdOptionalValue $_))
    })
    if ($missing.Count -gt 0) {
        throw "VIEWER_LIVE_ENABLED=true requires: $($missing -join ', ')."
    }
    if ($w365Enabled -ne 'true') {
        throw 'VIEWER_LIVE_ENABLED=true requires W365_ENABLED=true.'
    }
    $credentialMode = Get-AzdValue 'W365_BLUEPRINT_CREDENTIAL_MODE'
    Assert-ViewerCredentialMode -CredentialMode $credentialMode
    Assert-ViewerIdentityModeConfiguration `
        -CredentialMode $credentialMode `
        -ViewerPrincipalId (Get-AzdValue 'VIEWER_IDENTITY_PRINCIPAL_ID') `
        -OwnershipManifestPath (Join-Path $root ".azure\$environmentName\w365-ownership.json")

    $vaultName = Get-W365KeyVaultName
    $requiredSecrets = @('w365-viewer-client-secret')
    if ($credentialMode -eq 'client_secret') {
        $requiredSecrets += 'w365-blueprint-client-secret'
    }
    foreach ($secretName in $requiredSecrets) {
        & az keyvault secret show `
            --subscription (Get-AzdValue 'AZURE_SUBSCRIPTION_ID') `
            --vault-name $vaultName `
            --name $secretName `
            --query id `
            --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Key Vault '$vaultName' must contain secret '$secretName' before live viewer activation."
        }
    }
    Write-DeploymentEvent DECISION 'Live viewer prerequisites and Key Vault OIDC secret are present.'
}

function Assert-W365AgentKeyVaultAccessConfigured {
    # The hosted agent now fetches the blueprint client secret directly from Key Vault using its
    # own runtime identity (KeyVaultBlueprintSecretResolver) instead of receiving it as an
    # environment variable. This only confirms the vault name and secret exist before deployment;
    # the RBAC role assignment itself is provisioned by infra/state/keyvault.bicep.
    if ((Get-AzdOptionalValue 'W365_ENABLED') -ne 'true' -or
        (Get-AzdOptionalValue 'W365_BLUEPRINT_CREDENTIAL_MODE') -ne 'client_secret') {
        return
    }

    $vaultName = Get-W365KeyVaultName
    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        throw 'Client-secret mode requires W365_KEY_VAULT_NAME (or VIEWER_KEY_VAULT_NAME) to resolve the Key Vault holding w365-blueprint-client-secret.'
    }
    & az keyvault secret show `
        --subscription (Get-AzdValue 'AZURE_SUBSCRIPTION_ID') `
        --vault-name $vaultName `
        --name 'w365-blueprint-client-secret' `
        --query id `
        --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Key Vault '$vaultName' must contain secret 'w365-blueprint-client-secret' before deploying the hosted agent in client_secret mode."
    }
    Write-DeploymentEvent DECISION "Confirmed 'w365-blueprint-client-secret' exists in '$vaultName'; the hosted agent fetches it directly at startup using its own identity."
}

function Invoke-HostedAgentSmokeTest {
    if (!$SmokeInvoke) {
        return
    }

    $agentVersion = Get-AzdOptionalValue 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
    if ([string]::IsNullOrWhiteSpace($agentVersion)) {
        throw 'Hosted-agent smoke invoke requires AGENT_WIN365_DESKTOP_AGENT_VERSION after deployment.'
    }

    Write-DeploymentEvent STEP 'Smoke-testing the hosted agent with a minimal invocation to confirm the deployed container passes readiness.'
    $smokeArguments = @(
        'ai', 'agent', 'invoke', 'win365-desktop-agent',
        '--version', $agentVersion,
        '--new-session', $SmokeInvokePrompt
    )
    Write-DeploymentEvent COMMAND "azd $($smokeArguments -join ' ')"
    $smokeOutput = (& $azd.Path @smokeArguments 2>&1 | Out-String)
    $smokeOutput | Write-Host
    if ($LASTEXITCODE -eq 0) {
        return
    }

    if ($smokeOutput -match 'session_not_ready' -or $smokeOutput -match 'HTTP 424') {
        throw "Hosted-agent smoke invoke failed after deploy: the deployed container did not become ready. Check 'azd ai agent monitor win365-desktop-agent --tail 150' for the container's startup logs (a common cause is a missing required environment variable such as OPERATOR_TENANT_ID, OPERATOR_OBJECT_ID, or HOSTED_ALLOWED_USER_ID)."
    }

    Write-DeploymentEvent DECISION 'Smoke invoke reached the agent but was rejected for an application-level reason (not a readiness failure); the deployed container is healthy.'
}

function Assert-ResourceConfirmation {
    if (!$ConfirmResourceChanges) {
        throw "Mode '$Mode' can create or modify Azure resources. Review the validation log, then rerun with -ConfirmResourceChanges."
    }
    Write-DeploymentEvent DECISION 'Azure resource changes explicitly confirmed by the caller.'
}

function Has-ProjectEndpoint {
    param([string]$Value)

    return ![string]::IsNullOrWhiteSpace($Value)
}

function Invoke-FoundryLocalValidation {
    param([string]$ProjectEndpoint)

    if (Has-ProjectEndpoint $ProjectEndpoint) {
        Write-DeploymentEvent STEP 'Validating the local Foundry manifest and environment.'
        Invoke-Azd @('ai', 'agent', 'doctor', '--local-only')
        return
    }

    Write-DeploymentEvent DECISION 'Skipping azd ai agent doctor --local-only until the Foundry project endpoint exists.'
}

function Preview-FoundryLayer {
    Write-DeploymentEvent STEP 'Previewing the Foundry infrastructure layer.'
    Invoke-Azd @('provision', 'foundry', '--preview', '--no-prompt')
}

function Provision-FoundryLayer {
    Write-DeploymentEvent STEP 'Provisioning the Foundry infrastructure layer.'
    Invoke-Azd @('provision', 'foundry', '--no-prompt')
}

Push-Location $root
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
Start-Transcript -LiteralPath $logPath | Out-Null
try {
    Write-DeploymentEvent STEP "Starting '$Mode' workflow with azd $($azd.Version)."
    Write-DeploymentEvent RESULT "Transcript: $logPath"

    if ($Environment) {
        Write-DeploymentEvent DECISION "Selecting requested azd environment '$Environment'."
        Invoke-Azd @('env', 'select', $Environment)
    }

    & (Join-Path (Split-Path $PSScriptRoot) 'tests\PowerShell\Test-AzdPrerequisites.ps1') -RequireLogin
    if ($LASTEXITCODE -ne 0) {
        throw 'azd prerequisite validation failed.'
    }

    $environmentName = Get-AzdValue 'AZURE_ENV_NAME'
    $projectEndpoint = Get-AzdValue 'FOUNDRY_PROJECT_ENDPOINT'
    $w365Enabled = Get-AzdValue 'W365_ENABLED'
    $stateEnabled = Get-AzdValue 'DEPLOY_STATE'
    $viewerEnabled = Get-AzdValue 'DEPLOY_VIEWER'

    Write-DeploymentEvent DECISION "Environment: $environmentName"
    $foundryDecision = if ([string]::IsNullOrWhiteSpace($projectEndpoint)) {
        'Foundry: greenfield project provisioning.'
    }
    else {
        'Foundry: existing project binding; no replacement project should be created.'
    }
    Write-DeploymentEvent DECISION $foundryDecision
    Write-DeploymentEvent DECISION "W365 live integration enabled: $w365Enabled"
    Write-DeploymentEvent DECISION "Shared Blob state enabled: $stateEnabled"
    Write-DeploymentEvent DECISION "Optional viewer enabled: $viewerEnabled"

    Invoke-FoundryLocalValidation -ProjectEndpoint $projectEndpoint
    $needsFoundryProvisioning = !(Has-ProjectEndpoint $projectEndpoint)
    if ($needsFoundryProvisioning -or $Mode -eq 'ProvisionFoundry') {
        Preview-FoundryLayer
    }
    else {
        Write-DeploymentEvent DECISION 'Foundry preview skipped because the environment is already bound to an existing project endpoint.'
    }

    if ($stateEnabled -eq 'true') {
        $stateAgentPrincipalId = Get-AzdValue 'STATE_AGENT_PRINCIPAL_ID'
        if ([string]::IsNullOrWhiteSpace($stateAgentPrincipalId) -or
            $stateAgentPrincipalId -eq '00000000-0000-0000-0000-000000000000') {
            throw 'DEPLOY_STATE=true requires STATE_AGENT_PRINCIPAL_ID from the deployed phase-1 agent.'
        }
        Write-DeploymentEvent DECISION "State access principal: $stateAgentPrincipalId"
        Write-DeploymentEvent STEP 'Previewing the explicitly enabled state layer.'
        Invoke-Azd @('provision', 'state', '--preview', '--no-prompt')
    }
    else {
        Write-DeploymentEvent DECISION 'State preview skipped because DEPLOY_STATE=false.'
    }

    if ($viewerEnabled -eq 'true') {
        Assert-ViewerManagedEnvironmentResourceId `
            -ResourceId (Get-AzdOptionalValue 'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID')
        Assert-ViewerSharedStateConfiguration `
            -DeployState $stateEnabled `
            -StateResourceGroupName (Get-AzdValue 'AZURE_RESOURCE_GROUP') `
            -StateStorageAccountName (Get-AzdValue 'STATE_STORAGE_ACCOUNT_NAME') `
            -StateContainerName (Get-AzdValue 'STATE_CONTAINER_NAME') `
            -SessionBlobUri (Get-AzdValue 'SESSION_BLOB_URI')
        Assert-LiveViewerConfiguration
        Write-DeploymentEvent STEP 'Previewing the explicitly enabled viewer layer.'
        Invoke-Azd @('provision', 'viewer', '--preview', '--no-prompt')
    }
    else {
        Write-DeploymentEvent DECISION 'Viewer preview skipped because DEPLOY_VIEWER=false.'
    }

    if ($Mode -in @('DeployAgent', 'DeployAll')) {
        Assert-W365AgentKeyVaultAccessConfigured
    }

    if (!$SkipPackage) {
        Write-DeploymentEvent STEP 'Packaging the hosted agent without deploying it.'
        Invoke-Azd @('package', 'win365-desktop-agent', '--no-prompt')
    }

    switch ($Mode) {
        'Validate' {
            if (!(Has-ProjectEndpoint $projectEndpoint)) {
                Write-DeploymentEvent DECISION 'Remote Foundry checks skipped because the project endpoint will be created during provisioning.'
                break
            }
            Write-DeploymentEvent STEP 'Running remote Foundry readiness checks.'
            Invoke-Azd @('ai', 'agent', 'doctor')
        }
        'ProvisionFoundry' {
            Assert-ResourceConfirmation
            if (!$needsFoundryProvisioning) {
                Write-DeploymentEvent DECISION 'Foundry provisioning skipped because the environment is already bound to an existing project endpoint.'
                break
            }
            Provision-FoundryLayer
        }
        'DeployAgent' {
            Assert-ResourceConfirmation
            Write-DeploymentEvent STEP 'Deploying a new immutable hosted-agent version.'
            Invoke-Azd @('deploy', 'win365-desktop-agent', '--no-prompt')
            Invoke-Azd @('ai', 'agent', 'doctor')
            Invoke-HostedAgentSmokeTest
        }
        'DeployAll' {
            Assert-ResourceConfirmation
            if ($needsFoundryProvisioning) {
                Provision-FoundryLayer
                $projectEndpoint = Get-AzdValue 'FOUNDRY_PROJECT_ENDPOINT'
                if (!(Has-ProjectEndpoint $projectEndpoint)) {
                    throw 'Foundry provisioning completed but FOUNDRY_PROJECT_ENDPOINT is still empty.'
                }
                Invoke-FoundryLocalValidation -ProjectEndpoint $projectEndpoint
            }
            else {
                Write-DeploymentEvent DECISION 'Foundry provisioning skipped because the environment is already bound to an existing project endpoint.'
            }

            if ($stateEnabled -eq 'true') {
                Write-DeploymentEvent STEP 'Provisioning the explicitly enabled state layer.'
                Invoke-Azd @('provision', 'state', '--no-prompt')
            }

            if ($viewerEnabled -eq 'true') {
                Write-DeploymentEvent STEP 'Provisioning the explicitly enabled viewer layer.'
                Invoke-Azd @('provision', 'viewer', '--no-prompt')
            }

            Write-DeploymentEvent STEP 'Deploying a new immutable hosted-agent version.'
            Invoke-Azd @('deploy', 'win365-desktop-agent', '--no-prompt')
            Invoke-Azd @('ai', 'agent', 'doctor')
            Invoke-HostedAgentSmokeTest
        }
    }

    if ($Mode -ne 'ProvisionFoundry') {
        $agentVersion = Get-AzdOptionalValue 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
        if (![string]::IsNullOrWhiteSpace($agentVersion)) {
            Write-DeploymentEvent RESULT "Hosted agent version: $agentVersion"
        }
        elseif ($Mode -eq 'Validate') {
            Write-DeploymentEvent DECISION 'Hosted agent version is not available yet because this environment has not deployed an agent build.'
        }
    }
    Write-DeploymentEvent RESULT "Workflow '$Mode' completed successfully."
}
catch {
    Write-DeploymentEvent RESULT "Workflow '$Mode' failed: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
    Pop-Location
}
