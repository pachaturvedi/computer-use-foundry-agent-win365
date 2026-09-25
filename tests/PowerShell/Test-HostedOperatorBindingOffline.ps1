#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$deploymentScriptPath = Join-Path $root 'scripts\Invoke-AzdDeployment.ps1'
$deploymentScript = Get-Content -LiteralPath $deploymentScriptPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $deploymentScript,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw "Invoke-AzdDeployment.ps1 did not parse: $($parseErrors.Message -join '; ')"
}

$functionNames = @(
    'Get-HostedOperatorBindingFingerprint',
    'Test-HostedAgentSmokeSucceeded',
    'Invoke-HostedAgentSmokeTest'
)
foreach ($functionName in $functionNames) {
    $functionAst = $ast.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        },
        $true
    )
    if ($null -eq $functionAst) {
        throw "Expected function '$functionName' was not found."
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:fingerprint = 'sha256:' + ('a' * 64)
$script:binding = 'pending'
$script:version = '1'
$script:invokeResults = @()
$script:invokeCount = 0
$script:invokeCommands = [Collections.Generic.List[string]]::new()
$script:azdCalls = [Collections.Generic.List[string]]::new()
$savedHostedAllowedUserId = $env:HOSTED_ALLOWED_USER_ID
$SmokeInvoke = $true
$SmokeInvokePrompt = 'offline smoke'
$ConfirmResourceChanges = $true
$environmentName = 'sample-dev'

function Write-DeploymentEvent {
    param([string]$Kind, [string]$Message)
}

function Get-AzdOptionalValue {
    param([string]$Name)

    switch ($Name) {
        'AGENT_WIN365_DESKTOP_AGENT_VERSION' { return $script:version }
        'HOSTED_ALLOWED_USER_ID' { return $script:binding }
        default { return '' }
    }
}

function Invoke-Azd {
    param([string[]]$Arguments)

    $command = $Arguments -join ' '
    $script:azdCalls.Add($command)
    if ($command -match '^env set HOSTED_ALLOWED_USER_ID (\S+) --environment sample-dev$') {
        $script:binding = $Matches[1]
    }
    elseif ($command -eq 'deploy win365-desktop-agent --no-prompt') {
        $script:version = ([int]$script:version + 1).ToString()
    }
}

function Invoke-TestAzd {
    $script:invokeCommands.Add(($args -join ' '))
    $result = $script:invokeResults[$script:invokeCount]
    $script:invokeCount++
    $global:LASTEXITCODE = $result.ExitCode
    $result.Output
}

$azd = [pscustomobject]@{
    Path = (Get-Command Invoke-TestAzd)
}

function Reset-TestState {
    $script:binding = 'pending'
    $script:version = '1'
    $script:invokeResults = @()
    $script:invokeCount = 0
    $script:invokeCommands.Clear()
    $script:azdCalls.Clear()
    $env:HOSTED_ALLOWED_USER_ID = 'pending'
}

try {
    Reset-TestState
    $script:invokeResults = @(
        @{
            ExitCode = 1
            Output = "ERROR: HTTP 403`n" +
                '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $script:fingerprint + '"}}'
        },
        @{ ExitCode = 0; Output = 'OK' }
    )
    Invoke-HostedAgentSmokeTest
    if ($script:binding -ne $script:fingerprint -or
        $env:HOSTED_ALLOWED_USER_ID -ne $script:fingerprint -or
        $script:version -ne '2' -or
        $script:invokeCount -ne 2 -or
        @($script:invokeCommands | Where-Object {
                $_ -eq 'ai agent invoke win365-desktop-agent --version 1 --new-session --timeout 120 offline smoke' -or
                $_ -eq 'ai agent invoke win365-desktop-agent --version 2 --new-session --timeout 120 offline smoke'
            }).Count -ne 2 -or
        @($script:azdCalls | Where-Object { $_ -eq 'deploy win365-desktop-agent --no-prompt' }).Count -ne 1 -or
        @($script:azdCalls | Where-Object { $_ -eq 'ai agent doctor' }).Count -ne 1) {
        throw 'Pending operator binding was not persisted, refreshed, redeployed once, and retried successfully.'
    }

    Reset-TestState
    $script:binding = 'sha256:' + ('b' * 64)
    $script:invokeResults = @(
        @{
            ExitCode = 1
            Output = '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $script:fingerprint + '"}}'
        }
    )
    $existingBindingRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $existingBindingRejected = $_.Exception.Message -match 'already configured'
    }
    if (!$existingBindingRejected -or $script:azdCalls.Count -ne 0) {
        throw 'An existing concrete operator binding was not preserved.'
    }

    Reset-TestState
    $script:invokeResults = @(
        @{
            ExitCode = 1
            Output = '{"error":{"code":"operator_binding_required","fingerprint":"sha256:not-valid"}}'
        }
    )
    $malformedRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $malformedRejected = $_.Exception.Message -match 'single valid sha256 fingerprint'
    }
    if (!$malformedRejected -or $script:azdCalls.Count -ne 0) {
        throw 'A malformed operator fingerprint was not rejected before mutation.'
    }

    Reset-TestState
    $otherFingerprint = 'sha256:' + ('c' * 64)
    $script:invokeResults = @(
        @{
            ExitCode = 1
            Output = '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $script:fingerprint + '"}}' + "`n" +
                '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $otherFingerprint + '"}}'
        }
    )
    $ambiguousRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $ambiguousRejected = $_.Exception.Message -match 'response was ambiguous'
    }
    if (!$ambiguousRejected -or $script:azdCalls.Count -ne 0) {
        throw 'Ambiguous operator fingerprints were not rejected before mutation.'
    }

    Reset-TestState
    $script:invokeResults = @(
        @{ ExitCode = 1; Output = '{"status":"failed"}' + "`n" + 'ERROR: HTTP 403 unrelated_application_error' }
    )
    $unrelatedFailureRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $unrelatedFailureRejected = $_.Exception.Message -match 'failed without a valid operator-binding response'
    }
    if (!$unrelatedFailureRejected -or
        $script:binding -ne 'pending' -or
        $script:azdCalls.Count -ne 0) {
        throw 'An unrelated application rejection was incorrectly accepted as healthy.'
    }

    Reset-TestState
    $script:invokeResults = @(
        @{
            ExitCode = 1
            Output = '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $script:fingerprint + '"}}'
        },
        @{
            ExitCode = 1
            Output = '{"error":{"code":"operator_binding_required","fingerprint":"' +
                $script:fingerprint + '"}}'
        }
    )
    $repeatedBindingRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $repeatedBindingRejected = $_.Exception.Message -match 'still required after the one permitted'
    }
    if (!$repeatedBindingRejected -or
        @($script:azdCalls | Where-Object { $_ -eq 'deploy win365-desktop-agent --no-prompt' }).Count -ne 1) {
        throw 'Repeated operator binding did not stop after one redeployment.'
    }

    Reset-TestState
    $script:invokeResults = @(
        @{
            ExitCode = 0
            Output = @'
Agent: win365-desktop-agent (remote)
[win365-desktop-agent] desktop_state_error: No free W365 sessions are currently available.
'@
        }
    )
    $unexpectedResponseRejected = $false
    try {
        Invoke-HostedAgentSmokeTest
    }
    catch {
        $unexpectedResponseRejected = $_.Exception.Message -match 'did not return the expected single-word OK'
    }
    if (!$unexpectedResponseRejected -or $script:azdCalls.Count -ne 0) {
        throw 'An exit-zero application error was incorrectly accepted as a successful deployment smoke test.'
    }

    foreach ($case in @(
        @{
            Label = 'bare OK'
            Output = 'OK'
            Expected = $true
        },
        @{
            Label = 'azd metadata with one exact agent OK'
            Output = "Agent: win365-desktop-agent (remote)`nMessage: smoke`n[win365-desktop-agent] OK"
            Expected = $true
        },
        @{
            Label = 'agent OK plus application error'
            Output = "[win365-desktop-agent] OK`n[win365-desktop-agent] desktop_state_error: no capacity"
            Expected = $false
        },
        @{
            Label = 'contradictory agent responses'
            Output = "[win365-desktop-agent] NOT OK`n[win365-desktop-agent] OK"
            Expected = $false
        }
    )) {
        $actual = Test-HostedAgentSmokeSucceeded -InvocationOutput $case.Output
        if ($actual -ne $case.Expected) {
            throw "Smoke response validation failed for $($case.Label)."
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'HOSTED_ALLOWED_USER_ID',
        $savedHostedAllowedUserId,
        'Process')
}

Write-Host 'Hosted operator binding offline checks passed.'
