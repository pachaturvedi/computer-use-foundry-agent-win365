#Requires -Version 7.4
<#
.SYNOPSIS
Reconciles W365 and Entra setup for existing Foundry identities.

.DESCRIPTION
Validates blueprint/agent parentage and policy, reconciles resource declarations, grants and inheritance, creates or reuses the correctly parented agent user, creates or updates the approved pool, assigns the user, and writes ownership evidence.


Key inputs: Tenant, blueprint, agent identity, agent-user and pool settings, credential-federation approvals, billing confirmation, Graph options, azd-sync option, and manifest path.

.OUTPUTS
Non-secret W365 identifiers, azd environment values, and an ownership manifest.

.NOTES
WhatIf previews locally. Real mutation requires delegated Graph authorization and explicit billing/resource approval from the calling workflow.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$BlueprintId,
    [Parameter(Mandatory)][guid]$AgentIdentityId,
    [ValidatePattern('^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$')][string]$AgentUserPrincipalName,
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$AgentUserDomain,
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
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 2,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [switch]$SkipAzdEnvironmentSync,
    [string]$OwnershipManifestPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$repositoryRoot = Split-Path $PSScriptRoot
$deploymentConfig = Get-DeploymentConfig -RepositoryRoot $repositoryRoot
$setupBoundParameters = @{} + $PSBoundParameters
$w365Config = @{}
if ($deploymentConfig.Values.ContainsKey('w365') -and $deploymentConfig.Values.w365 -is [hashtable]) {
    $w365Config = $deploymentConfig.Values.w365
}

function Get-W365ConfiguredValue {
    param([Parameter(Mandatory)][string]$ConfigKey)

    if (!$script:w365Config.ContainsKey($ConfigKey)) {
        return $null
    }

    return $script:w365Config[$ConfigKey]
}

function Resolve-ConfiguredGuid {
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][guid]$CurrentValue,
        [Parameter(Mandatory)][string]$ConfigKey
    )

    if ($script:setupBoundParameters.ContainsKey($ParameterName) -or $CurrentValue -ne [guid]::Empty) {
        return $CurrentValue
    }

    $configuredValue = Get-W365ConfiguredValue -ConfigKey $ConfigKey
    if ([string]::IsNullOrWhiteSpace([string]$configuredValue)) {
        return $CurrentValue
    }

    $parsedValue = [guid]::Empty
    if (![guid]::TryParse([string]$configuredValue, [ref]$parsedValue) -or $parsedValue -eq [guid]::Empty) {
        throw "Configuration value 'w365.$ConfigKey' is not a valid GUID."
    }

    return $parsedValue
}

function Resolve-ConfiguredString {
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [string]$CurrentValue,
        [Parameter(Mandatory)][string]$ConfigKey
    )

    if ($script:setupBoundParameters.ContainsKey($ParameterName) -or ![string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    $configuredValue = Get-W365ConfiguredValue -ConfigKey $ConfigKey
    if ([string]::IsNullOrWhiteSpace([string]$configuredValue)) {
        return $CurrentValue
    }

    return [string]$configuredValue
}

function Resolve-ConfiguredStringArray {
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [string[]]$CurrentValue,
        [Parameter(Mandatory)][string]$ConfigKey
    )

    $resolvedCurrentValues = @($CurrentValue | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) })
    if ($script:setupBoundParameters.ContainsKey($ParameterName) -or $resolvedCurrentValues.Count -gt 0) {
        return $CurrentValue
    }

    $configuredValue = Get-W365ConfiguredValue -ConfigKey $ConfigKey
    if ($null -eq $configuredValue) {
        return $CurrentValue
    }

    return @($configuredValue | ForEach-Object { [string]$_ } | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
}

function Resolve-ConfiguredInt {
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][int]$CurrentValue,
        [Parameter(Mandatory)][string]$ConfigKey
    )

    if ($script:setupBoundParameters.ContainsKey($ParameterName)) {
        return $CurrentValue
    }

    $configuredValue = Get-W365ConfiguredValue -ConfigKey $ConfigKey
    if ($null -eq $configuredValue -or [string]::IsNullOrWhiteSpace([string]$configuredValue)) {
        return $CurrentValue
    }

    try {
        return [int]$configuredValue
    }
    catch {
        throw "Configuration value 'w365.$ConfigKey' is not a valid integer."
    }
}

function Resolve-ConfiguredSwitch {
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][bool]$CurrentValue,
        [Parameter(Mandatory)][string]$ConfigKey
    )

    if ($script:setupBoundParameters.ContainsKey($ParameterName)) {
        return $CurrentValue
    }

    $configuredValue = Get-W365ConfiguredValue -ConfigKey $ConfigKey
    if ($null -eq $configuredValue -or [string]::IsNullOrWhiteSpace([string]$configuredValue)) {
        return $CurrentValue
    }

    try {
        return [bool]$configuredValue
    }
    catch {
        throw "Configuration value 'w365.$ConfigKey' is not a valid boolean."
    }
}

$PoolId = Resolve-ConfiguredGuid -ParameterName 'PoolId' -CurrentValue $PoolId -ConfigKey 'poolId'
$PoolIdOrUrl = Resolve-ConfiguredString -ParameterName 'PoolIdOrUrl' -CurrentValue $PoolIdOrUrl -ConfigKey 'poolIdOrUrl'
$PoolDisplayName = Resolve-ConfiguredString -ParameterName 'PoolDisplayName' -CurrentValue $PoolDisplayName -ConfigKey 'poolDisplayName'
$PoolDescription = Resolve-ConfiguredString -ParameterName 'PoolDescription' -CurrentValue $PoolDescription -ConfigKey 'poolDescription'
$PoolBillingPlanId = Resolve-ConfiguredGuid -ParameterName 'PoolBillingPlanId' -CurrentValue $PoolBillingPlanId -ConfigKey 'poolBillingPlanId'
if ($PoolBillingPlanId -eq [guid]::Empty -and
    ![string]::IsNullOrWhiteSpace($env:W365_POOL_BILLING_PLAN_ID)) {
    $environmentBillingPlanId = [guid]::Empty
    if (![guid]::TryParse($env:W365_POOL_BILLING_PLAN_ID, [ref]$environmentBillingPlanId) -or
        $environmentBillingPlanId -eq [guid]::Empty) {
        throw 'W365_POOL_BILLING_PLAN_ID must be a non-empty GUID.'
    }
    $PoolBillingPlanId = $environmentBillingPlanId
}
$PoolBillingType = Resolve-ConfiguredString -ParameterName 'PoolBillingType' -CurrentValue $PoolBillingType -ConfigKey 'poolBillingType'
$PoolGeographicLocationType = Resolve-ConfiguredString -ParameterName 'PoolGeographicLocationType' -CurrentValue $PoolGeographicLocationType -ConfigKey 'poolGeographicLocationType'
$PoolRegionGroup = Resolve-ConfiguredString -ParameterName 'PoolRegionGroup' -CurrentValue $PoolRegionGroup -ConfigKey 'poolRegionGroup'
$PoolRegions = Resolve-ConfiguredStringArray -ParameterName 'PoolRegions' -CurrentValue $PoolRegions -ConfigKey 'poolRegions'
$PoolImageId = Resolve-ConfiguredString -ParameterName 'PoolImageId' -CurrentValue $PoolImageId -ConfigKey 'poolImageId'
$PoolImageType = Resolve-ConfiguredString -ParameterName 'PoolImageType' -CurrentValue $PoolImageType -ConfigKey 'poolImageType'
$PoolOsLocale = Resolve-ConfiguredString -ParameterName 'PoolOsLocale' -CurrentValue $PoolOsLocale -ConfigKey 'poolOsLocale'
$PoolMinimumCount = Resolve-ConfiguredInt -ParameterName 'PoolMinimumCount' -CurrentValue $PoolMinimumCount -ConfigKey 'poolMinimumCount'
$PoolMaximumCount = Resolve-ConfiguredInt -ParameterName 'PoolMaximumCount' -CurrentValue $PoolMaximumCount -ConfigKey 'poolMaximumCount'
$PoolEnableSingleSignOn = Resolve-ConfiguredSwitch -ParameterName 'PoolEnableSingleSignOn' -CurrentValue $PoolEnableSingleSignOn.IsPresent -ConfigKey 'poolEnableSingleSignOn'

