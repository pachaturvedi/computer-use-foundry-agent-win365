#Requires -Version 7.4
<#
.SYNOPSIS
Provides shared W365 provisioning and azd helpers.

.DESCRIPTION
Resolves compatible azd commands, reads/writes non-secret environment values, derives deterministic names and agent-user UPNs, validates approvals/state/credentials, and reports provisioning state.


Key inputs: Environment values, tenant/pool/state identifiers, configuration objects, and approval flags supplied to exported functions.

.OUTPUTS
Validated identifiers, derived names, azd command results, and provisioning-state objects.

.NOTES
Dot-source library. It does not select credential modes from model input and preserves fail-closed ownership and state checks.
#>
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
    foreach ($command in @(Get-Command azd -All -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($null -eq $command) {
            continue
        }

        $source = [string]$command.Source
        if ([string]::IsNullOrWhiteSpace($source) -or
            !(Test-Path -LiteralPath $source -PathType Leaf)) {
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
        if (![string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path) -and
            !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    $candidates = $azdPaths |
        ForEach-Object {
            $candidatePath = [string]$_
            try {
                $versionOutput = & $candidatePath version 2>$null
            }
            catch {
                return
            }

            $parsedVersion = $null
            if ($LASTEXITCODE -eq 0 -and
                ($versionOutput | Out-String) -match 'azd version\s+(\d+\.\d+\.\d+)' -and
                [version]::TryParse($Matches[1], [ref]$parsedVersion)) {
                [pscustomobject]@{ Path = $candidatePath; Version = $parsedVersion }
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
    $output = @(& $Azd.Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $failure = ($output | Out-String).Trim()
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE. $failure"
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

function Resolve-W365HostedAgentOperatorDefaults {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFilePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues
    )

    $updates = [ordered]@{}

    if ([string]::IsNullOrWhiteSpace([string]$EnvironmentValues['OPERATOR_TENANT_ID'])) {
        $tenantId = (& az account show --query tenantId --output tsv 2>$null | Out-String).Trim()
        $parsedTenantId = [guid]::Empty
        if ($LASTEXITCODE -eq 0 -and [guid]::TryParse($tenantId, [ref]$parsedTenantId) -and $parsedTenantId -ne [guid]::Empty) {
            $updates['OPERATOR_TENANT_ID'] = $parsedTenantId.ToString()
        }
        else {
            Write-SampleVerbose -Component 'postup' -Message 'Unable to auto-resolve OPERATOR_TENANT_ID from az account show; it must be set manually.'
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$EnvironmentValues['OPERATOR_OBJECT_ID'])) {
        $objectId = (& az ad signed-in-user show --query id --output tsv 2>$null | Out-String).Trim()
        $parsedObjectId = [guid]::Empty
        if ($LASTEXITCODE -eq 0 -and [guid]::TryParse($objectId, [ref]$parsedObjectId) -and $parsedObjectId -ne [guid]::Empty) {
            $updates['OPERATOR_OBJECT_ID'] = $parsedObjectId.ToString()
        }
        else {
            Write-SampleVerbose -Component 'postup' -Message 'Unable to auto-resolve OPERATOR_OBJECT_ID from az ad signed-in-user show; it must be set manually.'
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$EnvironmentValues['HOSTED_ALLOWED_USER_ID'])) {
        $updates['HOSTED_ALLOWED_USER_ID'] = 'pending'
    }

    if ($updates.Count -eq 0) {
        return $EnvironmentValues
    }

    Set-AzdEnvironmentFileValues -Path $EnvironmentFilePath -Values $updates
    foreach ($entry in $updates.GetEnumerator()) {
        $EnvironmentValues[[string]$entry.Key] = [string]$entry.Value
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
        Write-Host "Resolved and persisted $($entry.Key) for the hosted-agent operator binding."
    }

    return $EnvironmentValues
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

function Assert-W365ActivationPrerequisites {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
        [Parameter(Mandatory)][guid]$ExpectedAgentIdentityId,
        [guid]$HostedRuntimeIdentityObjectId = [guid]::Empty,
        [bool]$AuthorizeHostedRuntimeFederation = $false
    )

    $required = @(
        'SESSION_BLOB_URI',
        'STATE_AGENT_PRINCIPAL_ID',
        'OPERATOR_TENANT_ID',
        'OPERATOR_OBJECT_ID',
        'HOSTED_ALLOWED_USER_ID',
        'W365_BLUEPRINT_CREDENTIAL_MODE'
    )
    $missing = @($required | Where-Object {
        !$EnvironmentValues.Contains($_) -or
        [string]::IsNullOrWhiteSpace([string]$EnvironmentValues[$_])
    })
    if ($missing.Count -gt 0) {
        throw "W365 activation requires these azd environment values before setup mutates W365 or Entra: $($missing -join ', ')."
    }
    if ([string]$EnvironmentValues['DEPLOY_STATE'] -ne 'true') {
        throw 'W365 activation requires DEPLOY_STATE=true and provisioned shared Blob state.'
    }

    $sessionBlobUri = $null
    if (![uri]::TryCreate([string]$EnvironmentValues['SESSION_BLOB_URI'], [UriKind]::Absolute, [ref]$sessionBlobUri) -or
        $sessionBlobUri.Scheme -ne [Uri]::UriSchemeHttps) {
        throw 'SESSION_BLOB_URI must be a valid HTTPS URI before W365 setup.'
    }
    Resolve-W365SessionBlobLocation -SessionBlobUri $sessionBlobUri | Out-Null

    $statePrincipalId = [guid]::Empty
    if (![guid]::TryParse([string]$EnvironmentValues['STATE_AGENT_PRINCIPAL_ID'], [ref]$statePrincipalId) -or
        $statePrincipalId -eq [guid]::Empty -or
        $statePrincipalId -ne $ExpectedAgentIdentityId) {
        throw 'STATE_AGENT_PRINCIPAL_ID must match the discovered Foundry agent object/principal ID.'
    }
    foreach ($name in @('OPERATOR_TENANT_ID', 'OPERATOR_OBJECT_ID')) {
        $id = [guid]::Empty
        if (![guid]::TryParse([string]$EnvironmentValues[$name], [ref]$id) -or $id -eq [guid]::Empty) {
            throw "$name must be a non-empty GUID before W365 setup."
        }
    }

    $credentialMode = [string]$EnvironmentValues['W365_BLUEPRINT_CREDENTIAL_MODE']
    if ($credentialMode -notin @('client_secret', 'managed_identity_federation', 'key_vault_certificate')) {
        throw 'W365_BLUEPRINT_CREDENTIAL_MODE must be explicitly client_secret, managed_identity_federation, or key_vault_certificate before W365 setup.'
    }
    if (($credentialMode -eq 'client_secret' -or $credentialMode -eq 'key_vault_certificate') -and
        (!$EnvironmentValues.Contains('W365_KEY_VAULT_NAME') -or
         [string]::IsNullOrWhiteSpace([string]$EnvironmentValues['W365_KEY_VAULT_NAME']))) {
        throw "$credentialMode mode requires W365_KEY_VAULT_NAME and a securely stored blueprint credential before W365 setup."
    }
    if ($credentialMode -eq 'managed_identity_federation' -and
        (!$AuthorizeHostedRuntimeFederation -or
         $HostedRuntimeIdentityObjectId -eq [guid]::Empty -or
         $HostedRuntimeIdentityObjectId -ne $ExpectedAgentIdentityId)) {
        throw 'managed_identity_federation requires explicit hosted-runtime federation authorization for the exact discovered Foundry agent object/principal ID before W365 setup.'
    }

    return [pscustomobject]@{
        CredentialMode = $credentialMode
        KeyVaultName = [string]$EnvironmentValues['W365_KEY_VAULT_NAME']
    }
}

function Invoke-W365AzureCliRead {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 10)][int]$MaxAttempts = 1,
        [ValidateRange(0, 30)][int]$RetryDelaySeconds = 2
    )

    $lastError = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $stderrPath = [IO.Path]::GetTempFileName()
        try {
            $output = & az @Arguments 2> $stderrPath
            $exitCode = $LASTEXITCODE
            $lastError = if ((Get-Item -LiteralPath $stderrPath).Length -gt 0) {
                (Get-Content -LiteralPath $stderrPath -Raw).Trim()
            }
            else {
                ''
            }
        }
        finally {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }

        if ($exitCode -eq 0) {
            return ($output | Out-String).Trim()
        }
        if ($attempt -lt $MaxAttempts) {
            Write-Warning "Azure CLI read attempt $attempt of $MaxAttempts failed; retrying in $RetryDelaySeconds second(s)."
            if ($RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    $errorSummary = ($lastError -replace '\s+', ' ').Trim()
    if ($errorSummary.Length -gt 800) {
        $errorSummary = $errorSummary.Substring(0, 800) + '...'
    }
    if ([string]::IsNullOrWhiteSpace($errorSummary)) {
        $errorSummary = 'Azure CLI returned no error details.'
    }

    throw "Azure CLI read failed after $MaxAttempts attempt(s): az $($Arguments -join ' '). Details: $errorSummary"
}

function ConvertTo-W365LocationToken {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Resolve-W365ViewerResourceNames {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$ResourcePrefix = '',
        [string]$ResourceGroupName = ''
    )

    $prefix = if (![string]::IsNullOrWhiteSpace($ResourcePrefix)) { $ResourcePrefix } else { $EnvironmentName }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        throw 'Cannot resolve viewer resource names without RESOURCE_PREFIX or AZURE_ENV_NAME.'
    }

    $group = if (![string]::IsNullOrWhiteSpace($ResourceGroupName)) { $ResourceGroupName } else { "$prefix-rg" }

    return [pscustomobject]@{
        ResourceGroupName = $group
        IdentityName = "$prefix-viewer-identity"
        ContainerAppName = "$prefix-viewer"
    }
}

function Get-W365ExistingResourceLocation {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ResourceType
    )

    $groupExists = Invoke-W365AzureCliRead -Arguments @('group', 'exists', '--name', $ResourceGroupName)
    if ($groupExists -ne 'true') {
        return ''
    }

    return Invoke-W365AzureCliRead -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroupName,
        '--resource-type', $ResourceType,
        '--query', "[?name=='$Name'].location | [0]",
        '--output', 'tsv'
    )
}

function Resolve-W365ViewerIdentityLocation {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$ResourcePrefix = '',
        [string]$ResourceGroupName = ''
    )

    $names = Resolve-W365ViewerResourceNames `
        -EnvironmentName $EnvironmentName `
        -ResourcePrefix $ResourcePrefix `
        -ResourceGroupName $ResourceGroupName

    return Get-W365ExistingResourceLocation `
        -ResourceGroupName $names.ResourceGroupName `
        -Name $names.IdentityName `
        -ResourceType 'Microsoft.ManagedIdentity/userAssignedIdentities'
}

function Assert-W365ViewerContainerAppRegion {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$ResourcePrefix = '',
        [string]$ResourceGroupName = '',
        [string]$ManagedEnvironmentResourceId = ''
    )

    if ([string]::IsNullOrWhiteSpace($ManagedEnvironmentResourceId)) {
        return
    }

    $names = Resolve-W365ViewerResourceNames `
        -EnvironmentName $EnvironmentName `
        -ResourcePrefix $ResourcePrefix `
        -ResourceGroupName $ResourceGroupName

    $existingAppLocation = Get-W365ExistingResourceLocation `
        -ResourceGroupName $names.ResourceGroupName `
        -Name $names.ContainerAppName `
        -ResourceType 'Microsoft.App/containerApps'
    if ([string]::IsNullOrWhiteSpace($existingAppLocation)) {
        return
    }

    $managedEnvironmentLocation = Invoke-W365AzureCliRead -Arguments @(
        'resource', 'show',
        '--ids', $ManagedEnvironmentResourceId,
        '--api-version', '2024-03-01',
        '--query', 'location',
        '--output', 'tsv'
    ) -MaxAttempts 3

    if ((ConvertTo-W365LocationToken $existingAppLocation) -ne (ConvertTo-W365LocationToken $managedEnvironmentLocation)) {
        throw @"
Viewer container app '$($names.ContainerAppName)' already exists in '$existingAppLocation', but the selected ACA managed environment is in '$managedEnvironmentLocation'. A container app cannot change region.
Either select a managed environment in '$existingAppLocation', or delete the existing container app before rerunning:
    az containerapp delete --name $($names.ContainerAppName) --resource-group $($names.ResourceGroupName) --yes
"@
    }
}

