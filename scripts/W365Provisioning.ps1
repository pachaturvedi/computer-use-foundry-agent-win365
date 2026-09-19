#Requires -Version 7.4

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DeploymentConfig.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
Write-SampleVerbose -Component 'W365Provisioning' -Message 'Loaded W365 provisioning helpers.'
Write-SampleDebug -Component 'W365Provisioning' -Message 'External commands are logged without access-token or secret values.'

function Write-W365ProvisioningStep {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0:HH:mm:ss}] {1}' -f [DateTimeOffset]::Now, $Message)
}

function Get-W365AzdCommand {
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
        if (![string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path) -and
            !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    $candidates = $azdPaths |
        ForEach-Object {
            $versionOutput = & $_ version 2>$null
            if ($LASTEXITCODE -eq 0 -and $versionOutput -match 'azd version\s+(\d+\.\d+\.\d+)') {
                [pscustomobject]@{ Path = $_; Version = [version]$Matches[1] }
            }
        } |
        Sort-Object Version -Descending

    return $candidates |
        Where-Object Version -ge ([version]'1.32.0') |
        Select-Object -First 1
}

function Invoke-W365Azd {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    Write-SampleVerbose -Component 'azd' -Message ($Arguments -join ' ')
    Write-SampleDebug -Component 'azd' -Message "CaptureOutput=$($CaptureOutput.IsPresent); argumentCount=$($Arguments.Count)."
    Write-Host ('[{0:HH:mm:ss}] [COMMAND] azd {1}' -f [DateTimeOffset]::Now, ($Arguments -join ' '))
    $output = & $Azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }

    return $output
}

function Get-W365AzdValue {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowMissing
    )

    try {
        return Invoke-W365Azd -Azd $Azd -Arguments @('env', 'get-value', $Name) -CaptureOutput
    }
    catch {
        if ($AllowMissing) {
            return ''
        }

        throw
    }
}

function Set-W365AzdValues {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )

    foreach ($entry in $Values.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            throw "Cannot persist empty azd environment value '$($entry.Key)'."
        }

        Invoke-W365Azd -Azd $Azd -Arguments @('env', 'set', [string]$entry.Key, [string]$entry.Value) | Out-Null
    }
}

function Resolve-W365TenantId {
    param(
        [Parameter(Mandatory)]$Azd,
        [guid]$ExplicitTenantId = [guid]::Empty
    )

    if ($ExplicitTenantId -ne [guid]::Empty) {
        return $ExplicitTenantId
    }

    foreach ($name in @('W365_TENANT_ID', 'AZURE_TENANT_ID')) {
        $value = Get-W365AzdValue -Azd $Azd -Name $name -AllowMissing
        $parsed = [guid]::Empty
        if ([guid]::TryParse($value, [ref]$parsed) -and $parsed -ne [guid]::Empty) {
            return $parsed
        }
    }

    throw 'TenantId is required when the azd environment does not contain AZURE_TENANT_ID or W365_TENANT_ID.'
}

function ConvertTo-W365NameToken {
    param([Parameter(Mandatory)][string]$Value)

    $token = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $token = $token -replace '-+', '-'
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Value '$Value' cannot produce a valid W365 resource name token."
    }

    return $token
}

function Get-W365PoolDisplayName {
    param(
        [Parameter(Mandatory)][string]$ResourcePrefix,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [ValidateRange(32, 128)][int]$MaximumLength = 64
    )

    $prefixToken = ConvertTo-W365NameToken -Value $ResourcePrefix
    $environmentToken = ConvertTo-W365NameToken -Value $EnvironmentName
    $ownershipToken = if ($prefixToken -eq $environmentToken) {
        $environmentToken
    }
    else {
        "$prefixToken-$environmentToken"
    }
    $name = "foundry-w365-$ownershipToken"
    if ($name.Length -le $MaximumLength) {
        return $name
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($name)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($bytes)
    $suffix = ([Convert]::ToHexString($hashBytes)).Substring(0, 8).ToLowerInvariant()
    $baseLength = $MaximumLength - $suffix.Length - 1
    return "$($name.Substring(0, $baseLength).TrimEnd('-'))-$suffix"
}

function ConvertTo-W365DomainName {
    param([Parameter(Mandatory)][string]$Value)

    $domain = $Value.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($domain) -or
        !$domain.Contains('.') -or
        [Uri]::CheckHostName($domain) -ne [UriHostNameType]::Dns) {
        throw "Value '$Value' is not a valid DNS domain name."
    }

    return $domain
}

