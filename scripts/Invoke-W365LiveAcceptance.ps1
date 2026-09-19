#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{1,11}$')]
    [string]$Prefix,
    [Parameter(Mandatory)][string]$Location,
    [guid]$PoolBillingPlanId = [guid]::Empty,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')]
    [string]$AgentUserDomain,
    [ValidateSet('I_APPROVE_W365_BILLING_AND_CLEANUP')]
    [string]$ApprovalPhrase,
    [switch]$Resume,
    [switch]$RemoveEnvironmentAfterCleanup,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),
    [string]$EvidenceDirectory = (Join-Path (Split-Path $PSScriptRoot) 'artifacts\w365-live-acceptance'),
    [string]$AzdPath,
    [string]$InitializerScriptPath = (Join-Path $PSScriptRoot 'Initialize-Greenfield.ps1'),
    [string]$VerifierScriptPath = (Join-Path $PSScriptRoot 'Test-W365LiveDeployment.ps1'),
    [string]$PrerequisiteScriptPath = (Join-Path (Split-Path $PSScriptRoot) 'tests\PowerShell\Test-AzdPrerequisites.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'W365 live acceptance is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')

function Invoke-AcceptanceAzd {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Write-Host ('[{0:HH:mm:ss}] [COMMAND] azd {1}' -f [DateTimeOffset]::Now, ($Arguments -join ' '))
    $global:LASTEXITCODE = 0
    & $script:AzdPath @Arguments
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-AcceptanceAzdValue {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Name
    )

    $global:LASTEXITCODE = 0
    $value = & $script:AzdPath env get-value $Name --environment $EnvironmentName
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw "Unable to read azd environment value '$Name' from '$EnvironmentName'."
    }

    return ($value | Out-String).Trim().Trim('"')
}

function Assert-W365AcceptanceProfile {
    $deploymentConfig = Get-DeploymentConfig -RepositoryRoot $RepositoryRoot
    $w365 = $deploymentConfig.Values.w365
    if (!($w365 -is [System.Collections.IDictionary])) {
        throw "Configuration '$($deploymentConfig.Path)' does not contain a W365 profile."
    }

    $requiredStrings = @(
        'poolBillingPlanId',
        'poolGeographicLocationType',
        'poolRegionGroup',
        'poolImageId'
    )
    $missing = @($requiredStrings | Where-Object {
        !$w365.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$w365[$_])
    })
    if (!$w365.Contains('poolRegions') -or
        @($w365.poolRegions | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
        $missing += 'poolRegions'
    }
    if ($missing.Count -gt 0) {
        throw @"
The W365 acceptance profile is incomplete: $($missing -join ', ').
The checked-in sample defaults provide:
  geographic location type: usCentral
  region group:              usCentral
  regions:                   centralus
  gallery image:             microsoftwindowsdesktop_windows-ent-cpc_win11-25h2-ent-cpc-m365
Supply the tenant-specific billing plan with -PoolBillingPlanId, or override
unsupported defaults in config\deployment.local.json.
"@
    }

    $billingPlanId = [guid]::Empty
    if (![guid]::TryParse([string]$w365.poolBillingPlanId, [ref]$billingPlanId) -or
        $billingPlanId -eq [guid]::Empty) {
        throw 'w365.poolBillingPlanId must be a non-empty GUID.'
    }
    if ([int]$w365.poolMinimumCount -ne 1 -or [int]$w365.poolMaximumCount -ne 1) {
        throw 'Live acceptance requires w365.poolMinimumCount and w365.poolMaximumCount to both be 1.'
    }

    return [pscustomobject]@{
        Path = $deploymentConfig.Path
        LocalOverridePath = $deploymentConfig.LocalOverridePath
        GeographicLocationType = [string]$w365.poolGeographicLocationType
        RegionGroup = [string]$w365.poolRegionGroup
        Regions = @($w365.poolRegions | ForEach-Object { [string]$_ })
        ImageId = [string]$w365.poolImageId
        RegionCount = @($w365.poolRegions).Count
    }
}

