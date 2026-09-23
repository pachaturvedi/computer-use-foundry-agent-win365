#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path (Join-Path $repoRoot 'scripts') 'W365Provisioning.ps1')

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("w365-prefix-{0}" -f ([guid]::NewGuid()))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$script:azCalls = @()
$script:groupPayload = '[]'
$script:groupExitCode = 0

function az {
    $arguments = @($args)
    $script:azCalls += ($arguments -join ' ')
    $global:LASTEXITCODE = $script:groupExitCode
    if ($arguments[0] -eq 'group' -and $arguments[1] -eq 'list') {
        return $script:groupPayload
    }

    $global:LASTEXITCODE = 1
    return ''
}

function New-EnvironmentFile {
    param([hashtable]$Values = @{})

    $path = Join-Path $tempRoot ("env-{0}.env" -f ([guid]::NewGuid()))
    $lines = foreach ($entry in $Values.GetEnumerator()) { "$($entry.Key)=`"$($entry.Value)`"" }
    Set-Content -Path $path -Value $lines -Encoding utf8
    return $path
}

try {
    # An explicitly configured prefix always wins and is never re-derived.
    $script:azCalls = @()
    $path = New-EnvironmentFile -Values @{ AZURE_ENV_NAME = 'contoso-dev'; RESOURCE_PREFIX = 'chosen-prefix' }
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix -EnvironmentFilePath $path -EnvironmentName 'contoso-dev' -EnvironmentValues $values
    if ([string]$result['RESOURCE_PREFIX'] -ne 'chosen-prefix') {
        throw 'An explicitly configured RESOURCE_PREFIX was overwritten.'
    }
    if ($script:azCalls.Count -ne 0) {
        throw 'Azure was queried even though RESOURCE_PREFIX was already configured.'
    }

    # The deployed resource group tag is authoritative when the prefix differs
    # from the azd environment name, which is the long-environment-name case.
    $script:groupExitCode = 0
    $script:groupPayload = @'
[{"name":"fawin365-dev-rg","tags":{"azd-env-name":"computer-use-foundry-agent-win365-dev","resource-prefix":"fawin365-dev"}}]
'@
    $script:azCalls = @()
    $path = New-EnvironmentFile -Values @{ AZURE_ENV_NAME = 'computer-use-foundry-agent-win365-dev' }
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix `
        -EnvironmentFilePath $path `
        -EnvironmentName 'computer-use-foundry-agent-win365-dev' `
        -EnvironmentValues $values
    if ([string]$result['RESOURCE_PREFIX'] -ne 'fawin365-dev') {
        throw "The deployed resource-prefix tag was not used; got '$($result['RESOURCE_PREFIX'])'."
    }
    if (@($script:azCalls | Where-Object { $_ -like 'group list*azd-env-name=computer-use-foundry-agent-win365-dev*' }).Count -ne 1) {
        throw 'The resource group was not looked up by its azd-env-name tag.'
    }

    # The resolved value is persisted so later steps and reruns stay stable.
    $persisted = Read-AzdEnvironmentFile -Path $path
    if ([string]$persisted['RESOURCE_PREFIX'] -ne 'fawin365-dev') {
        throw 'The resolved RESOURCE_PREFIX was not persisted to the azd environment file.'
    }
    if ([Environment]::GetEnvironmentVariable('RESOURCE_PREFIX', 'Process') -ne 'fawin365-dev') {
        throw 'The resolved RESOURCE_PREFIX was not exported to the current process.'
    }

    # With no deployed group, fall back to the azd environment name, which is the
    # same default the Bicep templates apply when resourcePrefix is empty.
    $script:groupPayload = '[]'
    $path = New-EnvironmentFile -Values @{ AZURE_ENV_NAME = 'demosept23-su' }
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix -EnvironmentFilePath $path -EnvironmentName 'demosept23-su' -EnvironmentValues $values
    if ([string]$result['RESOURCE_PREFIX'] -ne 'demosept23-su') {
        throw "The azd environment name fallback was not applied; got '$($result['RESOURCE_PREFIX'])'."
    }

    # A resource group without the tag must not yield an empty prefix.
    $script:groupPayload = '[{"name":"demosept23-su-rg","tags":{"azd-env-name":"demosept23-su"}}]'
    $path = New-EnvironmentFile -Values @{ AZURE_ENV_NAME = 'demosept23-su' }
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix -EnvironmentFilePath $path -EnvironmentName 'demosept23-su' -EnvironmentValues $values
    if ([string]$result['RESOURCE_PREFIX'] -ne 'demosept23-su') {
        throw 'An untagged resource group did not fall back to the azd environment name.'
    }

    # An Azure CLI failure must not block provisioning.
    $script:groupExitCode = 1
    $script:groupPayload = ''
    $path = New-EnvironmentFile -Values @{ AZURE_ENV_NAME = 'offline-dev' }
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix -EnvironmentFilePath $path -EnvironmentName 'offline-dev' -EnvironmentValues $values
    if ([string]$result['RESOURCE_PREFIX'] -ne 'offline-dev') {
        throw 'A failed Azure CLI lookup did not fall back to the azd environment name.'
    }

    # Outside a selected environment there is nothing deterministic to derive.
    $script:groupExitCode = 0
    $path = New-EnvironmentFile
    $values = Read-AzdEnvironmentFile -Path $path
    $result = Resolve-W365ResourcePrefix -EnvironmentFilePath $path -EnvironmentName '' -EnvironmentValues $values
    if (![string]::IsNullOrWhiteSpace([string]$result['RESOURCE_PREFIX'])) {
        throw 'A prefix was invented without a selected azd environment.'
    }

    Write-Host 'Test-ResourcePrefixResolutionOffline passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('RESOURCE_PREFIX', $null, 'Process')
    Remove-Item Function:\az -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
