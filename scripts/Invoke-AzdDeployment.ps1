#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'DeployAgent', 'DeployAll')]
    [string]$Mode = 'Validate',
    [string]$Environment,
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

$azdCandidates = Get-Command azd -All -ErrorAction Stop |
    Select-Object -ExpandProperty Source -Unique |
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

function Assert-ResourceConfirmation {
    if (!$ConfirmResourceChanges) {
        throw "Mode '$Mode' can create or modify Azure resources. Review the validation log, then rerun with -ConfirmResourceChanges."
    }
    Write-DeploymentEvent DECISION 'Azure resource changes explicitly confirmed by the caller.'
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

    Write-DeploymentEvent STEP 'Validating the local Foundry manifest and environment.'
    Invoke-Azd @('ai', 'agent', 'doctor', '--local-only')

    Write-DeploymentEvent STEP 'Previewing the Foundry infrastructure layer.'
    Invoke-Azd @('provision', 'foundry', '--preview', '--no-prompt')

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
            Write-DeploymentEvent STEP 'Running remote Foundry readiness checks.'
            Invoke-Azd @('ai', 'agent', 'doctor')
        }
        'DeployAgent' {
            Assert-ResourceConfirmation
            Write-DeploymentEvent STEP 'Deploying a new immutable hosted-agent version.'
            Invoke-Azd @('deploy', 'win365-desktop-agent', '--no-prompt')
            Invoke-Azd @('ai', 'agent', 'doctor')
        }
        'DeployAll' {
            Assert-ResourceConfirmation
            Write-DeploymentEvent STEP 'Provisioning and deploying all enabled layers and services.'
            Invoke-Azd @('up', '--no-prompt')
            Invoke-Azd @('ai', 'agent', 'doctor')
        }
    }

    $agentVersion = Get-AzdValue 'AGENT_WIN365_DESKTOP_AGENT_VERSION'
    Write-DeploymentEvent RESULT "Hosted agent version: $agentVersion"
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
