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

$script:graphRequests = @()
$script:graphResponses = [Collections.Generic.Queue[object]]::new()

function Invoke-MgGraphRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$OutputType,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType
    )

    $script:graphRequests += , @{
        Method = $Method
        Uri = $Uri
        OutputType = $OutputType
        Headers = $Headers
        Body = $Body
        ContentType = $ContentType
    }

    if ($script:graphResponses.Count -eq 0) {
        throw "No mocked Graph response is available for $Method $Uri."
    }

    return $script:graphResponses.Dequeue()
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
    $script:graphRequests = @()
    $script:graphResponses = [Collections.Generic.Queue[object]]::new()
}

. (Join-Path $root 'scripts\GraphSignIn.ps1')

# Shared Graph requests reject non-Graph origins, serialize mutation bodies,
# paginate exactly once per cursor, and fail closed on ambiguous results.
Reset-GraphMocks
$script:graphResponses.Enqueue(@{ id = 'created' })
$created = Invoke-W365GraphRequest -Method POST -Path 'v1.0/example' -Body @{ displayName = 'sample' }
if ($created.id -ne 'created') {
    throw 'The shared Graph request did not return the mocked response.'
}
$request = $script:graphRequests[0]
if ($request.Uri -ne 'https://graph.microsoft.com/v1.0/example' -or
    $request.Headers['OData-Version'] -ne '4.0' -or
    $request.ContentType -ne 'application/json' -or
    $request.Body -notmatch '"displayName":"sample"') {
    throw 'The shared Graph request did not preserve the expected request contract.'
}

$threw = $false
try {
    Invoke-W365GraphRequest -Method GET -Path 'https://example.test/v1.0/users' | Out-Null
}
catch {
    $threw = $_.Exception.Message -match 'unexpected origin'
}
if (!$threw) {
    throw 'The shared Graph request accepted a non-Graph origin.'
}

Reset-GraphMocks
$script:graphResponses.Enqueue(@{
        value = @(@{ id = 'first' })
        '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/example?page=2'
    })
$script:graphResponses.Enqueue(@{
        value = @(@{ id = 'second' })
    })
$items = @(Get-W365GraphCollection -Path 'v1.0/example')
if ($items.Count -ne 2 -or $items[0].id -ne 'first' -or $items[1].id -ne 'second') {
    throw 'The shared Graph collection helper did not return every page.'
}

Reset-GraphMocks
$repeatedCursor = 'https://graph.microsoft.com/v1.0/example?page=1'
$script:graphResponses.Enqueue(@{
        value = @()
        '@odata.nextLink' = $repeatedCursor
    })
$threw = $false
try {
    Get-W365GraphCollection -Path $repeatedCursor | Out-Null
}
catch {
    $threw = $_.Exception.Message -match 'Repeated Graph pagination cursor'
}
if (!$threw) {
    throw 'The shared Graph collection helper accepted a repeated pagination cursor.'
}

Reset-GraphMocks
$script:graphResponses.Enqueue(@{
        value = @(@{ id = 'partial' })
        '@odata.nextLink' = '   '
    })
$threw = $false
try {
    Get-W365GraphCollection -Path 'v1.0/example' | Out-Null
}
catch {
    $threw = $_.Exception.Message -match 'whitespace-only continuation cursor'
}
if (!$threw) {
    throw 'The shared Graph collection helper treated a whitespace continuation cursor as successful completion.'
}

if ($null -ne (Select-W365GraphSingleResult -Items @() -Label 'empty result')) {
    throw 'The shared single-result helper did not return null for an empty result.'
}
if ((Select-W365GraphSingleResult -Items @(@{ id = 'only' }) -Label 'single result').id -ne 'only') {
    throw 'The shared single-result helper did not return the only match.'
}
$threw = $false
try {
    Select-W365GraphSingleResult `
        -Items @(@{ id = 'one' }, @{ id = 'two' }) `
        -Label 'duplicate result' | Out-Null
}
catch {
    $threw = $_.Exception.Message -match 'Ambiguous duplicate result'
}
if (!$threw) {
    throw 'The shared single-result helper accepted ambiguous matches.'
}

$diagnosticContracts = @{
    'Setup-W365.ps1' = @(
        'Graph pagination returned an unexpected origin.',
        'Resolve manually; no arbitrary object will be reused.'
    )
    'Remove-W365Resources.ps1' = @(
        'Graph request resolved to an unexpected origin.',
        'Resolve manually before rerunning cleanup.'
    )
    'Register-W365BlueprintCertificate.ps1' = @(
        'Graph request resolved to an unexpected origin.',
        'Resolve manually; no arbitrary object will be reused.'
    )
}
foreach ($entry in $diagnosticContracts.GetEnumerator()) {
    $scriptText = Get-Content -LiteralPath (Join-Path $root "scripts\$($entry.Key)") -Raw
    foreach ($message in $entry.Value) {
        if ($scriptText -notmatch [regex]::Escape($message)) {
            throw "$($entry.Key) no longer preserves Graph diagnostic '$message'."
        }
    }
}

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