if ($WhatIfPreference) {
    Write-Output "Plan only; no sign-in or network calls. Validate existing Foundry blueprint $BlueprintId and agent principal $AgentIdentityId in tenant $TenantId."
    $poolPlan = if ($PoolId -ne [guid]::Empty -or ![string]::IsNullOrWhiteSpace($PoolIdOrUrl)) {
        'resolve or update the requested Cloud PC pool'
    }
    else {
        'create or update the Cloud PC pool from the supplied pool configuration'
    }
    $agentUserPlan = if ([string]::IsNullOrWhiteSpace($AgentUserPrincipalName)) {
        'derive the agent-user UPN from the verified tenant domain, then create or reuse it'
    }
    else {
        "create or reuse agent user '$AgentUserPrincipalName'"
    }
    Write-Output "Reconcile permissions, $agentUserPlan, and $poolPlan. No blueprint, agent identity, certificate or secret will be created."
    if ($AuthorizeHostedRuntimeFederation) { Write-Output "Explicitly trust hosted runtime identity $HostedRuntimeIdentityObjectId on the existing blueprint. This trust can impersonate sibling agents." }
    if ($AuthorizeViewerFederation) { Write-Output "Explicitly trust viewer managed identity $ViewerManagedIdentityObjectId on the existing blueprint. This trust can impersonate sibling agents, not only screen sharing." }
    return
}
if ($AuthorizeHostedRuntimeFederation.IsPresent -ne ($HostedRuntimeIdentityObjectId -ne [guid]::Empty)) {
    throw 'Supply both -HostedRuntimeIdentityObjectId and -AuthorizeHostedRuntimeFederation, or neither. Federation grants blueprint-wide impersonation capability.'
}
if ($AuthorizeHostedRuntimeFederation -and $HostedRuntimeIdentityObjectId -ne $AgentIdentityId) {
    throw 'The hosted runtime federation subject must exactly match the supplied Foundry agent identity object ID.'
}
if ($AuthorizeViewerFederation.IsPresent -ne ($ViewerManagedIdentityObjectId -ne [guid]::Empty)) {
    throw 'Supply both -ViewerManagedIdentityObjectId and -AuthorizeViewerFederation, or neither. Federation grants blueprint-wide impersonation capability.'
}
if ($PoolMaximumCount -lt $PoolMinimumCount) {
    throw 'PoolMaximumCount must be greater than or equal to PoolMinimumCount.'
}
if (!$BillingConfirmed) { throw 'Read docs\W365-SETUP.md and pass -BillingConfirmed. Assignment permits consumption of paid Cloud PC capacity.' }
if (!$PSCmdlet.ShouldProcess("$TenantId / $BlueprintId / $AgentIdentityId", 'Configure existing Foundry identity, grant inherited consent (including sibling agents), create/reuse agent user and assign paid Cloud PC access')) { return }
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @(
    'Application.Read.All',
    'Domain.Read.All',
    'AgentIdentityBlueprint.ReadWrite.All', 'AgentIdentityBlueprint.UpdateAuthProperties.All',
    'AgentIdentity.Read.All', 'AgentIdUser.ReadWrite.All',
    'DelegatedPermissionGrant.ReadWrite.All', 'CloudPC.ReadWrite.All'
)
if ($AuthorizeHostedRuntimeFederation -or $AuthorizeViewerFederation) {
    $scopes += 'AgentIdentityBlueprint.AddRemoveCreds.All'
}
function Test-GraphContext {
    param(
        $Context,
        [guid]$RequiredTenantId,
        [string[]]$RequiredScopes
    )

    if ($null -eq $Context) {
        return $false
    }
    if ($Context.TenantId -ne $RequiredTenantId.ToString()) {
        return $false
    }
    if ($Context.AuthType -ne 'Delegated') {
        return $false
    }

    $missingScopes = @($RequiredScopes | Where-Object { $_ -notin $Context.Scopes })
    return $missingScopes.Count -eq 0
}

function Test-IsDeviceCodeTimeoutError {
    param([Parameter(Mandatory)]$ErrorRecord)

    return [string]$ErrorRecord.Exception.Message -match 'Authentication timed out after 120 seconds due to inactivity'
}

$context = Get-MgContext
if (!(Test-GraphContext -Context $context -RequiredTenantId $TenantId -RequiredScopes $scopes)) {
    $connectParameters = @{
        TenantId = $TenantId
        Scopes = $scopes
        ClientTimeout = $GraphClientTimeoutSeconds
        ContextScope = 'Process'
        NoWelcome = $true
    }

    if ($UseDeviceCode) {
        $connectParameters.UseDeviceCode = $true
        $connectParameters.InformationAction = 'Continue'
        Write-Host ''
        Write-Host 'Microsoft Graph administrator sign-in is required for W365 setup.'
        Write-Host 'When the device code appears:'
        Write-Host '  1. Open https://login.microsoft.com/device in a browser.'
        Write-Host '  2. Enter the displayed code and sign in with the authorized tenant administrator.'
        Write-Host '  3. Complete the prompt within 120 seconds; azd up waits for the result.'
        Write-Host ''

        for ($attempt = 1; $attempt -le $DeviceCodeMaxAttempts; $attempt++) {
            try {
                Write-Host "Starting Microsoft Graph device-code sign-in attempt $attempt of $DeviceCodeMaxAttempts..."
                Connect-MgGraph @connectParameters
                $context = Get-MgContext
                break
            }
            catch {
                if (!(Test-IsDeviceCodeTimeoutError -ErrorRecord $_) -or $attempt -eq $DeviceCodeMaxAttempts) {
                    throw
                }
                Write-Warning 'Microsoft Graph device-code sign-in timed out. Retrying with a fresh code...'
            }
        }
    }
    else {
        Connect-MgGraph @connectParameters
        $context = Get-MgContext
    }
}
if ($context.TenantId -ne $TenantId.ToString() -or $context.AuthType -ne 'Delegated') {
    throw 'A delegated Graph connection in the requested tenant is required.'
}
$missing = @($scopes | Where-Object { $_ -notin $context.Scopes })
if ($missing.Count) { throw "Missing Graph scopes: $($missing -join ', ')." }

