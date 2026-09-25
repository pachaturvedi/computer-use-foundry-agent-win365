#Requires -Version 7.4
<#
.SYNOPSIS
Runs guarded validation, provisioning, and hosted-agent deployment modes.

.DESCRIPTION
Validates project and credential prerequisites, previews or provisions Foundry, packages and deploys the hosted agent, verifies Key Vault RBAC, runs Foundry doctor, and optionally smoke-invokes the active version.


Key inputs: Mode selects Validate, ProvisionFoundry, DeployAgent, or DeployAll. Environment, ConfigPath, confirmation, packaging, and smoke-test options refine execution.

.OUTPUTS
Deployment events, azd outputs, active agent version, doctor results, and optional smoke-test results.

.NOTES
Mutating modes require ConfirmResourceChanges. Secrets are injected only into the child deployment process and then cleared.
#>
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
. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
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
foreach ($command in @(Get-Command azd -All -CommandType Application -ErrorAction SilentlyContinue)) {
    if ($null -eq $command) {
        continue
    }

    $source = $command.Source
    if ([string]::IsNullOrWhiteSpace($source) -or !(Test-Path -LiteralPath $source -PathType Leaf)) {
        continue
    }

    if (!$azdPaths.Contains($source)) {
        $azdPaths.Add($source)
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
        $candidatePath = $_
        $versionOutput = $null
        try {
            $versionOutput = & $candidatePath version 2>$null
        }
        catch {
            return
        }

        if ($LASTEXITCODE -eq 0 -and ($versionOutput | Out-String) -match 'azd version\s+(\d+\.\d+\.\d+)') {
            [pscustomobject]@{ Path = $candidatePath; Version = [version]$Matches[1] }
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
        [switch]$CaptureOutput,
        [switch]$DetailedOutput
    )

    Write-DeploymentEvent COMMAND "azd $($Arguments -join ' ')"
    $output = & $azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        $output | Write-Host
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }
    if ($DetailedOutput -and (Get-SampleLogLevel) -eq 'summary') {
        Write-DeploymentEvent RESULT 'Preview completed; detailed resource changes are hidden in summary mode. Set SAMPLE_LOG_LEVEL=verbose or debug to show them.'
        return
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
    $requiredSecrets = if ((Get-AzdValue 'VIEWER_OIDC_CREDENTIAL_MODE' -AllowMissing) -eq 'client_secret') {
        @('w365-viewer-client-secret')
    } else { @() }
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

function Assert-CertificateStateReprovisionSafe {
    # infra/state/keyvault.bicep applies certificate/key-scoped RBAC only when the orchestration-owned
    # readiness gate is active or W365_ENABLED is already persisted as 'true'. If the blueprint
    # certificate already exists but setup has not yet persisted W365_ENABLED=true, reprovisioning the
    # state layer here would silently remove role assignments the certificate flow just granted. Fail
    # closed instead of reporting success for a deployment that revoked the agent's signing access.
    if ((Get-AzdOptionalValue 'W365_BLUEPRINT_CREDENTIAL_MODE') -ne 'key_vault_certificate' -or
        (Get-AzdOptionalValue 'W365_ENABLED') -eq 'true') {
        return
    }

    $vaultName = Get-W365KeyVaultName
    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        return
    }
    & az keyvault certificate show `
        --subscription (Get-AzdValue 'AZURE_SUBSCRIPTION_ID') `
        --vault-name $vaultName `
        --name 'w365-blueprint-certificate' `
        --query id `
        --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        return
    }

    throw "Blueprint certificate 'w365-blueprint-certificate' already exists in '$vaultName', but W365_ENABLED is not yet 'true'. Reprovisioning the state layer now would revoke the agent's certificate- and key-scoped Key Vault roles. Complete Windows 365 setup first (scripts\Complete-AzdUp.ps1 or scripts\Invoke-W365SetupFlow.ps1) so W365_ENABLED is persisted as 'true', then re-run this deployment."
}

function Assert-W365AgentKeyVaultAccessConfigured {
    # The hosted agent now fetches the blueprint client secret directly from Key Vault using its
    # own runtime identity (KeyVaultBlueprintSecretResolver) instead of receiving it as an
    # environment variable. Confirms both that the secret exists and that the agent's principal
    # actually holds the Key Vault Secrets User role assignment provisioned by
    # infra/state/keyvault.bicep before deployment, so a missing/unprovisioned state layer fails
    # here instead of surfacing as a live startup failure.
    if ((Get-AzdOptionalValue 'W365_ENABLED') -ne 'true' -or
        (Get-AzdOptionalValue 'W365_BLUEPRINT_CREDENTIAL_MODE') -ne 'client_secret') {
        return
    }

    $vaultName = Get-W365KeyVaultName
    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        throw 'Client-secret mode requires W365_KEY_VAULT_NAME (or VIEWER_KEY_VAULT_NAME) to resolve the Key Vault holding w365-blueprint-client-secret.'
    }
    $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    & az keyvault secret show `
        --subscription $subscriptionId `
        --vault-name $vaultName `
        --name 'w365-blueprint-client-secret' `
        --query id `
        --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Key Vault '$vaultName' must contain secret 'w365-blueprint-client-secret' before deploying the hosted agent in client_secret mode."
    }

    $agentPrincipalId = Get-AzdOptionalValue 'STATE_AGENT_PRINCIPAL_ID'
    if ([string]::IsNullOrWhiteSpace($agentPrincipalId)) {
        throw 'Client-secret mode requires STATE_AGENT_PRINCIPAL_ID so the deployed agent identity can be verified against Key Vault RBAC.'
    }
    $vaultId = (& az keyvault show `
        --subscription $subscriptionId `
        --name $vaultName `
        --query id `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
        throw "Unable to resolve the resource ID of Key Vault '$vaultName' to verify agent RBAC."
    }
    # Key Vault Secrets User role definition ID, matching infra/state/keyvault.bicep.
    $secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
    $assignmentCount = (& az role assignment list `
        --subscription $subscriptionId `
        --assignee-object-id $agentPrincipalId `
        --fill-principal-name false `
        --scope $vaultId `
        --query "length([?roleDefinitionId.ends_with(@, '$secretsUserRoleId')])" `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $assignmentCount -eq '0' -or [string]::IsNullOrWhiteSpace($assignmentCount)) {
        throw "Agent principal '$agentPrincipalId' does not have Key Vault Secrets User on '$vaultName'. Run 'azd provision state --environment <env> --no-prompt' so infra/state/keyvault.bicep grants this role, then redeploy the hosted agent."
    }
    Write-DeploymentEvent DECISION "Confirmed 'w365-blueprint-client-secret' exists in '$vaultName' and agent principal '$agentPrincipalId' has Key Vault Secrets User on it."
}