# Device-code guidance names the minimum access for the step instead of implying tenant admin.
$guidance = (Write-W365DeviceCodeGuidance `
        -Purpose 'to register the blueprint certificate' `
        -RequiredAccess 'owner of the agent identity blueprint' `
        -DeviceCodeMaxAttempts 3 6>&1) -join "`n"

if ($guidance -notmatch 'owner of the agent identity blueprint') {
    throw 'The device-code guidance did not state the minimum required access.'
}
if ($guidance -match 'administrator sign-in is required') {
    throw 'The device-code guidance still asserts that administrator sign-in is required.'
}
if ($guidance -match 'authorized tenant administrator') {
    throw 'The device-code guidance still directs the operator to sign in as a tenant administrator.'
}
if ($guidance -notmatch 'up to 3 times') {
    throw 'The device-code guidance did not report the bounded retry count.'
}

# The minimum access is a required, caller-supplied statement; it is never guessed centrally.
$requiredAccessParameter = (Get-Command Write-W365DeviceCodeGuidance).Parameters['RequiredAccess']
if ($null -eq $requiredAccessParameter) {
    throw 'Write-W365DeviceCodeGuidance does not accept a RequiredAccess statement.'
}
$isMandatory = @($requiredAccessParameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
if (!$isMandatory) {
    throw 'RequiredAccess is optional, so a caller could prompt without stating the minimum access.'
}

# Every device-code prompt in the repository states its own minimum access.
$guidanceCallers = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' |
        Where-Object { $_.Name -ne 'GraphSignIn.ps1' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Write-W365DeviceCodeGuidance' })
if ($guidanceCallers.Count -eq 0) {
    throw 'No device-code guidance callers were found; the coverage check is not exercising anything.'
}
foreach ($caller in $guidanceCallers) {
    $text = Get-Content -LiteralPath $caller.FullName -Raw
    foreach ($call in [regex]::Matches($text, 'Write-W365DeviceCodeGuidance(?:[^\r\n]*`\r?\n)*[^\r\n]*')) {
        if ($call.Value -notmatch '-RequiredAccess') {
            throw "$($caller.Name) prompts for a device code without stating the minimum required access."
        }
    }
}


# Connect-MgGraph emits the device-code prompt on the success stream, so piping it
# to Out-Null silently hides the code and the operator can never sign in. Run the
# real helper in a child process and assert the prompt still reaches stdout.
$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "graph-signin-probe-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
try {
    $probeScript = Join-Path $probeRoot 'probe.ps1'
    $probeTemplate = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Connect-MgGraph { Write-Output 'DEVICE-CODE-PROMPT-MARKER' }
function Get-MgContext {
    return [pscustomobject]@{ TenantId = 'probe-tenant'; AuthType = 'Delegated'; Scopes = @('User.Read') }
}
. '__MODULE__'
$result = Connect-W365GraphContext -ConnectParameters @{ Scopes = @('User.Read') } -UseDeviceCode -DeviceCodeMaxAttempts 1
if (@($result).Count -ne 1) { throw 'PROBE-FAILED: the sign-in prompt leaked into the returned value.' }
if ($result.AuthType -ne 'Delegated') { throw 'PROBE-FAILED: the Graph context was not returned.' }
'@
    $modulePath = Join-Path $root 'scripts\GraphSignIn.ps1'
    $probeTemplate.Replace('__MODULE__', $modulePath.Replace("'", "''")) |
        Set-Content -Path $probeScript -Encoding utf8

    $probeOut = Join-Path $probeRoot 'out.txt'
    $probeErr = Join-Path $probeRoot 'err.txt'
    $probe = Start-Process pwsh `
        -ArgumentList '-NoProfile', '-NonInteractive', '-File', $probeScript `
        -RedirectStandardOutput $probeOut `
        -RedirectStandardError $probeErr `
        -PassThru -WindowStyle Hidden
    if (!$probe.WaitForExit(60000)) {
        $probe.Kill()
        throw 'The device-code visibility probe did not complete.'
    }

    $probeStdout = (Get-Content $probeOut -Raw -ErrorAction SilentlyContinue)
    $probeStderr = (Get-Content $probeErr -Raw -ErrorAction SilentlyContinue)
    if ($probe.ExitCode -ne 0) {
        throw "The device-code visibility probe failed: $probeStderr"
    }
    if ([string]::IsNullOrWhiteSpace($probeStdout) -or $probeStdout -notmatch 'DEVICE-CODE-PROMPT-MARKER') {
        throw 'The Microsoft Graph device-code prompt was suppressed instead of shown to the operator.'
    }
}
finally {
    Remove-Item $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Test-GraphSignInOffline passed.'