function Graph([string]$Method, [string]$Path, $Body = $null) {
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://graph.microsoft.com/$Path" }
    if (!([uri]$uri).Host.Equals('graph.microsoft.com')) { throw 'Graph pagination returned an unexpected origin.' }
    $requestParameters = @{ Method = $Method; Uri = $uri; OutputType = 'Hashtable'; Headers = @{ 'OData-Version' = '4.0' } }
    if ($null -ne $Body) {
        $requestParameters.Body = ConvertTo-Json $Body -Depth 30 -Compress
        $requestParameters.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @requestParameters
}
function List([string]$Path) {
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($Path) {
        if (!$seen.Add($Path)) { throw 'Repeated Graph pagination cursor.' }
        $page = Graph GET $Path
        foreach ($item in $page.value) { $item }
        $Path = $page['@odata.nextLink']
    }
}
function SingleOrNone($Items, [string]$Label) {
    $all = @($Items)
    if ($all.Count -gt 1) { throw "Ambiguous $Label; multiple matches. Resolve manually; no arbitrary object will be reused." }
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}
function Get-AzdCommand {
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

    return $azdCandidates | Where-Object Version -ge ([version]'1.32.0') | Select-Object -First 1
}
function Invoke-Azd {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $output = & $Azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }

    return $output
}
function Get-RequiredPoolValue {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($Value -is [guid]) {
        if ($Value -eq [guid]::Empty) {
            throw "Configure $Name before creating a new Cloud PC pool."
        }

        return $Value.ToString()
    }

    if ($Value -is [Array]) {
        if ($Value.Count -eq 0) {
            throw "Configure $Name before creating a new Cloud PC pool."
        }

        return $Value
    }

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Configure $Name before creating a new Cloud PC pool."
    }

    return $Value
}
function Resolve-OwnershipManifestTarget {
    param(
        $Azd,
        [string]$OverridePath
    )

    if (![string]::IsNullOrWhiteSpace($OverridePath)) {
        return [pscustomobject]@{
            EnvironmentName = ''
            Path = $OverridePath
        }
    }

    if ($null -eq $Azd) {
        return $null
    }

    try {
        $environmentName = Invoke-Azd -Azd $Azd -Arguments @('env', 'get-value', 'AZURE_ENV_NAME') -CaptureOutput
        if ([string]::IsNullOrWhiteSpace($environmentName)) {
            throw 'No azd environment is currently selected.'
        }

        return [pscustomobject]@{
            EnvironmentName = $environmentName
            Path = Get-W365OwnershipManifestPath -RepositoryRoot $script:repositoryRoot -EnvironmentName $environmentName
        }
    }
    catch {
        Write-Warning "Unable to resolve the azd ownership manifest location automatically. $($_.Exception.Message)"
        return $null
    }
}
function Merge-OwnershipEntry {
    param(
        [System.Collections.IDictionary]$ExistingEntry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentEntry,
        [string[]]$IdentityKeys,
        [string[]]$PreserveKeys,
        [Parameter(Mandatory)][string]$Label
    )

    if ($null -eq $ExistingEntry) {
        return Copy-W365ManifestValue -Value $CurrentEntry
    }

    foreach ($key in @($IdentityKeys | Where-Object { $_ })) {
        $existingValue = [string]$ExistingEntry[$key]
        $currentValue = [string]$CurrentEntry[$key]
        if (![string]::IsNullOrWhiteSpace($existingValue) -and
            ![string]::IsNullOrWhiteSpace($currentValue) -and
            $existingValue -ne $currentValue) {
            throw "Ownership manifest mismatch for $Label. Existing $key '$existingValue' does not match current '$currentValue'."
        }
    }

    $merged = Copy-W365ManifestValue -Value $ExistingEntry
    foreach ($key in $CurrentEntry.Keys) {
        if ($key -in @($PreserveKeys) -and $ExistingEntry.Contains($key)) {
            continue
        }

        $value = $CurrentEntry[$key]
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value) -and $merged.Contains($key)) {
            continue
        }

        if ($null -eq $value -and $merged.Contains($key)) {
            continue
        }

        $merged[$key] = Copy-W365ManifestValue -Value $value
    }

    if ([string]$ExistingEntry['disposition'] -eq 'created' -or [string]$CurrentEntry['disposition'] -eq 'created') {
        $merged['disposition'] = 'created'
    }

    return $merged
}
function Merge-OwnershipMapEntry {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Container,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [string[]]$IdentityKeys,
        [string[]]$PreserveKeys,
        [Parameter(Mandatory)][string]$Label
    )

    if (!$Container.Contains($Key) -or $null -eq $Container[$Key]) {
        $Container[$Key] = Copy-W365ManifestValue -Value $Entry
        return
    }

    $Container[$Key] = Merge-OwnershipEntry -ExistingEntry $Container[$Key] -CurrentEntry $Entry -IdentityKeys $IdentityKeys -PreserveKeys $PreserveKeys -Label $Label
}
function New-OwnershipManifest {
    param(
        [System.Collections.IDictionary]$ExistingManifest,
        [string]$EnvironmentName
    )

    $manifest = if ($null -eq $ExistingManifest) {
        [ordered]@{}
    }
    else {
        Copy-W365ManifestValue -Value $ExistingManifest
    }

    $manifest['schemaVersion'] = 1
    if (![string]::IsNullOrWhiteSpace($EnvironmentName)) {
        $manifest['environmentName'] = $EnvironmentName
    }
    elseif (!$manifest.Contains('environmentName')) {
        $manifest['environmentName'] = ''
    }

    $manifest['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')

    foreach ($sectionName in @('foundry', 'w365', 'graph')) {
        if (!$manifest.Contains($sectionName) -or !($manifest[$sectionName] -is [System.Collections.IDictionary])) {
            $manifest[$sectionName] = [ordered]@{}
        }
    }

    foreach ($mapName in @('permissionGrants', 'inheritablePermissions', 'federatedIdentityCredentials')) {
        if (!$manifest.graph.Contains($mapName) -or !($manifest.graph[$mapName] -is [System.Collections.IDictionary])) {
            $manifest.graph[$mapName] = [ordered]@{}
        }
    }
    if (!$manifest.Contains('operations') -or !($manifest.operations -is [System.Collections.IDictionary])) {
        $manifest['operations'] = [ordered]@{}
    }

    return $manifest
}
function Save-OwnershipManifest {
    $script:ownershipManifest['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
    Write-W365OwnershipManifest -Path $script:ownershipManifestTarget.Path -Manifest $script:ownershipManifest
}
function Start-OwnershipOperation {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Intent
    )

    if ($script:ownershipManifest.operations.Contains($Key)) {
        $existingOperation = $script:ownershipManifest.operations[$Key]
        foreach ($intentKey in $Intent.Keys) {
            $existingValue = ConvertTo-Json (Copy-W365ManifestValue -Value $existingOperation[$intentKey]) -Depth 80 -Compress
            $requestedValue = ConvertTo-Json (Copy-W365ManifestValue -Value $Intent[$intentKey]) -Depth 80 -Compress
            if ($existingValue -ne $requestedValue) {
                throw "Pending ownership operation '$Key' does not match the requested mutation. Resolve it manually."
            }
        }
        return $existingOperation
    }

    $operation = Copy-W365ManifestValue -Value $Intent
    $operation['status'] = 'pending'
    $operation['startedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
    $script:ownershipManifest.operations[$Key] = $operation
    Save-OwnershipManifest
    return $operation
}
function Complete-OwnershipOperation {
    param([Parameter(Mandatory)][string]$Key)

    $script:ownershipManifest.operations.Remove($Key)
    Save-OwnershipManifest
}
function Get-OptionalObjectValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}
function New-PoolCreateRequest {
    $regions = @(
        Get-RequiredPoolValue -Name 'PoolRegions' -Value $PoolRegions | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }
    )
    if ($regions.Count -eq 0) {
        throw 'Configure PoolRegions before creating a new Cloud PC pool.'
    }

    return @{
        '@odata.type' = '#microsoft.graph.cloudPcAgentPool'
        displayName = [string](Get-RequiredPoolValue -Name 'PoolDisplayName' -Value $PoolDisplayName)
        description = [string]$PoolDescription
        cloudPcConfiguration = @{
            imageId = [string](Get-RequiredPoolValue -Name 'PoolImageId' -Value $PoolImageId)
            imageType = $PoolImageType
            osLocale = [string](Get-RequiredPoolValue -Name 'PoolOsLocale' -Value $PoolOsLocale)
        }
        networkConfiguration = @{
            '@odata.type' = '#microsoft.graph.cloudPcMicrosoftHostedNetworkConfiguration'
            geographicLocationType = [string](Get-RequiredPoolValue -Name 'PoolGeographicLocationType' -Value $PoolGeographicLocationType)
            regionGroups = @(@{
                regionGroup = [string](Get-RequiredPoolValue -Name 'PoolRegionGroup' -Value $PoolRegionGroup)
                regions = $regions
            })
        }
        billingConfiguration = @{
            billingType = $PoolBillingType
            billingPlanId = [string](Get-RequiredPoolValue -Name 'PoolBillingPlanId' -Value $PoolBillingPlanId)
        }
        scalingPolicy = @{
            minimumCount = $PoolMinimumCount
            maximumCount = $PoolMaximumCount
        }
        capabilities = @{
            '@odata.type' = '#microsoft.graph.cloudPcAgentPoolCapabilityConfiguration'
            enableSingleSignOn = $PoolEnableSingleSignOn.IsPresent
        }
    }
}
function Get-ArrayValueOrEmpty {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value | Where-Object { $null -ne $_ -and ![string]::IsNullOrWhiteSpace([string]$_) })
}
function Compare-StringArrays {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    return (@($Left) -join '|') -eq (@($Right) -join '|')
}
function New-PoolUpdateRequest {
    param([hashtable]$ExistingPool)

    $patch = @{ '@odata.type' = '#microsoft.graph.cloudPcAgentPool' }
    $network = $ExistingPool.networkConfiguration
    if (![string]::IsNullOrWhiteSpace($PoolGeographicLocationType) -and
        $PoolGeographicLocationType -ne [string]$network.geographicLocationType) {
        throw 'PoolGeographicLocationType cannot be changed for an existing Cloud PC pool. Create a new pool instead.'
    }

    $requestedRegions = @(Get-ArrayValueOrEmpty $PoolRegions)
    if (![string]::IsNullOrWhiteSpace($PoolRegionGroup) -or $requestedRegions.Count -gt 0) {
        $existingRegionGroup = if (@($network.regionGroups).Count -gt 0) { $network.regionGroups[0] } else { $null }
        if ($null -eq $existingRegionGroup) {
            throw 'The existing pool does not expose a region group. Review it manually before rerunning.'
        }

        if (![string]::IsNullOrWhiteSpace($PoolRegionGroup) -and $PoolRegionGroup -ne [string]$existingRegionGroup.regionGroup) {
            throw 'PoolRegionGroup cannot be changed for an existing Cloud PC pool. Create a new pool instead.'
        }

        if ($requestedRegions.Count -gt 0 -and !(Compare-StringArrays -Left $requestedRegions -Right @(Get-ArrayValueOrEmpty $existingRegionGroup.regions))) {
            throw 'PoolRegions cannot be changed for an existing Cloud PC pool. Create a new pool instead.'
        }
    }

    if (![string]::IsNullOrWhiteSpace($PoolDisplayName) -and $PoolDisplayName -ne [string]$ExistingPool.displayName) {
        $patch.displayName = $PoolDisplayName
    }
    if ($PSBoundParameters.ContainsKey('PoolDescription') -and $PoolDescription -ne [string]$ExistingPool.description) {
        $patch.description = $PoolDescription
    }

    $billingPatch = @{}
    if ($PoolBillingPlanId -ne [guid]::Empty -and $PoolBillingPlanId.ToString() -ne [string]$ExistingPool.billingConfiguration.billingPlanId) {
        $billingPatch.billingPlanId = $PoolBillingPlanId.ToString()
    }
    if ($PoolBillingType -ne [string]$ExistingPool.billingConfiguration.billingType) {
        $billingPatch.billingType = $PoolBillingType
    }
    if ($billingPatch.Count -gt 0) {
        $patch.billingConfiguration = $billingPatch
    }

    $cloudPcPatch = @{}
    if (![string]::IsNullOrWhiteSpace($PoolImageId) -and $PoolImageId -ne [string]$ExistingPool.cloudPcConfiguration.imageId) {
        $cloudPcPatch.imageId = $PoolImageId
    }
    if ($PSBoundParameters.ContainsKey('PoolImageType') -and $PoolImageType -ne [string]$ExistingPool.cloudPcConfiguration.imageType) {
        $cloudPcPatch.imageType = $PoolImageType
    }
    if (![string]::IsNullOrWhiteSpace($PoolOsLocale) -and $PoolOsLocale -ne [string]$ExistingPool.cloudPcConfiguration.osLocale) {
        $cloudPcPatch.osLocale = $PoolOsLocale
    }
    if ($cloudPcPatch.Count -gt 0) {
        $patch.cloudPcConfiguration = $cloudPcPatch
    }

    $currentMin = [int]$ExistingPool.scalingPolicy.minimumCount
    $currentMax = [int]$ExistingPool.scalingPolicy.maximumCount
    if ($PoolMinimumCount -ne $currentMin -or $PoolMaximumCount -ne $currentMax) {
        $patch.scalingPolicy = @{
            minimumCount = $PoolMinimumCount
            maximumCount = $PoolMaximumCount
        }
    }

    $existingSso = [bool]$ExistingPool.capabilities.enableSingleSignOn
    if ($PoolEnableSingleSignOn.IsPresent -ne $existingSso) {
        $patch.capabilities = @{
            '@odata.type' = '#microsoft.graph.cloudPcAgentPoolCapabilityConfiguration'
            enableSingleSignOn = $PoolEnableSingleSignOn.IsPresent
        }
    }

    return $patch
}
function Resolve-OrCreatePool {
    param(
        [System.Collections.IDictionary]$OwnershipManifest,
        [string]$PersistedPoolId
    )

    $pendingPoolCreate = if ($OwnershipManifest -and $OwnershipManifest.operations.Contains('w365.pool.create')) {
        $OwnershipManifest.operations['w365.pool.create']
    }
    else {
        $null
    }
    $ownershipForPoolResolution = if ($OwnershipManifest.w365.Contains('pool')) {
        $OwnershipManifest
    }
    else {
        $null
    }
    $resolvedPoolId = Resolve-W365OwnedPoolId `
        -ExplicitPoolId $PoolId `
        -PoolReference $PoolIdOrUrl `
        -OwnershipManifest $ownershipForPoolResolution `
        -PersistedPoolId $persistedPoolId
    if ($resolvedPoolId -eq [guid]::Empty -and $pendingPoolCreate) {
        $pendingDisplayName = [string]$pendingPoolCreate.displayName
        if ($pendingDisplayName -ne [string]$PoolDisplayName) {
            throw 'Pending pool creation does not match the requested pool name. Resolve the ownership manifest manually.'
        }
        $matchingPools = @(List 'beta/deviceManagement/virtualEndpoint/cloudPcPools' |
            Where-Object { [string]$_.displayName -eq $pendingDisplayName })
        $reconciledPool = SingleOrNone $matchingPools "pending Cloud PC pool creation '$pendingDisplayName'"
        if ($reconciledPool) {
            $resolvedPoolId = [guid]$reconciledPool.id
        }
        else {
            throw "The outcome of pending Cloud PC pool creation '$pendingDisplayName' is still unknown. No create request was replayed."
        }
    }
    if ($resolvedPoolId -ne [guid]::Empty) {
        $existingPool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$resolvedPoolId"
        if ($existingPool['@odata.type'] -ne '#microsoft.graph.cloudPcAgentPool') {
            throw 'PoolId is not an agent pool.'
        }

        $patch = New-PoolUpdateRequest -ExistingPool $existingPool
        $pendingPoolUpdate = $OwnershipManifest.operations['w365.pool.update']
        if ($patch.Count -gt 1) {
            $poolUpdateOperationKey = 'w365.pool.update'
            $poolBeforeUpdate = if ($pendingPoolUpdate) {
                Copy-W365ManifestValue -Value $pendingPoolUpdate.previous
            }
            else {
                Copy-W365ManifestValue -Value $existingPool
            }
            Start-OwnershipOperation -Key $poolUpdateOperationKey -Intent ([ordered]@{
                kind = 'update'
                id = [string]$resolvedPoolId
                previous = $poolBeforeUpdate
                desiredPatch = Copy-W365ManifestValue -Value $patch
            }) | Out-Null
            Graph PATCH "beta/deviceManagement/virtualEndpoint/cloudPcPools/$resolvedPoolId" $patch | Out-Null
            $existingPool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$resolvedPoolId"
            $script:ownershipManifest.w365['pool'] = Merge-OwnershipEntry `
                -ExistingEntry $script:ownershipManifest.w365['pool'] `
                -CurrentEntry ([ordered]@{
                    id = [string]$existingPool.id
                    displayName = [string]$existingPool.displayName
                    description = [string]$existingPool.description
                    disposition = 'reused'
                    previous = $poolBeforeUpdate
                }) `
                -IdentityKeys @('id') `
                -PreserveKeys @('previous') `
                -Label 'W365 pool'
            Complete-OwnershipOperation -Key $poolUpdateOperationKey
        }
        elseif ($pendingPoolUpdate) {
            if ([string]$pendingPoolUpdate.id -ne [string]$resolvedPoolId) {
                throw 'Pending pool update does not match the resolved pool. Resolve the ownership manifest manually.'
            }
            $script:ownershipManifest.w365['pool'] = Merge-OwnershipEntry `
                -ExistingEntry $script:ownershipManifest.w365['pool'] `
                -CurrentEntry ([ordered]@{
                    id = [string]$existingPool.id
                    displayName = [string]$existingPool.displayName
                    description = [string]$existingPool.description
                    disposition = 'reused'
                    previous = Copy-W365ManifestValue -Value $pendingPoolUpdate.previous
                }) `
                -IdentityKeys @('id') `
                -PreserveKeys @('previous') `
                -Label 'W365 pool'
            Complete-OwnershipOperation -Key 'w365.pool.update'
        }

        return [pscustomobject]@{
            Id = [guid]$existingPool.id
            Pool = $existingPool
            Created = $null -ne $pendingPoolCreate
        }
    }

    $createRequest = New-PoolCreateRequest
    $sameNamePool = SingleOrNone @(
        List 'beta/deviceManagement/virtualEndpoint/cloudPcPools' |
            Where-Object { [string]$_.displayName -eq [string]$createRequest.displayName }
    ) "Cloud PC pool named '$([string]$createRequest.displayName)'"
    if ($sameNamePool) {
        throw "A Cloud PC pool named '$([string]$createRequest.displayName)' already exists without ownership evidence. Supply its explicit pool ID only if it is intended for reuse."
    }
    Start-OwnershipOperation -Key 'w365.pool.create' -Intent ([ordered]@{
        kind = 'create'
        displayName = [string]$createRequest.displayName
        request = Copy-W365ManifestValue -Value $createRequest
    }) | Out-Null
    $createdPool = Graph POST 'beta/deviceManagement/virtualEndpoint/cloudPcPools' $createRequest
    return [pscustomobject]@{
        Id = [guid]$createdPool.id
        Pool = $createdPool
        Created = $true
    }
}
function Resource([string]$AppId) {
    $sp = SingleOrNone (List "v1.0/servicePrincipals?`$filter=appId eq '$AppId'") "resource $AppId"
    if ($null -eq $sp) { throw "Resource $AppId is absent. Complete Agent 365/W365 tenant onboarding first." }
    return $sp
}

