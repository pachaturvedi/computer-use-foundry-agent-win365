#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)

$script:azCalls = @()
$script:groupExists = 'true'
$script:identityLocation = ''
$script:containerAppLocation = ''
$script:managedEnvironmentLocation = ''
$script:resourceShowFailuresRemaining = 0

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $script:azCalls += ($arguments -join ' ')

    if ($arguments[0] -eq 'group' -and $arguments[1] -eq 'exists') {
        return $script:groupExists
    }
    if ($arguments[0] -eq 'resource' -and $arguments[1] -eq 'list') {
        if ($arguments -contains 'Microsoft.ManagedIdentity/userAssignedIdentities') {
            return $script:identityLocation
        }
        return $script:containerAppLocation
    }
    if ($arguments[0] -eq 'resource' -and $arguments[1] -eq 'show') {
        if ($script:resourceShowFailuresRemaining -gt 0) {
            $script:resourceShowFailuresRemaining--
            $global:LASTEXITCODE = 1
            Write-Error 'ERROR: (TooManyRequests) The Azure control plane temporarily throttled the read.' -ErrorAction Continue
            return ''
        }
        return $script:managedEnvironmentLocation
    }

    $global:LASTEXITCODE = 1
    return ''
}

. (Join-Path $root 'scripts\W365Provisioning.ps1')

$names = Resolve-W365ViewerResourceNames -EnvironmentName 'sample-dev'
if ($names.ResourceGroupName -ne 'sample-dev-rg' -or
    $names.IdentityName -ne 'sample-dev-viewer-identity' -or
    $names.ContainerAppName -ne 'sample-dev-viewer') {
    throw 'Viewer resource names were not derived from the environment name.'
}

$prefixed = Resolve-W365ViewerResourceNames `
    -EnvironmentName 'sample-dev' `
    -ResourcePrefix 'custom' `
    -ResourceGroupName 'custom-group'
if ($prefixed.ResourceGroupName -ne 'custom-group' -or
    $prefixed.IdentityName -ne 'custom-viewer-identity') {
    throw 'Explicit resource prefix and group were not honoured.'
}

# A missing resource group means a first deployment, which must use the deployment region.
$script:groupExists = 'false'
if ((Resolve-W365ViewerIdentityLocation -EnvironmentName 'sample-dev') -ne '') {
    throw 'A missing resource group must not pin an identity region.'
}

# An absent identity must also fall back to the deployment region.
$script:groupExists = 'true'
$script:identityLocation = ''
if ((Resolve-W365ViewerIdentityLocation -EnvironmentName 'sample-dev') -ne '') {
    throw 'An absent viewer identity must not pin an identity region.'
}

# An existing identity is immutable, so its region must be reused.
$script:identityLocation = 'westus'
if ((Resolve-W365ViewerIdentityLocation -EnvironmentName 'sample-dev') -ne 'westus') {
    throw 'An existing viewer identity region was not reused.'
}

$previousIdentityLocationEnv = $env:VIEWER_IDENTITY_LOCATION
try {
    $env:VIEWER_IDENTITY_LOCATION = ''
    $script:containerAppLocation = ''
    $resolved = Initialize-W365ViewerRegionEnvironment -EnvironmentName 'sample-dev'
    if ($resolved -ne 'westus' -or $env:VIEWER_IDENTITY_LOCATION -ne 'westus') {
        throw 'Viewer region initialization did not publish VIEWER_IDENTITY_LOCATION.'
    }

    # No managed environment selection means no container-app region conflict to check.
    $script:azCalls = @()
    $script:containerAppLocation = 'westus'
    $script:managedEnvironmentLocation = 'eastus2'
    Initialize-W365ViewerRegionEnvironment -EnvironmentName 'sample-dev' | Out-Null
    if (@($script:azCalls | Where-Object { $_ -like 'resource show*' }).Count -ne 0) {
        throw 'Managed-environment region was queried without a recorded selection.'
    }

    # A reused managed environment in another region cannot host the existing container app.
    $conflict = $null
    try {
        Initialize-W365ViewerRegionEnvironment `
            -EnvironmentName 'sample-dev' `
            -ManagedEnvironmentResourceId '/subscriptions/s/resourceGroups/g/providers/Microsoft.App/managedEnvironments/e' | Out-Null
    }
    catch {
        $conflict = $_.Exception.Message
    }
    if ($null -eq $conflict -or
        $conflict -notlike "*already exists in 'westus'*" -or
        $conflict -notlike '*az containerapp delete*') {
        throw 'A cross-region container app reuse did not fail with actionable guidance.'
    }

    # Matching regions must provision without complaint.
    $script:managedEnvironmentLocation = 'West US'
    Initialize-W365ViewerRegionEnvironment `
        -EnvironmentName 'sample-dev' `
        -ManagedEnvironmentResourceId '/subscriptions/s/resourceGroups/g/providers/Microsoft.App/managedEnvironments/e' | Out-Null

    # A transient managed-environment read must be retried before blocking post-up.
    $script:azCalls = @()
    $script:resourceShowFailuresRemaining = 2
    Initialize-W365ViewerRegionEnvironment `
        -EnvironmentName 'sample-dev' `
        -ManagedEnvironmentResourceId '/subscriptions/s/resourceGroups/g/providers/Microsoft.App/managedEnvironments/e' | Out-Null
    if (@($script:azCalls | Where-Object { $_ -like 'resource show*' }).Count -ne 3) {
        throw 'Managed-environment location lookup did not retry a transient Azure CLI failure.'
    }
    if (@($script:azCalls | Where-Object {
        $_ -like 'resource show*--api-version 2024-03-01*'
    }).Count -ne 3) {
        throw 'Managed-environment location lookup did not pin the supported ARM API version.'
    }

    # A persistent failure must retain the Azure CLI diagnostic instead of hiding it.
    $script:resourceShowFailuresRemaining = 2
    $readFailure = $null
    try {
        Invoke-W365AzureCliRead `
            -Arguments @('resource', 'show', '--ids', '/subscriptions/s/resourceGroups/g/providers/Microsoft.App/managedEnvironments/e') `
            -MaxAttempts 2 `
            -RetryDelaySeconds 0 | Out-Null
    }
    catch {
        $readFailure = $_.Exception.Message
    }
    if ($null -eq $readFailure -or
        $readFailure -notlike '*after 2 attempt(s)*' -or
        $readFailure -notlike '*TooManyRequests*') {
        throw "Persistent Azure CLI read failure did not preserve actionable diagnostics: $readFailure"
    }

    # An absent container app must never block a first viewer deployment.
    $script:containerAppLocation = ''
    $script:managedEnvironmentLocation = 'eastus2'
    Initialize-W365ViewerRegionEnvironment `
        -EnvironmentName 'sample-dev' `
        -ManagedEnvironmentResourceId '/subscriptions/s/resourceGroups/g/providers/Microsoft.App/managedEnvironments/e' | Out-Null
}
finally {
    $env:VIEWER_IDENTITY_LOCATION = $previousIdentityLocationEnv
}

Write-Host 'Viewer region resolution offline test passed.'
