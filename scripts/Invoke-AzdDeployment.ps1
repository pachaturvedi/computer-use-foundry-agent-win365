#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'ProvisionFoundry', 'DeployAgent', 'DeployAll')]
    [string]$Mode = 'Validate',
    [string]$Environment,
    [string]$ConfigPath,
    [switch]$ConfirmResourceChanges,
    [switch]$SkipPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
        'VIEWER_KEY_VAULT_NAME'
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

    $vaultName = Get-AzdOptionalValue 'VIEWER_KEY_VAULT_NAME'
    & az keyvault secret show `
        --subscription (Get-AzdValue 'AZURE_SUBSCRIPTION_ID') `
        --vault-name $vaultName `
        --name 'w365-viewer-client-secret' `
        --query id `
        --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Key Vault '$vaultName' must contain secret 'w365-viewer-client-secret' before live viewer activation."
    }
    Write-DeploymentEvent DECISION 'Live viewer prerequisites and Key Vault OIDC secret are present.'
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

    & (Join-Path $PSScriptRoot 'Test-AzdPrerequisites.ps1') -RequireLogin
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
        Assert-LiveViewerConfiguration
        Write-DeploymentEvent STEP 'Previewing the explicitly enabled viewer layer.'
        Invoke-Azd @('provision', 'viewer', '--preview', '--no-prompt')
    }
    else {
        Write-DeploymentEvent DECISION 'Viewer preview skipped because DEPLOY_VIEWER=false.'
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