# Validate the complete supplied identity chain before any mutation.
$agent = Graph GET "v1.0/servicePrincipals/$AgentIdentityId`?`$select=id,appId,displayName,agentIdentityBlueprintId"
if ($agent['@odata.type'] -ne '#microsoft.graph.agentIdentity' -or $agent.agentIdentityBlueprintId -ne $BlueprintId.ToString()) {
    throw 'Existing agent is not an agent identity or belongs to a different blueprint.'
}
$parsedClientId = [guid]::Empty
if ($agent.id -ne $AgentIdentityId.ToString() -or ![guid]::TryParse($agent.appId, [ref]$parsedClientId) -or $parsedClientId -eq [guid]::Empty) {
    throw 'Graph returned invalid agent identifiers.'
}
$blueprint = SingleOrNone (List "v1.0/applications/microsoft.graph.agentIdentityBlueprint?`$filter=appId eq '$BlueprintId'") 'Foundry blueprint app ID'
if (!$blueprint) { throw 'Existing Foundry blueprint is unavailable. Complete phase 1; setup will not create a replacement.' }
$bpPath = "v1.0/applications/$($blueprint.id)"
$blueprint = Graph GET "$bpPath`?`$select=id,appId,requiredResourceAccess"
if ($blueprint.appId -ne $BlueprintId.ToString()) { throw 'Resolved blueprint does not match the supplied client ID.' }
$principal = SingleOrNone (List "v1.0/servicePrincipals?`$filter=appId eq '$BlueprintId'") 'Foundry blueprint principal'
if (!$principal -or $principal['@odata.type'] -ne '#microsoft.graph.agentIdentityBlueprintPrincipal') {
    throw 'Foundry blueprint principal is missing or has the wrong type. Setup will not create a replacement.'
}
$federations = @()
$ficPath = "$bpPath/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials"
$existingFics = if ($AuthorizeHostedRuntimeFederation -or $AuthorizeViewerFederation) {
    @(List $ficPath)
} else {
    @()
}
if ($AuthorizeHostedRuntimeFederation) {
    $ficName = "w365-hosted-$HostedRuntimeIdentityObjectId"
    $federation = @{
        name = $ficName; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
        subject = $HostedRuntimeIdentityObjectId.ToString(); audiences = @('api://AzureADTokenExchange')
    }
    $existingFic = SingleOrNone @($existingFics | Where-Object {
        $_.name -eq $ficName -or $_.subject -eq $federation.subject
    }) 'hosted runtime federation'
    if ($existingFic) {
        if ($existingFic.issuer -ne $federation.issuer -or $existingFic.subject -ne $federation.subject -or
            @($existingFic.audiences).Count -ne 1 -or $existingFic.audiences[0] -ne 'api://AzureADTokenExchange') {
            throw 'Existing hosted runtime federation differs. Review manually; no trust will be overwritten.'
        }
    } else {
        $federations += $federation
    }
}
if ($AuthorizeViewerFederation) {
    $viewer = Graph GET "v1.0/servicePrincipals/$ViewerManagedIdentityObjectId"
    if ($viewer.servicePrincipalType -ne 'ManagedIdentity') { throw 'Viewer principal is not a managed identity in this tenant.' }
    $ficName = "w365-viewer-$ViewerManagedIdentityObjectId"
    $federation = @{
        name = $ficName; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
        subject = $ViewerManagedIdentityObjectId.ToString(); audiences = @('api://AzureADTokenExchange')
    }
    $existingFic = SingleOrNone @($existingFics | Where-Object {
        $_.name -eq $ficName -or $_.subject -eq $federation.subject
    }) 'viewer federation'
    if ($existingFic) {
        if ($existingFic.issuer -ne $federation.issuer -or $existingFic.subject -ne $federation.subject -or
            @($existingFic.audiences).Count -ne 1 -or $existingFic.audiences[0] -ne 'api://AzureADTokenExchange') {
            throw 'Existing viewer federation differs. Review manually; no trust will be overwritten.'
        }
        $federation = $null
    }
    if ($federation) {
        $federations += $federation
    }
}