function Assert-W365AgentCertificateKeyVaultAccessConfigured {
    # Mirrors Assert-W365AgentKeyVaultAccessConfigured for key_vault_certificate mode: confirms the
    # blueprint certificate exists and that the agent's runtime principal actually holds the
    # certificate- and key-scoped role assignments provisioned by infra/state/keyvault.bicep
    # (Key Vault Certificate User on the certificate object, Key Vault Crypto User on its backing
    # key) before deployment. Because these roles were later re-scoped from the whole vault to the
    # specific certificate/key objects, a state layer that was provisioned before the mode was
    # switched to key_vault_certificate (or before the certificate existed) can leave the agent
    # without this access; this check fails fast here instead of surfacing as a live signing
    # failure.
    if ((Get-AzdOptionalValue 'W365_ENABLED') -ne 'true' -or
        (Get-AzdOptionalValue 'W365_BLUEPRINT_CREDENTIAL_MODE') -ne 'key_vault_certificate') {
        return
    }

    $vaultName = Get-W365KeyVaultName
    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        throw 'key_vault_certificate mode requires W365_KEY_VAULT_NAME (or VIEWER_KEY_VAULT_NAME) to resolve the Key Vault holding w365-blueprint-certificate.'
    }
    $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    $certificateName = 'w365-blueprint-certificate'
    $certificateShowOutput = (& az keyvault certificate show `
        --subscription $subscriptionId `
        --vault-name $vaultName `
        --name $certificateName `
        --query id `
        --output tsv 2>&1 | Out-String).Trim()
    $certificateShowFailed = $LASTEXITCODE -ne 0
    $certificateId = if ($certificateShowFailed) { '' } else { $certificateShowOutput }
    if ($certificateShowFailed -or [string]::IsNullOrWhiteSpace($certificateId)) {
        # A data-plane authorization failure is not a missing certificate. Reporting it as one sends
        # the operator to re-run certificate creation, which cannot fix an RBAC gap.
        if ($certificateShowOutput -match '(?i)(^|\W)(403|Forbidden|AuthorizationFailed|AccessDenied)(\W|$)|Caller is not authorized') {
            throw "The current operator is not authorized to read certificate '$certificateName' in Key Vault '$vaultName', so its presence could not be verified. Grant the operator Key Vault Certificates Officer on the vault and re-run; certificate creation will not resolve this."
        }
        throw "Key Vault '$vaultName' must contain certificate '$certificateName' before deploying the hosted agent in key_vault_certificate mode. Run scripts\Initialize-W365BlueprintCertificate.ps1 first."
    }

    $agentPrincipalId = Get-AzdOptionalValue 'STATE_AGENT_PRINCIPAL_ID'
    if ([string]::IsNullOrWhiteSpace($agentPrincipalId)) {
        throw 'key_vault_certificate mode requires STATE_AGENT_PRINCIPAL_ID so the deployed agent identity can be verified against Key Vault RBAC.'
    }
    $vaultId = (& az keyvault show `
        --subscription $subscriptionId `
        --name $vaultName `
        --query id `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
        throw "Unable to resolve the resource ID of Key Vault '$vaultName' to verify agent RBAC."
    }
    $certificateScope = "$vaultId/certificates/$certificateName"
    $keyScope = "$vaultId/keys/$certificateName"
    # Role definition IDs matching infra/state/keyvault.bicep.
    $certificateUserRoleId = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    $cryptoUserRoleId = '12338af0-0e69-4776-bea7-57ae8d297424'

    $hasCertificateRole = (& az role assignment list `
        --subscription $subscriptionId `
        --assignee-object-id $agentPrincipalId `
        --fill-principal-name false `
        --scope $certificateScope `
        --query "length([?roleDefinitionId.ends_with(@, '$certificateUserRoleId')])" `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $hasCertificateRole -eq '0' -or [string]::IsNullOrWhiteSpace($hasCertificateRole)) {
        throw "Agent principal '$agentPrincipalId' does not have Key Vault Certificate User on certificate '$certificateName' in '$vaultName'. Complete Windows 365 setup so W365_ENABLED is persisted as 'true' and the certificate is registered, then run 'azd provision state --environment <env> --no-prompt' so infra/state/keyvault.bicep grants this role, and redeploy the hosted agent."
    }

    $hasCryptoRole = (& az role assignment list `
        --subscription $subscriptionId `
        --assignee-object-id $agentPrincipalId `
        --fill-principal-name false `
        --scope $keyScope `
        --query "length([?roleDefinitionId.ends_with(@, '$cryptoUserRoleId')])" `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $hasCryptoRole -eq '0' -or [string]::IsNullOrWhiteSpace($hasCryptoRole)) {
        throw "Agent principal '$agentPrincipalId' does not have Key Vault Crypto User on the backing key of certificate '$certificateName' in '$vaultName'. Complete Windows 365 setup so W365_ENABLED is persisted as 'true' and the certificate is registered, then run 'azd provision state --environment <env> --no-prompt' so infra/state/keyvault.bicep grants this role, and redeploy the hosted agent."
    }
    Write-DeploymentEvent DECISION "Confirmed certificate '$certificateName' exists in '$vaultName' and agent principal '$agentPrincipalId' has Key Vault Certificate User and Key Vault Crypto User on it."
}

function Get-HostedOperatorBindingFingerprint {
    param([Parameter(Mandatory)][string]$InvocationOutput)

    $bindingResponses = @(
        foreach ($line in @($InvocationOutput -split '\r?\n')) {
            $candidate = $line.Trim()
            if (!$candidate.StartsWith('{') -or !$candidate.EndsWith('}')) {
                continue
            }

            try {
                $response = $candidate | ConvertFrom-Json -Depth 10
            }
            catch {
                continue
            }
            $errorProperty = $response.PSObject.Properties['error']
            if ($null -eq $errorProperty) {
                continue
            }
            $codeProperty = $errorProperty.Value.PSObject.Properties['code']
            if ($null -ne $codeProperty -and $codeProperty.Value -eq 'operator_binding_required') {
                $response
            }
        }
    )
    if ($bindingResponses.Count -eq 0) {
        return ''
    }
    if ($bindingResponses.Count -ne 1) {
        throw 'Hosted-agent operator binding response was ambiguous. The binding was not changed.'
    }

    $fingerprintProperty = $bindingResponses[0].error.PSObject.Properties['fingerprint']
    $fingerprint = if ($null -eq $fingerprintProperty) { '' } else { [string]$fingerprintProperty.Value }
    if ($fingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Hosted-agent operator binding response was missing a single valid sha256 fingerprint. The binding was not changed.'
    }

    return $fingerprint
}

function Test-HostedAgentSmokeSucceeded {
    param([Parameter(Mandatory)][string]$InvocationOutput)

    $trimmed = $InvocationOutput.Trim()
    if ($trimmed -eq 'OK') {
        return $true
    }

    $agentResponses = @(
        [regex]::Matches(
            $InvocationOutput,
            '(?m)^\[win365-desktop-agent\]\s+(?<payload>[^\r\n]+?)\s*$')
    )
    if ($agentResponses.Count -ne 1 -or
        $agentResponses[0].Groups['payload'].Value -ne 'OK') {
        return $false
    }

    return $InvocationOutput -notmatch
        '(?im)^\s*(?:ERROR:|.*\b(?:desktop_state_error|operator_binding_required|w365_[a-z_]+_error)\b)'
}

function Invoke-HostedAgentSmokeTest {
    if (!$SmokeInvoke) {
        return
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $agentVersion = Get-AzdOptionalValue 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
        if ([string]::IsNullOrWhiteSpace($agentVersion)) {
            throw 'Hosted-agent smoke invoke requires AGENT_WIN365_DESKTOP_AGENT_VERSION after deployment.'
        }

        Write-DeploymentEvent STEP 'Smoke-testing the hosted agent with a minimal invocation to confirm the deployed container passes readiness.'
        $smokeArguments = @(
            'ai', 'agent', 'invoke', 'win365-desktop-agent',
            '--version', $agentVersion,
            '--new-session',
            '--timeout', 120,
            $SmokeInvokePrompt
        )
        Write-DeploymentEvent COMMAND "azd $($smokeArguments -join ' ')"
        $smokeOutput = (& $azd.Path @smokeArguments 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            if (Test-HostedAgentSmokeSucceeded -InvocationOutput $smokeOutput) {
                Write-DeploymentEvent RESULT 'Hosted-agent smoke invoke returned the expected OK response.'
                return
            }

            throw "Hosted-agent smoke invoke reached the deployed container but did not return the expected single-word OK response. Check 'azd ai agent monitor win365-desktop-agent --tail 150' for application diagnostics."
        }

        if ($smokeOutput -match 'session_not_ready' -or $smokeOutput -match 'HTTP 424') {
            throw "Hosted-agent smoke invoke failed after deploy: the deployed container did not become ready. Check 'azd ai agent monitor win365-desktop-agent --tail 150' for the container's startup logs (a common cause is a missing required environment variable such as OPERATOR_TENANT_ID, OPERATOR_OBJECT_ID, or HOSTED_ALLOWED_USER_ID)."
        }

        $bindingFingerprint = Get-HostedOperatorBindingFingerprint -InvocationOutput $smokeOutput
        if ([string]::IsNullOrWhiteSpace($bindingFingerprint)) {
            throw "Hosted-agent smoke invoke failed without a valid operator-binding response. Check 'azd ai agent monitor win365-desktop-agent --tail 150' for application diagnostics."
        }

        if ($attempt -ne 1) {
            throw 'Hosted-agent operator binding was still required after the one permitted binding redeployment. The workflow stopped without another mutation.'
        }
        $configuredBinding = Get-AzdOptionalValue 'HOSTED_ALLOWED_USER_ID'
        if ($configuredBinding -ne 'pending') {
            throw "Hosted-agent smoke invoke requested operator binding, but HOSTED_ALLOWED_USER_ID is already configured. The existing binding was preserved; verify that the intended Foundry caller is invoking this environment."
        }

        Write-DeploymentEvent DECISION 'Binding the Foundry caller from the guarded deployment smoke invoke; an existing concrete binding is never replaced automatically.'
        Invoke-Azd @(
            'env', 'set', 'HOSTED_ALLOWED_USER_ID', $bindingFingerprint,
            '--environment', $environmentName
        )
        [Environment]::SetEnvironmentVariable(
            'HOSTED_ALLOWED_USER_ID',
            $bindingFingerprint,
            'Process')
        Write-DeploymentEvent STEP 'Redeploying the same hosted-agent name once so the operator binding reaches a new immutable version.'
        Invoke-Azd @('deploy', 'win365-desktop-agent', '--no-prompt')
        Invoke-Azd @('ai', 'agent', 'doctor')
    }
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
    Invoke-Azd -Arguments @('provision', 'foundry', '--preview', '--no-prompt') -DetailedOutput
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
        Invoke-Azd -Arguments @('provision', 'state', '--preview', '--no-prompt') -DetailedOutput
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
        Invoke-Azd -Arguments @('provision', 'viewer', '--preview', '--no-prompt') -DetailedOutput
    }
    else {
        Write-DeploymentEvent DECISION 'Viewer preview skipped because DEPLOY_VIEWER=false.'
    }

    if ($Mode -in @('DeployAgent', 'DeployAll')) {
        Assert-W365AgentKeyVaultAccessConfigured
        Assert-W365AgentCertificateKeyVaultAccessConfigured
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
                Assert-CertificateStateReprovisionSafe
                Write-DeploymentEvent STEP 'Provisioning the explicitly enabled state layer.'
                Invoke-Azd @('provision', 'state', '--no-prompt')
            }

            if ($viewerEnabled -eq 'true') {
                Write-DeploymentEvent STEP 'Provisioning the explicitly enabled viewer layer.'
                Initialize-W365ViewerRegionEnvironment `
                    -EnvironmentName (Get-AzdValue 'AZURE_ENV_NAME') `
                    -ResourcePrefix (Get-AzdOptionalValue 'RESOURCE_PREFIX') `
                    -ResourceGroupName (Get-AzdOptionalValue 'AZURE_RESOURCE_GROUP') `
                    -ManagedEnvironmentResourceId (
                        Get-AzdOptionalValue 'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID') | Out-Null
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