function Resolve-W365AgentUserDomain {
    param(
        [Parameter(Mandatory)][object[]]$Domains,
        [string]$ExplicitDomain
    )

    $verifiedDomains = @($Domains | Where-Object {
        $_ -and $_.isVerified -eq $true -and
        ![string]::IsNullOrWhiteSpace([string]$_.id)
    })
    if (![string]::IsNullOrWhiteSpace($ExplicitDomain)) {
        $requestedDomain = ConvertTo-W365DomainName -Value $ExplicitDomain
        $matches = @($verifiedDomains | Where-Object {
            (ConvertTo-W365DomainName -Value ([string]$_.id)) -eq $requestedDomain
        })
        if ($matches.Count -ne 1) {
            throw "W365 agent-user domain '$requestedDomain' is not a unique verified domain in the requested tenant."
        }

        return $requestedDomain
    }

    $defaultDomains = @($verifiedDomains | Where-Object { $_.isDefault -eq $true })
    if ($defaultDomains.Count -ne 1) {
        throw "Expected exactly one verified default tenant domain for W365 agent-user creation, found $($defaultDomains.Count)."
    }

    return ConvertTo-W365DomainName -Value ([string]$defaultDomains[0].id)
}

function Get-W365AgentUserPrincipalName {
    param(
        [Parameter(Mandatory)][string]$ResourcePrefix,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Domain,
        [ValidateRange(32, 64)][int]$MaximumLocalPartLength = 64
    )

    $prefixToken = ConvertTo-W365NameToken -Value $ResourcePrefix
    $environmentToken = ConvertTo-W365NameToken -Value $EnvironmentName
    $ownershipToken = if ($prefixToken -eq $environmentToken) {
        $environmentToken
    }
    else {
        "$prefixToken-$environmentToken"
    }
    $localPart = "foundry-w365-$ownershipToken"
    if ($localPart.Length -gt $MaximumLocalPartLength) {
        $hashBytes = [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($localPart))
        $suffix = ([Convert]::ToHexString($hashBytes)).Substring(0, 8).ToLowerInvariant()
        $baseLength = $MaximumLocalPartLength - $suffix.Length - 1
        $localPart = "$($localPart.Substring(0, $baseLength).TrimEnd('-'))-$suffix"
    }

    return "$localPart@$(ConvertTo-W365DomainName -Value $Domain)"
}