# Resolve service metadata before making directory changes.
$resources = @(
    @{ Sp = (Resource 'da81128c-e5b5-4f9e-8d89-50d906f107c5'); Scopes = @('Tools.ListInvoke.All') },
    @{ Sp = (Resource 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'); Scopes = @('McpServersMetadata.Read.All') },
    @{ Sp = (Resource '90ecec28-f5a6-42b3-9bde-dae1ca98f8b5'); Scopes = @(
        'Computer.See',
        'Computer.Control',
        'Computer.Do',
        'Computer.Get'
    ) }
)
$azd = if ($SkipAzdEnvironmentSync) { $null } else { Get-AzdCommand }
$manifestTarget = Resolve-OwnershipManifestTarget -Azd $azd -OverridePath $OwnershipManifestPath
$existingManifest = if ($manifestTarget) {
    Read-W365OwnershipManifest -Path $manifestTarget.Path -AllowMissing
}
else {
    $null
}
if ($null -eq $manifestTarget) {
    throw 'An ownership manifest path is required before W365 or Microsoft Graph resources can be changed.'
}
$script:ownershipManifestTarget = $manifestTarget
$script:ownershipManifest = New-OwnershipManifest `
    -ExistingManifest $existingManifest `
    -EnvironmentName $manifestTarget.EnvironmentName
$script:ownershipManifest.graph['blueprint'] = Merge-OwnershipEntry `
    -ExistingEntry $script:ownershipManifest.graph['blueprint'] `
    -CurrentEntry ([ordered]@{
        appId = [string]$blueprint.appId
        objectId = [string]$blueprint.id
        principalId = [string]$principal.id
    }) `
    -IdentityKeys @('appId', 'objectId', 'principalId') `
    -Label 'Foundry blueprint'
$script:ownershipManifest.graph['agent'] = Merge-OwnershipEntry `
    -ExistingEntry $script:ownershipManifest.graph['agent'] `
    -CurrentEntry ([ordered]@{
        appId = [string]$agent.appId
        objectId = [string]$agent.id
    }) `
    -IdentityKeys @('appId', 'objectId') `
    -Label 'Foundry agent identity'
$existingManifest = $script:ownershipManifest
$environmentValues = [ordered]@{}
if ($manifestTarget -and ![string]::IsNullOrWhiteSpace($manifestTarget.EnvironmentName)) {
    $environmentFilePath = Join-Path `
        (Join-Path $repositoryRoot ".azure\$($manifestTarget.EnvironmentName)") `
        '.env'
    if (Test-Path -LiteralPath $environmentFilePath) {
        $environmentValues = Read-AzdEnvironmentFile -Path $environmentFilePath
    }
}
$domains = @(List 'v1.0/domains?$select=id,isDefault,isVerified')
$AgentUserPrincipalName = Resolve-W365OwnedAgentUserPrincipalName `
    -ExplicitPrincipalName $AgentUserPrincipalName `
    -ExplicitDomain $AgentUserDomain `
    -PersistedPrincipalName ([string]$environmentValues['W365_AGENT_USER_PRINCIPAL_NAME']) `
    -OwnershipManifest $existingManifest `
    -Domains $domains `
    -ResourcePrefix ([string]$environmentValues['RESOURCE_PREFIX']) `
    -EnvironmentName $(if ($manifestTarget) { $manifestTarget.EnvironmentName } else { '' })
$agentUser = SingleOrNone (List "beta/users/microsoft.graph.agentUser?`$filter=userPrincipalName eq '$AgentUserPrincipalName'") 'agent user'
if ($agentUser -and $agentUser.identityParentId -ne $agent.id) { throw 'Existing agent user belongs to a different agent identity. Use a new UPN; never reparent implicitly.' }
if ($null -eq $existingManifest -and
    $PoolId -eq [guid]::Empty -and
    [string]::IsNullOrWhiteSpace($PoolIdOrUrl) -and
    [string]::IsNullOrWhiteSpace($PoolDisplayName)) {
    if ($null -eq $azd -or $null -eq $manifestTarget -or [string]::IsNullOrWhiteSpace($manifestTarget.EnvironmentName)) {
        throw 'PoolDisplayName is required when a new pool is created outside a selected azd environment.'
    }

    $resourcePrefix = [string]$environmentValues['RESOURCE_PREFIX']
    if ([string]::IsNullOrWhiteSpace($resourcePrefix)) {
        throw 'RESOURCE_PREFIX is required to derive the environment-owned W365 pool name.'
    }
    $PoolDisplayName = Get-W365PoolDisplayName `
        -ResourcePrefix $resourcePrefix `
        -EnvironmentName $manifestTarget.EnvironmentName
}
$poolState = Resolve-OrCreatePool `
    -OwnershipManifest $existingManifest `
    -PersistedPoolId ([string]$environmentValues['W365_POOL_ID'])
$pool = $poolState.Pool
$PoolId = $poolState.Id
if ($poolState.Created -and $manifestTarget) {
    $script:ownershipManifest.w365['pool'] = Merge-OwnershipEntry `
        -ExistingEntry $script:ownershipManifest.w365['pool'] `
        -CurrentEntry ([ordered]@{
        id = $PoolId.ToString()
        displayName = [string]$pool.displayName
        description = [string]$pool.description
        disposition = 'created'
    }) -IdentityKeys @('id') -Label 'W365 pool'
    Complete-OwnershipOperation -Key 'w365.pool.create'
    $existingManifest = $script:ownershipManifest
}
$inheritPath = "v1.0/applications/microsoft.graph.agentIdentityBlueprint/$($blueprint.appId)/inheritablePermissions"
$inheritances = @(List $inheritPath)
$grants = @(List "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($principal.id)'")
$pendingBlueprintOperation = $script:ownershipManifest.operations['graph.blueprint.requiredResourceAccess']
$requiredResourceAccessBefore = if ($pendingBlueprintOperation) {
    Copy-W365ManifestValue -Value @($pendingBlueprintOperation.previous)
}
else {
    Copy-W365ManifestValue -Value @($blueprint.requiredResourceAccess | Where-Object { $null -ne $_ })
}
foreach ($resource in $resources) {
    foreach ($scope in $resource.Scopes) {
        $match = @($resource.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })
        if ($match.Count -ne 1) { throw "Resource $($resource.Sp.appId) does not publish enabled scope $scope." }
    }
    $resource.ExistingInheritance = SingleOrNone @($inheritances | Where-Object { $_.resourceAppId -eq $resource.Sp.appId }) 'inheritance entry'
    if ($resource.ExistingInheritance -and ($resource.ExistingInheritance.inheritableScopes.kind -ne 'allAllowed' -or
        $resource.ExistingInheritance.inheritableRoles.kind -ne 'none')) {
        throw "Existing inheritance for $($resource.Sp.appId) differs. Review it manually before rerunning."
    }
    $resource.Grant = SingleOrNone @($grants | Where-Object { $_.resourceId -eq $resource.Sp.id -and $_.consentType -eq 'AllPrincipals' }) 'OAuth grant'
}
Write-Output "Blueprint app ID: $($blueprint.appId)"
$required = @($blueprint.requiredResourceAccess | Where-Object { $null -ne $_ })
$grantManifestEntries = [ordered]@{}
$inheritanceManifestEntries = [ordered]@{}
foreach ($resource in $resources) {
    $entry = SingleOrNone @($required | Where-Object { $_.resourceAppId -eq $resource.Sp.appId }) 'resource declaration'
    if ($null -eq $entry) { $entry = @{ resourceAppId = $resource.Sp.appId; resourceAccess = @() }; $required += $entry }
    foreach ($scope in $resource.Scopes) {
        $permission = @($resource.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope -and $_.isEnabled })[0]
        if ($permission.id -notin @($entry.resourceAccess | ForEach-Object { $_.id })) {
            $entry.resourceAccess += @{ id = $permission.id; type = 'Scope' }
        }
    }
}
$requiredResourceAccessAdded = @()
foreach ($entry in $required) {
    $beforeEntries = @($requiredResourceAccessBefore | Where-Object { $_.resourceAppId -eq $entry.resourceAppId })
    if ($beforeEntries.Count -gt 1) {
        throw "Blueprint contains duplicate requiredResourceAccess entries for $($entry.resourceAppId)."
    }
    $beforeIds = if ($beforeEntries.Count -eq 1) {
        @($beforeEntries[0].resourceAccess | ForEach-Object { [string]$_.id })
    }
    else {
        @()
    }
    $addedAccess = @($entry.resourceAccess | Where-Object { [string]$_.id -notin $beforeIds })
    if ($addedAccess.Count -gt 0) {
        $requiredResourceAccessAdded += [ordered]@{
            resourceAppId = [string]$entry.resourceAppId
            resourceAccess = Copy-W365ManifestValue -Value $addedAccess
        }
    }
}
Start-OwnershipOperation -Key 'graph.blueprint.requiredResourceAccess' -Intent ([ordered]@{
    kind = 'update'
    objectId = [string]$blueprint.id
    previous = Copy-W365ManifestValue -Value $requiredResourceAccessBefore
    added = Copy-W365ManifestValue -Value $requiredResourceAccessAdded
    desired = Copy-W365ManifestValue -Value $required
}) | Out-Null
Graph PATCH $bpPath @{ requiredResourceAccess = $required } | Out-Null
$script:ownershipManifest.graph['blueprint'] = Merge-OwnershipEntry `
    -ExistingEntry $script:ownershipManifest.graph['blueprint'] `
    -CurrentEntry ([ordered]@{
        appId = [string]$blueprint.appId
        objectId = [string]$blueprint.id
        principalId = [string]$principal.id
        requiredResourceAccessBefore = $requiredResourceAccessBefore
        requiredResourceAccessAdded = $requiredResourceAccessAdded
    }) `
    -IdentityKeys @('appId', 'objectId', 'principalId') `
    -PreserveKeys @('requiredResourceAccessBefore', 'requiredResourceAccessAdded') `
    -Label 'Foundry blueprint'
Complete-OwnershipOperation -Key 'graph.blueprint.requiredResourceAccess'
foreach ($resource in $resources) {
    $grant = $resource.Grant
    $operationKey = "graph.permissionGrant.$($resource.Sp.appId)"
    $pendingGrant = $script:ownershipManifest.operations[$operationKey]
    $grantExisted = if ($pendingGrant) { [bool]$pendingGrant.existedBefore } else { $null -ne $grant }
    $previousScope = if ($pendingGrant) {
        [string]$pendingGrant.previousScope
    }
    elseif ($grantExisted) {
        [string]$grant.scope
    }
    else {
        ''
    }
    $scope = @(@($(if ($grant) { $grant.scope -split ' ' })) + $resource.Scopes | Where-Object { $_ } | Sort-Object -Unique) -join ' '
    Start-OwnershipOperation -Key $operationKey -Intent ([ordered]@{
        kind = if ($grantExisted) { 'update' } else { 'create' }
        resourceAppId = [string]$resource.Sp.appId
        resourceId = [string]$resource.Sp.id
        existedBefore = $grantExisted
        previousScope = $previousScope
        desiredScope = $scope
    }) | Out-Null
    if ($grant) {
        Graph PATCH "v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $scope } | Out-Null
    }
    else {
        $grant = Graph POST 'v1.0/oauth2PermissionGrants' @{
            clientId = $principal.id; resourceId = $resource.Sp.id; consentType = 'AllPrincipals'; scope = $scope
        }
    }
    $grantManifestEntries[$resource.Sp.appId] = [ordered]@{
        resourceAppId = $resource.Sp.appId
        resourceId = $resource.Sp.id
        grantId = [string]$grant.id
        disposition = if ($grantExisted) { 'reused' } else { 'created' }
        previousScope = $previousScope
        scope = $scope
    }
    Merge-OwnershipMapEntry -Container $script:ownershipManifest.graph.permissionGrants `
        -Key $resource.Sp.appId `
        -Entry $grantManifestEntries[$resource.Sp.appId] `
        -IdentityKeys @('resourceAppId', 'resourceId') `
        -PreserveKeys @('previousScope') `
        -Label "permission grant $($resource.Sp.appId)"
    Complete-OwnershipOperation -Key $operationKey
    $inheritance = @{
        resourceAppId = $resource.Sp.appId
        inheritableScopes = @{ '@odata.type' = '#microsoft.graph.allAllowedScopes'; kind = 'allAllowed' }
        inheritableRoles = @{ '@odata.type' = '#microsoft.graph.noRoles'; kind = 'none' }
    }
    $inheritanceDisposition = 'reused'
    $currentInheritance = $resource.ExistingInheritance
    $inheritanceOperationKey = "graph.inheritance.$($resource.Sp.appId)"
    $pendingInheritance = $script:ownershipManifest.operations[$inheritanceOperationKey]
    if ($pendingInheritance -and $currentInheritance) {
        $inheritanceDisposition = 'created'
    }
    if (!$resource.ExistingInheritance) {
        Start-OwnershipOperation -Key $inheritanceOperationKey -Intent ([ordered]@{
            kind = 'create'
            resourceAppId = [string]$resource.Sp.appId
            previous = $null
            desired = Copy-W365ManifestValue -Value $inheritance
        }) | Out-Null
        $currentInheritance = Graph POST $inheritPath $inheritance
        $inheritanceDisposition = 'created'
    }
    $inheritanceManifestEntries[$resource.Sp.appId] = [ordered]@{
        resourceAppId = $resource.Sp.appId
        entryId = [string](Get-OptionalObjectValue -Object $currentInheritance -Name 'id')
        disposition = $inheritanceDisposition
        previous = Copy-W365ManifestValue -Value $resource.ExistingInheritance
        current = Copy-W365ManifestValue -Value $currentInheritance
    }
    Merge-OwnershipMapEntry -Container $script:ownershipManifest.graph.inheritablePermissions `
        -Key $resource.Sp.appId `
        -Entry $inheritanceManifestEntries[$resource.Sp.appId] `
        -IdentityKeys @('resourceAppId') `
        -PreserveKeys @('previous') `
        -Label "inheritance $($resource.Sp.appId)"
    if ($script:ownershipManifest.operations.Contains($inheritanceOperationKey)) {
        Complete-OwnershipOperation -Key $inheritanceOperationKey
    }
}
$federationManifestEntries = [ordered]@{}
foreach ($existingFic in @($existingFics)) {
    $ficName = [string]$existingFic.name
    if ([string]::IsNullOrWhiteSpace($ficName)) {
        continue
    }

    $existingFederationOperationKey = "graph.federation.$ficName"
    $pendingFederation = $script:ownershipManifest.operations[$existingFederationOperationKey]
    $federationManifestEntries[$ficName] = [ordered]@{
        id = [string](Get-OptionalObjectValue -Object $existingFic -Name 'id')
        name = $ficName
        subject = [string]$existingFic.subject
        issuer = [string]$existingFic.issuer
        audiences = @($existingFic.audiences)
        disposition = if ($pendingFederation) { 'created' } else { 'reused' }
    }
    Merge-OwnershipMapEntry -Container $script:ownershipManifest.graph.federatedIdentityCredentials `
        -Key $ficName `
        -Entry $federationManifestEntries[$ficName] `
        -IdentityKeys @('name', 'subject') `
        -Label "federation $ficName"
    if ($pendingFederation) {
        Complete-OwnershipOperation -Key $existingFederationOperationKey
    }
}
foreach ($federation in $federations) {
    $federationOperationKey = "graph.federation.$($federation.name)"
    Start-OwnershipOperation -Key $federationOperationKey -Intent ([ordered]@{
        kind = 'create'
        name = [string]$federation.name
        subject = [string]$federation.subject
        desired = Copy-W365ManifestValue -Value $federation
    }) | Out-Null
    $createdFederation = Graph POST $ficPath $federation
    $federationManifestEntries[$federation.name] = [ordered]@{
        id = [string](Get-OptionalObjectValue -Object $createdFederation -Name 'id')
        name = [string]$federation.name
        subject = [string]$federation.subject
        issuer = [string]$federation.issuer
        audiences = @($federation.audiences)
        disposition = 'created'
    }
    Merge-OwnershipMapEntry -Container $script:ownershipManifest.graph.federatedIdentityCredentials `
        -Key $federation.name `
        -Entry $federationManifestEntries[$federation.name] `
        -IdentityKeys @('name', 'subject') `
        -Label "federation $($federation.name)"
    Complete-OwnershipOperation -Key $federationOperationKey
}
Write-Output "Existing agent principal ID: $($agent.id)"
$agentUserOperationKey = 'w365.agentUser.create'
$pendingAgentUser = $script:ownershipManifest.operations[$agentUserOperationKey]
$createdAgentUser = $null -ne $pendingAgentUser
if (!$agentUser) {
    Start-OwnershipOperation -Key $agentUserOperationKey -Intent ([ordered]@{
        kind = 'create'
        userPrincipalName = $AgentUserPrincipalName
        parentAgentObjectId = [string]$agent.id
    }) | Out-Null
    $agentUser = Graph POST 'beta/users/microsoft.graph.agentUser' @{
        displayName = "$($agent.displayName) user"; userPrincipalName = $AgentUserPrincipalName
        mailNickname = $AgentUserPrincipalName.Split('@')[0]; accountEnabled = $true; identityParentId = $agent.id
    }
    $createdAgentUser = $true
}
$script:ownershipManifest.w365['agentUser'] = Merge-OwnershipEntry `
    -ExistingEntry $script:ownershipManifest.w365['agentUser'] `
    -CurrentEntry ([ordered]@{
        id = [string]$agentUser.id
        userPrincipalName = [string]$agentUser.userPrincipalName
        parentAgentObjectId = [string]$agent.id
        disposition = if ($createdAgentUser) { 'created' } else { 'reused' }
    }) `
    -IdentityKeys @('id', 'userPrincipalName', 'parentAgentObjectId') `
    -Label 'W365 agent user'
if ($script:ownershipManifest.operations.Contains($agentUserOperationKey)) {
    Complete-OwnershipOperation -Key $agentUserOperationKey
}
$assignmentPath = "beta/deviceManagement/virtualEndpoint/cloudPcPools/$PoolId/assignments"
$assigned = SingleOrNone @(List $assignmentPath | Where-Object { $_.userPrincipalId -eq $agentUser.id }) 'agent pool assignment'
$assignmentOperationKey = 'w365.pool.assignment.create'
$pendingAssignment = $script:ownershipManifest.operations[$assignmentOperationKey]
if ($pendingAssignment -and
    ([string]$pendingAssignment.poolId -ne $PoolId.ToString() -or
    [string]$pendingAssignment.userPrincipalId -ne [string]$agentUser.id)) {
    throw 'Pending pool assignment does not match the resolved pool and agent user. Resolve the ownership manifest manually.'
}
$createdAssignment = $null
if (!$assigned) {
    Start-OwnershipOperation -Key $assignmentOperationKey -Intent ([ordered]@{
        kind = 'create'
        poolId = $PoolId.ToString()
        userPrincipalId = [string]$agentUser.id
    }) | Out-Null
    $createdAssignment = Graph POST $assignmentPath @{
        '@odata.type' = '#microsoft.graph.cloudPcAgentPoolUserAssignment'; userPrincipalId = $agentUser.id
    }
}
$script:ownershipManifest.w365['assignment'] = Merge-OwnershipEntry `
    -ExistingEntry $script:ownershipManifest.w365['assignment'] `
    -CurrentEntry ([ordered]@{
        id = if ($assigned) { [string](Get-OptionalObjectValue -Object $assigned -Name 'id') } else { [string](Get-OptionalObjectValue -Object $createdAssignment -Name 'id') }
        poolId = $PoolId.ToString()
        userPrincipalId = [string]$agentUser.id
        disposition = if ($assigned -and !$pendingAssignment) { 'reused' } else { 'created' }
    }) `
    -IdentityKeys @('poolId', 'userPrincipalId') `
    -Label 'W365 pool assignment'
if ($script:ownershipManifest.operations.Contains($assignmentOperationKey)) {
    Complete-OwnershipOperation -Key $assignmentOperationKey
}
$phaseTwoValues = [ordered]@{
    W365_TENANT_ID = $TenantId.ToString()
    W365_BLUEPRINT_ID = $blueprint.appId
    W365_AGENT_ID = $agent.appId
    W365_AGENT_OBJECT_ID = $agent.id
    W365_AGENT_USER_ID = $agentUser.id
    W365_AGENT_USER_PRINCIPAL_NAME = $AgentUserPrincipalName
    W365_POOL_ID = $PoolId.ToString()
    W365_POOL_NAME = [string]$pool.displayName
    W365_ENABLED = 'true'
}

if ($manifestTarget) {
    $manifest = New-OwnershipManifest -ExistingManifest $existingManifest -EnvironmentName $manifestTarget.EnvironmentName
    $foundryOwnership = ''
    $projectEndpoint = ''
    $projectId = ''
    $foundryResourceGroupName = ''
    $foundryResourceGroupId = ''
    if ($azd) {
        foreach ($entry in @(
            @{ Name = 'FOUNDRY_PROJECT_OWNERSHIP'; Target = 'foundryOwnership' },
            @{ Name = 'FOUNDRY_PROJECT_ENDPOINT'; Target = 'projectEndpoint' },
            @{ Name = 'AZURE_AI_PROJECT_ID'; Target = 'projectId' },
            @{ Name = 'AZURE_FOUNDRY_RESOURCE_GROUP'; Target = 'foundryResourceGroupName' },
            @{ Name = 'AZD_FOUNDRY_RESOURCE_GROUP_ID'; Target = 'foundryResourceGroupId' }
        )) {
            try {
                Set-Variable -Name $entry.Target -Value (Invoke-Azd -Azd $azd -Arguments @('env', 'get-value', $entry.Name) -CaptureOutput) -Scope Local
            }
            catch {
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($foundryOwnership) -and ![string]::IsNullOrWhiteSpace($projectEndpoint)) {
        $foundryOwnership = 'existing'
    }

    $manifest.foundry = Merge-OwnershipEntry -ExistingEntry $manifest.foundry -CurrentEntry ([ordered]@{
        tenantId = $TenantId.ToString()
        projectOwnership = if ([string]::IsNullOrWhiteSpace($foundryOwnership)) { 'unknown' } else { $foundryOwnership }
        existingProjectBound = $foundryOwnership -eq 'existing'
        projectEndpoint = $projectEndpoint
        projectId = $projectId
        resourceGroupName = $foundryResourceGroupName
        resourceGroupId = $foundryResourceGroupId
    }) -IdentityKeys @('tenantId', 'projectEndpoint', 'projectId') -Label 'Foundry project binding'
    $manifest.w365['pool'] = Merge-OwnershipEntry -ExistingEntry $manifest.w365['pool'] -CurrentEntry ([ordered]@{
        id = $PoolId.ToString()
        displayName = [string]$pool.displayName
        description = [string]$pool.description
        disposition = if ($poolState.Created) { 'created' } else { 'reused' }
    }) -IdentityKeys @('id') -Label 'W365 pool'
    $manifest.w365['agentUser'] = Merge-OwnershipEntry -ExistingEntry $manifest.w365['agentUser'] -CurrentEntry ([ordered]@{
        id = [string]$agentUser.id
        userPrincipalName = [string]$agentUser.userPrincipalName
        parentAgentObjectId = [string]$agent.id
        disposition = if ($createdAgentUser) { 'created' } else { 'reused' }
    }) -IdentityKeys @('id', 'userPrincipalName', 'parentAgentObjectId') -Label 'W365 agent user'
    $manifest.w365['assignment'] = Merge-OwnershipEntry -ExistingEntry $manifest.w365['assignment'] -CurrentEntry ([ordered]@{
        id = if ($assigned) { [string](Get-OptionalObjectValue -Object $assigned -Name 'id') } else { [string](Get-OptionalObjectValue -Object $createdAssignment -Name 'id') }
        poolId = $PoolId.ToString()
        userPrincipalId = [string]$agentUser.id
        disposition = if ($assigned) { 'reused' } else { 'created' }
    }) -IdentityKeys @('poolId', 'userPrincipalId') -Label 'W365 pool assignment'
    $manifest.graph['blueprint'] = Merge-OwnershipEntry -ExistingEntry $manifest.graph['blueprint'] -CurrentEntry ([ordered]@{
        appId = [string]$blueprint.appId
        objectId = [string]$blueprint.id
        principalId = [string]$principal.id
        requiredResourceAccessBefore = $requiredResourceAccessBefore
        requiredResourceAccessAdded = $requiredResourceAccessAdded
    }) -IdentityKeys @('appId', 'objectId', 'principalId') -PreserveKeys @('requiredResourceAccessBefore', 'requiredResourceAccessAdded') -Label 'Foundry blueprint'
    $manifest.graph['agent'] = Merge-OwnershipEntry -ExistingEntry $manifest.graph['agent'] -CurrentEntry ([ordered]@{
        appId = [string]$agent.appId
        objectId = [string]$agent.id
    }) -IdentityKeys @('appId', 'objectId') -Label 'Foundry agent identity'

    foreach ($resourceAppId in $grantManifestEntries.Keys) {
        Merge-OwnershipMapEntry -Container $manifest.graph.permissionGrants -Key $resourceAppId -Entry $grantManifestEntries[$resourceAppId] -IdentityKeys @('resourceAppId', 'resourceId') -PreserveKeys @('previousScope') -Label "permission grant $resourceAppId"
    }
    foreach ($resourceAppId in $inheritanceManifestEntries.Keys) {
        Merge-OwnershipMapEntry -Container $manifest.graph.inheritablePermissions -Key $resourceAppId -Entry $inheritanceManifestEntries[$resourceAppId] -IdentityKeys @('resourceAppId') -PreserveKeys @('previous') -Label "inheritance $resourceAppId"
    }
    foreach ($federationName in $federationManifestEntries.Keys) {
        Merge-OwnershipMapEntry -Container $manifest.graph.federatedIdentityCredentials -Key $federationName -Entry $federationManifestEntries[$federationName] -IdentityKeys @('name', 'subject') -Label "federation $federationName"
    }

    Write-W365OwnershipManifest -Path $manifestTarget.Path -Manifest $manifest
    Write-Output "W365_OWNERSHIP_MANIFEST=$($manifestTarget.Path)"
}
elseif (!$SkipAzdEnvironmentSync) {
    Write-Warning 'Ownership manifest was not written because no azd environment or manifest path was available.'
}

if ($azd) {
    try {
        $environmentName = Invoke-Azd -Azd $azd -Arguments @('env', 'get-value', 'AZURE_ENV_NAME') -CaptureOutput
        if ([string]::IsNullOrWhiteSpace($environmentName)) {
            throw 'No azd environment is currently selected.'
        }

        foreach ($entry in $phaseTwoValues.GetEnumerator()) {
            Invoke-Azd -Azd $azd -Arguments @('env', 'set', $entry.Key, $entry.Value) | Out-Null
        }

        Write-Output "`nPersisted phase-2 azd environment values for '$environmentName':"
    }
    catch {
        Write-Warning "Unable to persist azd environment values automatically. $($_.Exception.Message)"
        Write-Output "`nSet these non-secret phase-2 azd environment values manually:"
    }
}
elseif ($SkipAzdEnvironmentSync) {
    Write-Output "`nSet these non-secret phase-2 azd environment values manually:"
}
else {
    Write-Warning 'azd 1.32.0 or later was not found. Persist the phase-2 environment values manually.'
    Write-Output "`nSet these non-secret phase-2 azd environment values manually:"
}

foreach ($entry in $phaseTwoValues.GetEnumerator()) {
    Write-Output "$($entry.Key)=$($entry.Value)"
}
Write-Output 'Setup requests completed. Check pool readiness in Intune before running the sample.'
