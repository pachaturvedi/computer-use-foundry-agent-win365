#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Environment,
    [switch]$Apply,
    [string]$AzdPath,
    [string]$DotNetPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
$safeLogParameters = [ordered]@{
    Environment = $Environment
    Apply = $Apply.IsPresent
}
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $safeLogParameters

function Resolve-RecoveryCommand {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory)][string]$Name
    )

    if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (!(Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "$Name path was not found."
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw "$Name is required for stale-state recovery."
    }
    return $command.Source
}

function Invoke-RecoveryAzd {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $global:LASTEXITCODE = 0
    $output = (& $script:AzdExecutable @Arguments 2>&1 | Out-String).Trim()
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw 'Recovery blocked: an azd verification command failed.'
    }
    return $output
}

function Get-RecoveryEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $value = Invoke-RecoveryAzd -Arguments @(
        'env', 'get-value', $Name, '--environment', $EnvironmentName
    )
    $value = $value.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Recovery blocked: azd environment value '$Name' is missing."
    }
    return $value
}

function Assert-NoRunningHostedSessions {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$DeployedAgentName
    )

    $json = Invoke-RecoveryAzd -Arguments @(
        'ai', 'agent', 'sessions', 'list',
        '--agent-name', $DeployedAgentName,
        '--environment', $EnvironmentName,
        '--limit', '100',
        '--output', 'json'
    )
    try {
        $result = $json | ConvertFrom-Json -Depth 30 -NoEnumerate
    }
    catch {
        throw 'Recovery blocked: hosted-session inspection returned malformed JSON.'
    }

    $containers = @($result)
    if ($null -ne $result -and $null -ne $result.PSObject.Properties['data'] -and
        $result.data -isnot [array]) {
        $containers += $result.data
    }
    $continuation = foreach ($container in $containers) {
        foreach ($name in @(
            'paginationToken', 'pagination_token', 'continuationToken',
            'nextLink', 'next_link', 'nextToken', 'nextPageToken', '@odata.nextLink')) {
            $property = $container.PSObject.Properties[$name]
            if ($null -ne $property) {
                $property.Value
            }
        }
        $paging = $container.PSObject.Properties['pagination']
        if ($null -ne $paging -and $null -ne $paging.Value) {
            foreach ($name in @('nextToken', 'nextLink', 'continuationToken')) {
                $property = $paging.Value.PSObject.Properties[$name]
                if ($null -ne $property) {
                    $property.Value
                }
            }
        }
    }
    $continuation = @($continuation | Where-Object {
        ![string]::IsNullOrWhiteSpace([string]$_)
    })
    if (@($continuation).Count -ne 0) {
        throw 'Recovery blocked: hosted-session inspection was paged; stop sessions and retry after the list is unambiguous.'
    }

    $collections = @()
    if ($result -is [array]) {
        $collections += ,@($result)
    }
    else {
        foreach ($name in @('sessions', 'items', 'value')) {
            $property = $result.PSObject.Properties[$name]
            if ($null -ne $property) {
                $collections += ,@($property.Value)
            }
        }
        $dataProperty = $result.PSObject.Properties['data']
        if ($null -ne $dataProperty) {
            if ($dataProperty.Value -is [array]) {
                $collections += ,@($dataProperty.Value)
            }
            elseif ($null -ne $dataProperty.Value) {
                foreach ($name in @('sessions', 'items', 'value')) {
                    $property = $dataProperty.Value.PSObject.Properties[$name]
                    if ($null -ne $property) {
                        $collections += ,@($property.Value)
                    }
                }
            }
        }
    }
    if ($collections.Count -ne 1) {
        throw 'Recovery blocked: hosted-session inspection returned an unknown or mixed schema.'
    }
    $records = if ($result -is [array]) {
        @($result)
    }
    else {
        @($collections[0])
    }

    $safeStatuses = @('stopped', 'idle', 'deleted', 'expired')
    foreach ($record in $records) {
        $statusProperty = $record.PSObject.Properties['status']
        if ($null -eq $statusProperty -or
            [string]::IsNullOrWhiteSpace([string]$statusProperty.Value) -or
            ([string]$statusProperty.Value).Trim().ToLowerInvariant() -notin $safeStatuses) {
            throw 'Recovery blocked: a hosted session is running or has an ambiguous status. Stop it before recovery.'
        }
    }
}