function Initialize-W365ViewerRegionEnvironment {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$ResourcePrefix = '',
        [string]$ResourceGroupName = '',
        [string]$ManagedEnvironmentResourceId = ''
    )

    Assert-W365ViewerContainerAppRegion `
        -EnvironmentName $EnvironmentName `
        -ResourcePrefix $ResourcePrefix `
        -ResourceGroupName $ResourceGroupName `
        -ManagedEnvironmentResourceId $ManagedEnvironmentResourceId

    $identityLocation = Resolve-W365ViewerIdentityLocation `
        -EnvironmentName $EnvironmentName `
        -ResourcePrefix $ResourcePrefix `
        -ResourceGroupName $ResourceGroupName

    $env:VIEWER_IDENTITY_LOCATION = $identityLocation
    if (![string]::IsNullOrWhiteSpace($identityLocation)) {
        Write-W365ProvisioningStep "Reusing the existing viewer identity region '$identityLocation'; a managed identity cannot change region."
    }

    return $identityLocation
}

function Resolve-W365SessionBlobLocation {
    param([Parameter(Mandatory)][uri]$SessionBlobUri)

    if ($SessionBlobUri.Scheme -ne [Uri]::UriSchemeHttps -or
        $SessionBlobUri.Host -notmatch '^(?<account>[a-z0-9]{3,24})\.blob\.core\.windows\.net$' -or
        !$SessionBlobUri.IsDefaultPort -or
        ![string]::IsNullOrEmpty($SessionBlobUri.UserInfo) -or
        ![string]::IsNullOrEmpty($SessionBlobUri.Query) -or
        ![string]::IsNullOrEmpty($SessionBlobUri.Fragment) -or
        $SessionBlobUri.AbsolutePath -ne '/desktop-state/slot.json' -or
        $SessionBlobUri.OriginalString -cne "https://$($SessionBlobUri.Host)/desktop-state/slot.json") {
        throw 'SESSION_BLOB_URI must be exactly https://<storage-account>.blob.core.windows.net/desktop-state/slot.json without credentials, query, or fragment.'
    }

    return [pscustomobject]@{
        StorageAccountName = $Matches.account
        ContainerName = 'desktop-state'
    }
}

function Assert-W365StateResourceReady {
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][uri]$SessionBlobUri,
        [Parameter(Mandatory)][guid]$ExpectedAgentIdentityId
    )

    $blobLocation = Resolve-W365SessionBlobLocation -SessionBlobUri $SessionBlobUri
    $storageAccountName = $blobLocation.StorageAccountName

    $storageAccountId = Invoke-W365AzureCliRead -Arguments @(
        'storage', 'account', 'show',
        '--subscription', $SubscriptionId.ToString(),
        '--name', $storageAccountName,
        '--query', 'id',
        '--output', 'tsv')
    if ([string]::IsNullOrWhiteSpace($storageAccountId)) {
        throw "Storage account '$storageAccountName' was not found."
    }

    $containerScope = "$storageAccountId/blobServices/default/containers/$($blobLocation.ContainerName)"
    $containerName = Invoke-W365AzureCliRead -Arguments @(
        'rest',
        '--method', 'get',
        '--url', "https://management.azure.com${containerScope}?api-version=2023-05-01",
        '--query', 'name',
        '--output', 'tsv')
    if ($containerName -ne $blobLocation.ContainerName) {
        throw "Storage account '$storageAccountName' does not contain the expected $($blobLocation.ContainerName) container."
    }

    $principalId = $ExpectedAgentIdentityId.ToString()
    $roleDefinitionIds = Invoke-W365AzureCliRead -Arguments @(
        'role', 'assignment', 'list',
        '--subscription', $SubscriptionId.ToString(),
        '--assignee-object-id', $principalId,
        '--scope', $containerScope,
        '--query', "[?principalId=='$principalId'].roleDefinitionId",
        '--output', 'tsv')
    $blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    $hasBlobContributor = @($roleDefinitionIds -split '\r?\n' | Where-Object {
        $_.Trim().EndsWith("/$blobContributorRoleId", [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    if (!$hasBlobContributor) {
        throw "Foundry agent principal '$principalId' requires container-scoped Storage Blob Data Contributor on '$containerScope'."
    }

    return [pscustomobject]@{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        ContainerScope = $containerScope
    }
}

function Assert-W365BlueprintSecretReady {
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$KeyVaultName
    )

    $secretId = Invoke-W365AzureCliRead -Arguments @(
        'keyvault', 'secret', 'show',
        '--subscription', $SubscriptionId.ToString(),
        '--vault-name', $KeyVaultName,
        '--name', 'w365-blueprint-client-secret',
        '--query', 'id',
        '--output', 'tsv')
    if ([string]::IsNullOrWhiteSpace($secretId)) {
        throw "Key Vault '$KeyVaultName' must contain w365-blueprint-client-secret before W365 setup mutates resources."
    }
}

function Assert-W365BlueprintCertificateReady {
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$KeyVaultName,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$BlueprintId
    )

    $certificateId = Invoke-W365AzureCliRead -Arguments @(
        'keyvault', 'certificate', 'show',
        '--subscription', $SubscriptionId.ToString(),
        '--vault-name', $KeyVaultName,
        '--name', 'w365-blueprint-certificate',
        '--query', 'id',
        '--output', 'tsv')
    if ([string]::IsNullOrWhiteSpace($certificateId)) {
        throw "Key Vault '$KeyVaultName' must contain w365-blueprint-certificate before W365 setup mutates resources."
    }

    # Presence in Key Vault alone does not prove the certificate is trusted by Foundry: verify the
    # exact same certificate is registered exactly once as a keyCredential on the discovered
    # blueprint before W365 setup proceeds to mutate resources against it.
    $vaultUri = Invoke-W365AzureCliRead -Arguments @(
        'keyvault', 'show',
        '--subscription', $SubscriptionId.ToString(),
        '--name', $KeyVaultName,
        '--query', 'properties.vaultUri',
        '--output', 'tsv')
    $vaultAccessToken = Invoke-W365AzureCliRead -Arguments @(
        'account', 'get-access-token',
        '--resource', 'https://vault.azure.net',
        '--query', 'accessToken',
        '--output', 'tsv')
    $certificateBundle = Invoke-RestMethod `
        -Method Get `
        -Uri "$($vaultUri.TrimEnd('/'))/certificates/w365-blueprint-certificate`?api-version=7.4" `
        -Headers @{ Authorization = "Bearer $vaultAccessToken" }
    if ([string]::IsNullOrWhiteSpace($certificateBundle.cer)) {
        throw "Unable to read the public certificate bytes for 'w365-blueprint-certificate' from Key Vault '$KeyVaultName'."
    }
    # Key Vault encodes 'cer' as base64url (RFC 7515 JOSE convention); convert to standard base64.
    $base64UrlCer = $certificateBundle.cer.Replace('-', '+').Replace('_', '/')
    switch ($base64UrlCer.Length % 4) {
        2 { $base64UrlCer += '==' }
        3 { $base64UrlCer += '=' }
    }
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($base64UrlCer))
    $expectedKeyIdentifier = [Convert]::ToBase64String($certificate.GetCertHash())

    $graphAccessToken = Invoke-W365AzureCliRead -Arguments @(
        'account', 'get-access-token',
        '--resource', 'https://graph.microsoft.com',
        '--tenant', $TenantId.ToString(),
        '--query', 'accessToken',
        '--output', 'tsv')
    $blueprint = Invoke-RestMethod `
        -Method Get `
        -Uri "https://graph.microsoft.com/v1.0/applications(appId='$BlueprintId')/microsoft.graph.agentIdentityBlueprint`?`$select=keyCredentials" `
        -Headers @{ Authorization = "Bearer $graphAccessToken" }
    $registeredMatches = @($blueprint.keyCredentials | Where-Object {
        [string]$_.customKeyIdentifier -eq $expectedKeyIdentifier
    })
    if ($registeredMatches.Count -ne 1) {
        throw "Certificate 'w365-blueprint-certificate' exists in Key Vault '$KeyVaultName' but is not registered exactly once as a keyCredential on blueprint '$BlueprintId'. Run Register-W365BlueprintCertificate.ps1 -ConfirmResourceChanges before continuing."
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