function Resolve-W365OwnedAgentUserPrincipalName {
    param(
        [string]$ExplicitPrincipalName,
        [string]$ExplicitDomain,
        [string]$PersistedPrincipalName,
        [System.Collections.IDictionary]$OwnershipManifest,
        [Parameter(Mandatory)][object[]]$Domains,
        [string]$ResourcePrefix,
        [string]$EnvironmentName
    )

    $manifestPrincipalName = ''
    if ($OwnershipManifest -and
        $OwnershipManifest.Contains('w365') -and
        $OwnershipManifest.w365 -is [System.Collections.IDictionary] -and
        $OwnershipManifest.w365.Contains('agentUser') -and
        $OwnershipManifest.w365.agentUser -is [System.Collections.IDictionary] -and
        $OwnershipManifest.w365.agentUser.Contains('userPrincipalName')) {
        $manifestPrincipalName = [string]$OwnershipManifest.w365.agentUser.userPrincipalName
    }

    $requestedPrincipalName = if (![string]::IsNullOrWhiteSpace($ExplicitPrincipalName)) {
        $ExplicitPrincipalName.Trim().ToLowerInvariant()
    }
    elseif (![string]::IsNullOrWhiteSpace($PersistedPrincipalName)) {
        $PersistedPrincipalName.Trim().ToLowerInvariant()
    }
    else {
        ''
    }

    if (![string]::IsNullOrWhiteSpace($manifestPrincipalName)) {
        $ownedPrincipalName = $manifestPrincipalName.Trim().ToLowerInvariant()
        if (![string]::IsNullOrWhiteSpace($requestedPrincipalName) -and
            $requestedPrincipalName -ne $ownedPrincipalName) {
            throw "The requested W365 agent-user UPN '$requestedPrincipalName' does not match the environment-owned UPN '$ownedPrincipalName'."
        }
        $requestedPrincipalName = $ownedPrincipalName
    }

    if (![string]::IsNullOrWhiteSpace($requestedPrincipalName)) {
        if ($requestedPrincipalName -notmatch '^[a-z0-9._+-]+@([a-z0-9.-]+)$') {
            throw "W365 agent-user UPN '$requestedPrincipalName' is invalid."
        }
        $principalDomainValue = $Matches[1]
        $principalDomain = Resolve-W365AgentUserDomain -Domains $Domains -ExplicitDomain $principalDomainValue
        if (![string]::IsNullOrWhiteSpace($ExplicitDomain) -and
            (ConvertTo-W365DomainName -Value $ExplicitDomain) -ne $principalDomain) {
            throw "W365 agent-user UPN domain '$principalDomain' conflicts with explicit domain '$ExplicitDomain'."
        }

        return "$($requestedPrincipalName.Split('@')[0])@$principalDomain"
    }

    if ([string]::IsNullOrWhiteSpace($ResourcePrefix) -or
        [string]::IsNullOrWhiteSpace($EnvironmentName)) {
        throw 'AgentUserPrincipalName is required outside a selected azd environment because deterministic ownership naming cannot be derived.'
    }

    $resolvedDomain = Resolve-W365AgentUserDomain -Domains $Domains -ExplicitDomain $ExplicitDomain
    return Get-W365AgentUserPrincipalName `
        -ResourcePrefix $ResourcePrefix `
        -EnvironmentName $EnvironmentName `
        -Domain $resolvedDomain
}

function ConvertTo-W365PoolId {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [guid]::Empty
    }

    $parsed = [guid]::Empty
    if ([guid]::TryParse($Value, [ref]$parsed) -and $parsed -ne [guid]::Empty) {
        return $parsed
    }
    if ($Value -match 'poolId/([0-9a-fA-F-]{36})') {
        return [guid]$Matches[1]
    }

    throw 'PoolIdOrUrl must be a pool GUID or an Intune pool URL containing poolId/<guid>.'
}

function Resolve-W365OwnedPoolId {
    param(
        [guid]$ExplicitPoolId = [guid]::Empty,
        [string]$PoolReference,
        [System.Collections.IDictionary]$OwnershipManifest,
        [string]$PersistedPoolId
    )

    $requestedPoolId = if ($ExplicitPoolId -ne [guid]::Empty) {
        $ExplicitPoolId
    }
    else {
        ConvertTo-W365PoolId -Value $PoolReference
    }

    $manifestPoolId = [guid]::Empty
    if ($null -ne $OwnershipManifest) {
        $w365 = if ($OwnershipManifest.Contains('w365') -and
            $OwnershipManifest.w365 -is [System.Collections.IDictionary]) {
            $OwnershipManifest.w365
        }
        else {
            $null
        }
        $pool = if ($null -ne $w365 -and
            $w365.Contains('pool') -and
            $w365.pool -is [System.Collections.IDictionary]) {
            $w365.pool
        }
        else {
            $null
        }
        $manifestValue = if ($null -ne $pool -and $pool.Contains('id')) {
            [string]$pool.id
        }
        else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($manifestValue)) {
            throw 'The ownership manifest exists but does not contain w365.pool.id. Reconcile or tear down the partial environment before continuing.'
        }

        $manifestPoolId = ConvertTo-W365PoolId -Value $manifestValue
        if ($requestedPoolId -ne [guid]::Empty -and $requestedPoolId -ne $manifestPoolId) {
            throw "The requested W365 pool '$requestedPoolId' does not match the environment-owned pool '$manifestPoolId'."
        }

        return $manifestPoolId
    }

    if ($requestedPoolId -ne [guid]::Empty) {
        return $requestedPoolId
    }
    if (![string]::IsNullOrWhiteSpace($PersistedPoolId)) {
        throw 'W365_POOL_ID exists without an ownership manifest. It cannot be reused automatically; reconcile or tear down the legacy state first.'
    }

    return [guid]::Empty
}

function Assert-W365ResourceApproval {
    param(
        [Parameter(Mandatory)][bool]$EnableW365,
        [Parameter(Mandatory)][bool]$ConfirmResourceChanges
    )

    if (!$EnableW365) {
        return
    }
    if (!$ConfirmResourceChanges) {
        throw 'W365 enablement can create or update billable Cloud PC and Entra resources. Review the plan and explicitly confirm resource changes.'
    }
}

function Get-W365ProvisioningState {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues
    )

    $manifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $RepositoryRoot -EnvironmentName $EnvironmentName
    $manifest = Read-W365OwnershipManifest -Path $manifestPath -AllowMissing
    $persistedKeys = @('W365_POOL_ID', 'W365_AGENT_USER_ID', 'W365_AGENT_ID', 'W365_AGENT_OBJECT_ID', 'W365_BLUEPRINT_ID')
    $persistedState = @($persistedKeys | Where-Object {
        $EnvironmentValues.Contains($_) -and
        ![string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$_])
    })

    if ($null -eq $manifest) {
        if ($persistedState.Count -gt 0 -or [string]$EnvironmentValues['W365_ENABLED'] -eq 'true') {
            throw "W365 environment state exists without ownership manifest '$manifestPath'. Reconcile or tear down the legacy state before continuing."
        }

        return [pscustomobject]@{
            Name = 'FirstRun'
            ManifestPath = $manifestPath
            Manifest = $null
        }
    }

    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Ownership manifest '$manifestPath' uses unsupported schema version '$($manifest.schemaVersion)'."
    }
    if ([string]$manifest.environmentName -ne $EnvironmentName) {
        throw "Ownership manifest '$manifestPath' belongs to environment '$($manifest.environmentName)', not '$EnvironmentName'."
    }

    foreach ($required in @(
        @{ Path = 'w365.pool.id'; Value = $manifest.w365.pool.id },
        @{ Path = 'w365.agentUser.id'; Value = $manifest.w365.agentUser.id },
        @{ Path = 'w365.agentUser.userPrincipalName'; Value = $manifest.w365.agentUser.userPrincipalName },
        @{ Path = 'w365.assignment.poolId'; Value = $manifest.w365.assignment.poolId },
        @{ Path = 'w365.assignment.userPrincipalId'; Value = $manifest.w365.assignment.userPrincipalId }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "Ownership manifest '$manifestPath' is incomplete: $($required.Path) is required."
        }
    }

    $comparisons = @(
        @{ Key = 'W365_POOL_ID'; ManifestValue = $manifest.w365.pool.id },
        @{ Key = 'W365_AGENT_USER_ID'; ManifestValue = $manifest.w365.agentUser.id },
        @{ Key = 'W365_AGENT_USER_PRINCIPAL_NAME'; ManifestValue = $manifest.w365.agentUser.userPrincipalName },
        @{ Key = 'W365_AGENT_ID'; ManifestValue = $manifest.graph.agent.appId },
        @{ Key = 'W365_AGENT_OBJECT_ID'; ManifestValue = $manifest.graph.agent.objectId },
        @{ Key = 'W365_BLUEPRINT_ID'; ManifestValue = $manifest.graph.blueprint.appId }
    )
    foreach ($comparison in $comparisons) {
        $environmentValue = [string]$EnvironmentValues[$comparison.Key]
        if (![string]::IsNullOrWhiteSpace($environmentValue) -and
            $environmentValue -ne [string]$comparison.ManifestValue) {
            throw "W365 environment value '$($comparison.Key)' does not match the ownership manifest."
        }
    }

    return [pscustomobject]@{
        Name = if ([string]$EnvironmentValues['W365_ENABLED'] -eq 'true') { 'Complete' } else { 'Provisioned' }
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}