if (!$IsWindows) {
    throw 'Stale desktop state recovery is Windows-only. Use PowerShell 7.4 or later on Windows.'
}

$resolvedAzd = if (![string]::IsNullOrWhiteSpace($AzdPath)) {
    [pscustomobject]@{ Path = (Resolve-RecoveryCommand -ExplicitPath $AzdPath -Name 'azd') }
}
else {
    Get-W365AzdCommand
}
if (!$resolvedAzd) {
    throw 'Azure Developer CLI 1.32.0 or later is required.'
}
$AzdExecutable = $resolvedAzd.Path
$dotnetExecutable = Resolve-RecoveryCommand -ExplicitPath $DotNetPath -Name 'dotnet'

$environmentName = if ([string]::IsNullOrWhiteSpace($Environment)) {
    $selected = Invoke-RecoveryAzd -Arguments @('env', 'get-value', 'AZURE_ENV_NAME')
    $selected.Trim().Trim('"')
}
else {
    $Environment
}
if ([string]::IsNullOrWhiteSpace($environmentName)) {
    throw 'Recovery blocked: pass -Environment or select an azd environment.'
}

$configurationNames = @(
    'SESSION_BLOB_URI',
    'W365_TENANT_ID',
    'W365_BLUEPRINT_ID',
    'W365_AGENT_ID',
    'W365_AGENT_USER_ID',
    'W365_BLUEPRINT_CREDENTIAL_MODE',
    'OPERATOR_TENANT_ID',
    'OPERATOR_OBJECT_ID',
    'FOUNDRY_AGENT_NAME'
)
$configuration = @{}
foreach ($name in $configurationNames) {
    $configuration[$name] = Get-RecoveryEnvironmentValue `
        -Name $name `
        -EnvironmentName $environmentName
}
if ($configuration['W365_BLUEPRINT_CREDENTIAL_MODE'] -in @(
    'client_secret',
    'key_vault_certificate'
)) {
    $configuration['W365_KEY_VAULT_NAME'] = Get-RecoveryEnvironmentValue `
        -Name 'W365_KEY_VAULT_NAME' `
        -EnvironmentName $environmentName
}
$configuration['RECOVERY_AZD_PATH'] = $AzdExecutable

$modeMessage = if ($Apply) {
    'Recovery mode: guarded mutation requested; no identifiers or state will be displayed.'
}
else {
    'Recovery mode: read-only inspection; no lease or state will be changed.'
}
Write-Host $modeMessage
Assert-NoRunningHostedSessions `
    -EnvironmentName $environmentName `
    -DeployedAgentName $configuration['FOUNDRY_AGENT_NAME']
Write-Host 'Hosted-session check passed: no session is actively running.'

$previousValues = @{}
try {
    foreach ($entry in $configuration.GetEnumerator()) {
        $previousValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }

    $commandArguments = @(
        'run',
        '--project', (Join-Path (Split-Path $PSScriptRoot) 'src\Win365Agent\Win365Agent.csproj'),
        '--configuration', 'Release',
        '--',
        'recover-stale-state',
        '--environment', $environmentName
    )
    $willApply = $Apply -and $PSCmdlet.ShouldProcess(
        'the private desktop state Blob',
        'break the verified stale lease and clear unchanged expired state')
    if ($willApply) {
        $commandArguments += '--apply'
    }

    $global:LASTEXITCODE = 0
    & $dotnetExecutable @commandArguments
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw 'Recovery failed safely. No successful state clear was reported.'
    }
}
finally {
    foreach ($entry in $previousValues.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}