function Initialize-W365AcceptanceProfile {
    $baseConfig = Read-DeploymentConfigFile -Path (Join-Path $RepositoryRoot 'config\deployment.defaults.json')
    $acceptanceDefaults = $baseConfig.w365AcceptanceDefaults
    if (!($acceptanceDefaults -is [hashtable])) {
        throw 'Configuration does not contain w365AcceptanceDefaults.'
    }
    $localConfigPath = Join-Path $RepositoryRoot 'config\deployment.local.json'
    $localConfig = if (Test-Path -LiteralPath $localConfigPath) {
        Read-DeploymentConfigFile -Path $localConfigPath
    }
    else {
        @{}
    }
    if (!$localConfig.ContainsKey('w365') -or !($localConfig.w365 -is [hashtable])) {
        $localConfig.w365 = @{}
    }

    foreach ($entry in $acceptanceDefaults.GetEnumerator()) {
        if (!$localConfig.w365.ContainsKey($entry.Key)) {
            $localConfig.w365[$entry.Key] = $entry.Value
        }
    }
    if ($PoolBillingPlanId -ne [guid]::Empty) {
        $localConfig.w365.poolBillingPlanId = $PoolBillingPlanId.ToString()
    }
    $localConfig | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $localConfigPath -Encoding utf8
}

function Confirm-W365Acceptance {
    if ($ApprovalPhrase -eq 'I_APPROVE_W365_BILLING_AND_CLEANUP') {
        return
    }

    Write-Host ''
    Write-Host 'This acceptance run can create a Foundry account, model deployment,'
    Write-Host 'hosted agent, Entra agent user, and a billable minimum-capacity W365 pool.'
    Write-Host 'The script always attempts ownership-driven cleanup, including after failure.'
    $answer = Read-Host 'Type I_APPROVE_W365_BILLING_AND_CLEANUP to continue'
    if ($answer -cne 'I_APPROVE_W365_BILLING_AND_CLEANUP') {
        throw 'W365 live acceptance billing and cleanup were not approved.'
    }
}

foreach ($path in @($RepositoryRoot, $InitializerScriptPath, $VerifierScriptPath, $PrerequisiteScriptPath)) {
    if (!(Test-Path -LiteralPath $path)) {
        throw "Required live acceptance path '$path' was not found."
    }
}

$resolvedAzd = if (![string]::IsNullOrWhiteSpace($AzdPath)) {
    [pscustomobject]@{ Path = $AzdPath }
}
else {
    Get-W365AzdCommand
}
if (!$resolvedAzd -or !(Test-Path -LiteralPath $resolvedAzd.Path)) {
    throw 'Azure Developer CLI 1.32.0 or later is required.'
}
$AzdPath = $resolvedAzd.Path

$azdDirectory = Split-Path -Parent $AzdPath

$environmentName = "$Prefix-live"
$environmentRoot = Join-Path $RepositoryRoot ".azure\$environmentName"
$environmentExists = Test-Path -LiteralPath $environmentRoot -PathType Container
if ($environmentExists -and !$Resume) {
    throw "Azd environment '$environmentName' already exists. Use -Resume only after reviewing its ownership state."
}
if (!$environmentExists -and $Resume) {
    throw "Azd environment '$environmentName' does not exist, so it cannot be resumed."
}

