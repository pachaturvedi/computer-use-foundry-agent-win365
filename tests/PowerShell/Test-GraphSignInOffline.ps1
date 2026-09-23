#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)

$script:connectCalls = @()
$script:failures = @()
$script:contextToReturn = $null

function Connect-MgGraph {
    $arguments = @($args)
    $captured = @{}
    for ($index = 0; $index -lt $arguments.Count - 1; $index += 2) {
        $captured[([string]$arguments[$index]).TrimStart('-').TrimEnd(':')] = $arguments[$index + 1]
    }
    $script:connectCalls += , $captured

    $callIndex = $script:connectCalls.Count - 1
    if ($callIndex -lt $script:failures.Count -and $script:failures[$callIndex]) {
        throw $script:failures[$callIndex]
    }
}

function Test-UsedDeviceCode {
    param([Parameter(Mandatory)][hashtable]$Call)

    return $Call.ContainsKey('UseDeviceCode') -and [bool]$Call.UseDeviceCode
}

function Get-MgContext {
    return $script:contextToReturn
}

function Reset-GraphMocks {
    param([string[]]$Failures = @())

    $script:connectCalls = @()
    $script:failures = $Failures
    $script:contextToReturn = [pscustomobject]@{
        TenantId = '11111111-1111-1111-1111-111111111111'
        AuthType = 'Delegated'
        Scopes   = @('CloudPC.Read.All')
    }
}

. (Join-Path $root 'scripts\GraphSignIn.ps1')

$timeout = 'Authentication timed out after 120 seconds due to inactivity. Please try again.'
$timeoutAlternateWindow = 'Authentication timed out after 60 seconds due to inactivity.'
$connectParameters = @{ TenantId = '11111111-1111-1111-1111-111111111111'; Scopes = @('CloudPC.Read.All') }

# A device-code timeout is retried with a fresh code until it succeeds.
Reset-GraphMocks -Failures @($timeout, $timeout)
$context = Connect-W365GraphContext -ConnectParameters $connectParameters -UseDeviceCode -DeviceCodeMaxAttempts 3
if ($script:connectCalls.Count -ne 3) {
    throw "Expected 3 device-code attempts, saw $($script:connectCalls.Count)."
}
if ($null -eq $context -or $context.AuthType -ne 'Delegated') {
    throw 'The recovered device-code sign-in did not return the Graph context.'
}

# The retry matcher tolerates a different reported inactivity window.
Reset-GraphMocks -Failures @($timeoutAlternateWindow)
Connect-W365GraphContext -ConnectParameters $connectParameters -UseDeviceCode -DeviceCodeMaxAttempts 2 | Out-Null
if ($script:connectCalls.Count -ne 2) {
    throw 'A device-code timeout reporting a different window was not retried.'
}

# Device-code sign-in requests a fresh code rather than reusing connect parameters.
if (!(Test-UsedDeviceCode -Call $script:connectCalls[1])) {
    throw 'The device-code retry did not request device-code sign-in.'
}

# Attempts are bounded and the final timeout surfaces to the caller.
Reset-GraphMocks -Failures @($timeout, $timeout, $timeout)
$threw = $false
try {
    Connect-W365GraphContext -ConnectParameters $connectParameters -UseDeviceCode -DeviceCodeMaxAttempts 3 | Out-Null
}
catch {
    $threw = $true
}
if (!$threw) { throw 'Exhausting the device-code attempts did not fail.' }
if ($script:connectCalls.Count -ne 3) {
    throw "Device-code attempts were not bounded at 3; saw $($script:connectCalls.Count)."
}

# A non-timeout failure is never retried, so real errors stay fast and visible.
Reset-GraphMocks -Failures @('AADSTS65001: The user or administrator has not consented.')
$threw = $false
try {
    Connect-W365GraphContext -ConnectParameters $connectParameters -UseDeviceCode -DeviceCodeMaxAttempts 3 | Out-Null
}
catch {
    $threw = $true
}
if (!$threw) { throw 'A consent failure was swallowed instead of surfaced.' }
if ($script:connectCalls.Count -ne 1) {
    throw "A non-timeout failure was retried; saw $($script:connectCalls.Count) attempts."
}

# Interactive sign-in without device code connects exactly once.
Reset-GraphMocks
Connect-W365GraphContext -ConnectParameters $connectParameters | Out-Null
if ($script:connectCalls.Count -ne 1) {
    throw 'Interactive sign-in did not connect exactly once.'
}
if (Test-UsedDeviceCode -Call $script:connectCalls[0]) {
    throw 'Interactive sign-in unexpectedly requested a device code.'
}

# Opt-in fallback retries with device code, and that fallback is itself retried on timeout.
Reset-GraphMocks -Failures @('Interactive browser sign-in failed.', $timeout)
Connect-W365GraphContext -ConnectParameters $connectParameters -FallbackToDeviceCode -DeviceCodeMaxAttempts 3 | Out-Null
if ($script:connectCalls.Count -ne 3) {
    throw "The device-code fallback was not retried; saw $($script:connectCalls.Count) attempts."
}
if (Test-UsedDeviceCode -Call $script:connectCalls[0]) {
    throw 'The fallback path used a device code before interactive sign-in was attempted.'
}
if (!(Test-UsedDeviceCode -Call $script:connectCalls[1])) {
    throw 'The fallback did not switch to device-code sign-in.'
}

# Without the opt-in, an interactive failure is not silently converted to a device-code prompt.
Reset-GraphMocks -Failures @('Interactive browser sign-in failed.')
$threw = $false
try {
    Connect-W365GraphContext -ConnectParameters $connectParameters | Out-Null
}
catch {
    $threw = $true
}
if (!$threw) { throw 'An interactive failure was not surfaced.' }
if ($script:connectCalls.Count -ne 1) {
    throw 'An unrequested device-code fallback was attempted.'
}

$tenant = [guid]'11111111-1111-1111-1111-111111111111'
$goodContext = [pscustomobject]@{
    TenantId = $tenant.ToString()
    AuthType = 'Delegated'
    Scopes   = @('CloudPC.Read.All', 'User.Read')
}

if (!(Test-GraphContext -Context $goodContext -RequiredTenantId $tenant -RequiredScopes @('CloudPC.Read.All'))) {
    throw 'A satisfying Graph context was rejected.'
}
if (!(Test-GraphContext -Context $goodContext -RequiredTenantId ([guid]::Empty) -RequiredScopes @('CloudPC.Read.All'))) {
    throw 'An empty required tenant was not treated as any tenant.'
}
if (Test-GraphContext -Context $null -RequiredTenantId $tenant -RequiredScopes @('CloudPC.Read.All')) {
    throw 'A missing Graph context was accepted.'
}
if (Test-GraphContext -Context $goodContext -RequiredTenantId ([guid]'22222222-2222-2222-2222-222222222222') -RequiredScopes @('CloudPC.Read.All')) {
    throw 'A context from another tenant was accepted.'
}
if (Test-GraphContext -Context $goodContext -RequiredTenantId $tenant -RequiredScopes @('CloudPC.ReadWrite.All')) {
    throw 'A context missing a required scope was accepted.'
}

$appOnlyContext = [pscustomobject]@{
    TenantId = $tenant.ToString()
    AuthType = 'AppOnly'
    Scopes   = @('CloudPC.Read.All')
}
if (Test-GraphContext -Context $appOnlyContext -RequiredTenantId $tenant -RequiredScopes @('CloudPC.Read.All')) {
    throw 'An app-only context was accepted where delegated access is required.'
}

Write-Host 'Test-GraphSignInOffline passed.'