Initialize-W365AcceptanceProfile
$profile = Assert-W365AcceptanceProfile
if (!(Get-Module -Name Microsoft.Graph.Authentication) -and
    !(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is required. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}

& $PrerequisiteScriptPath -RequireLogin

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$firstEvidence = Join-Path $EvidenceDirectory "$environmentName-first.json"
$rerunEvidence = Join-Path $EvidenceDirectory "$environmentName-rerun.json"
$cleanupEvidence = Join-Path $EvidenceDirectory "$environmentName-cleanup.json"
$primaryError = $null
$cleanupError = $null
$cleanupComplete = $false
$cleanupRequired = $false
$previousPath = $env:Path
$env:Path = "$azdDirectory;$previousPath"

try {
    if (!$Resume) {
        $initializerArguments = @{
            SubscriptionId = $SubscriptionId
            TenantId = $TenantId
            Prefix = $Prefix
            Environment = 'live'
            Location = $Location
            EnableW365 = $true
        }
        if (![string]::IsNullOrWhiteSpace($AgentUserDomain)) {
            $initializerArguments.AgentUserDomain = $AgentUserDomain
        }
        & $InitializerScriptPath @initializerArguments
    }
    else {
        Invoke-AcceptanceAzd @('env', 'select', $environmentName)
        $expectedValues = @{
            AZURE_SUBSCRIPTION_ID = $SubscriptionId.ToString()
            AZURE_TENANT_ID = $TenantId.ToString()
            AZURE_LOCATION = $Location
            ENABLE_W365 = 'true'
        }
        foreach ($entry in $expectedValues.GetEnumerator()) {
            $actual = Get-AcceptanceAzdValue -EnvironmentName $environmentName -Name $entry.Key
            if ($actual -ne $entry.Value) {
                throw "Azd environment '$environmentName' value '$($entry.Key)' does not match the requested context."
            }
        }

        $manifestPath = Join-Path $environmentRoot 'w365-ownership.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 40
            if ($manifest.Contains('cleanup') -and
                [string]$manifest.cleanup.status -eq 'completed') {
                throw "Azd environment '$environmentName' has already completed cleanup and cannot be resumed."
            }
        }
    }

    Write-Host ''
    Write-Host "Acceptance environment: $environmentName"
    Write-Host "Azure location:        $Location"
    Write-Host "W365 profile:          $($profile.LocalOverridePath)"
    Write-Host "W365 geography:        $($profile.GeographicLocationType)"
    Write-Host "W365 region group:     $($profile.RegionGroup)"
    Write-Host "W365 regions:          $($profile.Regions -join ', ')"
    Write-Host "W365 gallery image:    $($profile.ImageId)"
    Confirm-W365Acceptance
    $cleanupRequired = $true

    $previousResourceApproval = $env:W365_RESOURCE_CHANGES_CONFIRMED
    $env:W365_RESOURCE_CHANGES_CONFIRMED = 'true'
    try {
        Invoke-AcceptanceAzd @('up', '--environment', $environmentName, '--no-prompt')
        $first = & $VerifierScriptPath `
            -EnvironmentName $environmentName `
            -RepositoryRoot $RepositoryRoot `
            -EvidencePath $firstEvidence
        Invoke-AcceptanceAzd @('ai', 'agent', 'doctor', '--environment', $environmentName, '--no-prompt')

        Invoke-AcceptanceAzd @('up', '--environment', $environmentName, '--no-prompt')
        & $VerifierScriptPath `
            -EnvironmentName $environmentName `
            -RepositoryRoot $RepositoryRoot `
            -ExpectedManifestSha256 $first.ownershipManifestSha256 `
            -EvidencePath $rerunEvidence | Out-Null
        Invoke-AcceptanceAzd @('ai', 'agent', 'doctor', '--environment', $environmentName, '--no-prompt')
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'W365_RESOURCE_CHANGES_CONFIRMED',
            $previousResourceApproval,
            'Process')
    }
}
catch {
    $primaryError = $_
}
finally {
    try {
        if ($cleanupRequired -and
            (Test-Path -LiteralPath $environmentRoot -PathType Container)) {
            $previousCleanupApproval = $env:W365_CLEANUP_CONFIRMED
            $env:W365_CLEANUP_CONFIRMED = 'true'
            try {
                Invoke-AcceptanceAzd @('down', '--environment', $environmentName, '--force', '--purge', '--no-prompt')
            }
            finally {
                [Environment]::SetEnvironmentVariable(
                    'W365_CLEANUP_CONFIRMED',
                    $previousCleanupApproval,
                    'Process')
            }

            & $VerifierScriptPath `
                -EnvironmentName $environmentName `
                -RepositoryRoot $RepositoryRoot `
                -RequireCleanupComplete `
                -EvidencePath $cleanupEvidence | Out-Null
            $cleanupComplete = $true

            if ($RemoveEnvironmentAfterCleanup) {
                Invoke-AcceptanceAzd @('env', 'remove', $environmentName, '--force')
            }
        }
    }
    catch {
        $cleanupError = $_
    }
    finally {
        $env:Path = $previousPath
    }
}

if ($cleanupError) {
    if ($primaryError) {
        throw "W365 live acceptance failed: $($primaryError.Exception.Message) Cleanup also failed: $($cleanupError.Exception.Message) The azd environment and ownership evidence were retained."
    }
    throw "W365 live acceptance cleanup failed: $($cleanupError.Exception.Message) The azd environment and ownership evidence were retained."
}
if ($primaryError) {
    throw "W365 live acceptance failed, but cleanup completed: $($primaryError.Exception.Message)"
}
if (!$cleanupComplete) {
    throw 'W365 live acceptance ended without proving cleanup.'
}

Write-Host ''
Write-Host "W365 live acceptance passed for '$environmentName'."
Write-Host "Sanitized evidence: $EvidenceDirectory"
if (!$RemoveEnvironmentAfterCleanup) {
    Write-Host "Cleaned azd state retained for review: $environmentRoot"
}
