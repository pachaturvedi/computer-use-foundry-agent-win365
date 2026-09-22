#Requires -Version 7.4
# TestCategory: Platform
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'scripts\W365Provisioning.ps1')
$scriptPath = Join-Path $root 'scripts\Invoke-AzdUp.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "invoke-azd-up-$([guid]::NewGuid())"
$fakeAzdPath = Join-Path $tempRoot 'azd.cmd'
$callsPath = Join-Path $tempRoot 'calls.txt'
$environmentDirectory = Join-Path $tempRoot '.azure\sample-dev'
$failingSummaryPath = Join-Path $tempRoot 'Failing-Summary.ps1'
$destructiveSummaryPath = Join-Path $tempRoot 'Destructive-Summary.ps1'
$hangStartedPath = Join-Path $tempRoot 'hang-started.txt'
$hangSurvivedPath = Join-Path $tempRoot 'hang-survived.txt'
$previousCallsPath = $env:TEST_AZD_UP_CALLS_PATH
$previousEnvironmentPath = $env:TEST_AZD_UP_ENV_PATH
$previousPrompt = $env:TEST_AZD_UP_PROMPT
$previousSkipCompletion = $env:TEST_AZD_UP_SKIP_COMPLETION
$previousHang = $env:TEST_AZD_UP_HANG
$previousHangStartedPath = $env:TEST_AZD_UP_HANG_STARTED_PATH
$previousHangSurvivedPath = $env:TEST_AZD_UP_HANG_SURVIVED_PATH

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $environmentDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
        'ENABLE_W365="true"',
        'W365_ENABLED="true"',
        'DEPLOY_STATE="true"',
        'STATE_STORAGE_ACCOUNT_NAME="samplestorage"',
        'STATE_CONTAINER_NAME="desktop-state"',
        'SESSION_BLOB_URI="https://samplestorage.blob.core.windows.net/desktop-state/slot.json"',
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.example.test"'
    )
    Set-Content -LiteralPath $fakeAzdPath -Value @'
@echo off
echo %*>>"%TEST_AZD_UP_CALLS_PATH%"
if "%TEST_AZD_UP_HANG%"=="true" (
  echo started>"%TEST_AZD_UP_HANG_STARTED_PATH%"
  ping 127.0.0.1 -n 31 >nul
  echo survived>"%TEST_AZD_UP_HANG_SURVIVED_PATH%"
  exit /b 0
)
if "%TEST_AZD_UP_PROMPT%"=="true" (
  <nul set /p "=Type YES to continue: "
  ping 127.0.0.1 -n 3 >nul
  echo approved
)
echo   (^) Done: win365-desktop-agent
echo   - Agent playground (portal): https://portal.example.test/agent
echo   - Agent endpoint (responses): https://agent.example.test/responses
echo     For information on invoking the agent, see https://aka.ms/azd-agents-invoke
echo.
echo Set up an evaluation suite to measure quality and impact in one step with azd ai agent eval generate
echo.
echo Next:
echo   azd ai agent show win365-desktop-agent
echo   verify it's running
echo.
echo   azd ai agent invoke win365-desktop-agent ^'^<payload^>^'
echo   test the deployment
echo.
echo Windows 365 enablement started.
if not "%TEST_AZD_UP_SKIP_COMPLETION%"=="true" echo W365_AZD_UP_POSTUP_RUN_ID="%W365_AZD_UP_RUN_ID%">>"%TEST_AZD_UP_ENV_PATH%"
echo SUCCESS: Your application was provisioned and deployed to Azure in 1 minute 20 seconds.
echo   Provisioning: 58 seconds
echo   Deploying:    20 seconds
if "%TEST_AZD_UP_FAIL%"=="true" exit /b 23
'@
    Set-Content -LiteralPath $failingSummaryPath -Value @'
param([string]$RepositoryRoot, [string]$Environment)
Write-Host 'SUMMARY-SHOULD-NOT-BE-PRINTED'
throw 'Simulated summary failure.'
'@
    Set-Content -LiteralPath $destructiveSummaryPath -Value @'
param([string]$RepositoryRoot, [string]$Environment)
Write-Host 'SUMMARY-SHOULD-STAY-BUFFERED'
Remove-Item -LiteralPath (Join-Path $RepositoryRoot ".azure\$Environment\.env") -Force
'@
    $env:TEST_AZD_UP_CALLS_PATH = $callsPath
    $env:TEST_AZD_UP_ENV_PATH = Join-Path $environmentDirectory '.env'
    $env:TEST_AZD_UP_HANG_STARTED_PATH = $hangStartedPath
    $env:TEST_AZD_UP_HANG_SURVIVED_PATH = $hangSurvivedPath

    $output = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String

    if ($output -match 'For information on invoking the agent' -or
        $output -match 'Set up an evaluation suite' -or
        $output -match 'verify it''s running' -or
        $output -match 'test the deployment' -or
        $output -match 'Provisioning: 58 seconds' -or
        $output -match 'Deploying:\s+20 seconds') {
        throw "The wrapper exposed intermediate Foundry guidance: $output"
    }
    if ($output -notmatch 'Agent playground' -or
        $output -notmatch 'Agent endpoint' -or
        $output -notmatch 'Windows 365 enablement started' -or
        $output -notmatch 'Deployment result: sample-dev' -or
        $output -notmatch '(?m)^\s*Next:\s*$' -or
    $output -notmatch 'Run the repository invoice scenario in a fresh session' -or
        $output -notmatch 'SUCCESS: Complete sample installation finished') {
        throw "The wrapper hid deployment progress or the final result: $output"
    }
    if ($output.IndexOf('SUCCESS: Complete sample installation finished') -gt
    $output.IndexOf('Next:')) {
    throw "The final next steps were not printed after complete installation success: $output"
    }

    $call = Get-Content -LiteralPath $callsPath -Raw
    if ($call.Trim() -ne 'up --environment sample-dev') {
        throw "The wrapper invoked unexpected azd arguments: $call"
    }
    $completedValues = Read-AzdEnvironmentFile -Path (Join-Path $environmentDirectory '.env')
    if ([string]::IsNullOrWhiteSpace([string]$completedValues['W365_AZD_UP_COMPLETED_RUN_ID']) -or
        [string]$completedValues['W365_AZD_UP_COMPLETED_RUN_ID'] -ne
        [string]$completedValues['W365_AZD_UP_POSTUP_RUN_ID']) {
        throw 'The wrapper did not persist a matching run-specific completion handshake.'
    }

    $promptOutputPath = Join-Path $tempRoot 'prompt-output.txt'
    $promptErrorPath = Join-Path $tempRoot 'prompt-error.txt'
    $env:TEST_AZD_UP_PROMPT = 'true'
    $promptProcess = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @(
            '-NoProfile',
            '-File', $scriptPath,
            '-Environment', 'sample-dev',
            '-ConfirmResourceChanges',
            '-AzdPath', $fakeAzdPath,
            '-RepositoryRoot', $tempRoot
        ) `
        -RedirectStandardOutput $promptOutputPath `
        -RedirectStandardError $promptErrorPath `
        -NoNewWindow `
        -PassThru
    Start-Sleep -Milliseconds 750
    $earlyOutput = if (Test-Path -LiteralPath $promptOutputPath) {
        Get-Content -LiteralPath $promptOutputPath -Raw
    }
    else {
        ''
    }
    if ($earlyOutput -notmatch 'Type YES to continue:') {
        $promptProcess.Kill($true)
        throw 'The wrapper buffered a non-newline interactive prompt.'
    }
    $promptProcess.WaitForExit()
    if ($promptProcess.ExitCode -ne 0) {
        $promptError = Get-Content -LiteralPath $promptErrorPath -Raw
        throw "The prompt-streaming wrapper process failed: $promptError"
    }
    $env:TEST_AZD_UP_PROMPT = $null

    $cancellationOutputPath = Join-Path $tempRoot 'cancellation-output.txt'
    $cancellationErrorPath = Join-Path $tempRoot 'cancellation-error.txt'
    $env:TEST_AZD_UP_HANG = 'true'
    $cancellationProcess = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @(
            '-NoProfile',
            '-File', $scriptPath,
            '-Environment', 'sample-dev',
            '-ConfirmResourceChanges',
            '-AzdPath', $fakeAzdPath,
            '-RepositoryRoot', $tempRoot
        ) `
        -RedirectStandardOutput $cancellationOutputPath `
        -RedirectStandardError $cancellationErrorPath `
        -NoNewWindow `
        -PassThru
    $cancellationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (!(Test-Path -LiteralPath $hangStartedPath) -and
        [DateTimeOffset]::UtcNow -lt $cancellationDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path -LiteralPath $hangStartedPath)) {
        $cancellationProcess.Kill($true)
        throw 'The fake azd provider did not start its cancellation scenario.'
    }
    Stop-Process -Id $cancellationProcess.Id
    $cancellationProcess.WaitForExit()
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $hangSurvivedPath) {
        throw 'The azd provider survived termination of the wrapper host.'
    }
    $cancellationOutput = if (Test-Path -LiteralPath $cancellationOutputPath) {
        Get-Content -LiteralPath $cancellationOutputPath -Raw
    }
    else {
        ''
    }
    $cancellationValues = Read-AzdEnvironmentFile -Path (Join-Path $environmentDirectory '.env')
    if ($cancellationOutput -match 'SUCCESS:' -or
        ![string]::IsNullOrWhiteSpace([string]$cancellationValues['W365_AZD_UP_COMPLETED_RUN_ID'])) {
        throw 'Wrapper cancellation emitted success or persisted completion state.'
    }
    $env:TEST_AZD_UP_HANG = $null

    Remove-Item -LiteralPath $callsPath
    & $scriptPath `
        -Environment 'sample-dev' `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot `
        -WhatIf *> $null
    if (Test-Path -LiteralPath $callsPath) {
        throw 'The wrapper executed azd up during a WhatIf preview.'
    }

    (Get-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Raw).
        Replace('W365_ENABLED="true"', 'W365_ENABLED="false"') |
        Set-Content -LiteralPath (Join-Path $environmentDirectory '.env')
    $incompleteFailed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $incompleteFailed = $_.Exception.Message -match 'complete sample installation is unfinished'
    }
    if (!$incompleteFailed) {
        throw 'The wrapper accepted azd core success after W365 installation was interrupted.'
    }

    (Get-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Raw).
        Replace('W365_ENABLED="false"', 'W365_ENABLED="true"') |
        Set-Content -LiteralPath (Join-Path $environmentDirectory '.env')
    $env:TEST_AZD_UP_SKIP_COMPLETION = 'true'
    $staleCompletionFailed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $staleCompletionFailed = $_.Exception.Message -match 'current post-deployment workflow did not complete'
    }
    if (!$staleCompletionFailed) {
        throw 'The wrapper accepted stale persisted state without a current-run post-deployment handshake.'
    }
    $env:TEST_AZD_UP_SKIP_COMPLETION = $null

    $summaryFailureOutput = try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot `
            -DeploymentSummaryScriptPath $failingSummaryPath *>&1 | Out-String
    }
    catch {
        $_ | Out-String
    }
    if ($summaryFailureOutput -match 'SUCCESS: Complete sample installation finished' -or
        $summaryFailureOutput -match 'SUMMARY-SHOULD-NOT-BE-PRINTED') {
        throw "The wrapper emitted success-shaped output before summary validation: $summaryFailureOutput"
    }

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
        'ENABLE_W365="true"',
        'W365_ENABLED="true"',
        'DEPLOY_STATE="true"',
        'STATE_STORAGE_ACCOUNT_NAME="samplestorage"',
        'STATE_CONTAINER_NAME="desktop-state"',
        'SESSION_BLOB_URI="https://samplestorage.blob.core.windows.net/desktop-state/slot.json"',
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.example.test"'
    )
    $persistenceFailureOutput = try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot `
            -DeploymentSummaryScriptPath $destructiveSummaryPath *>&1 | Out-String
    }
    catch {
        $_ | Out-String
    }
    if ($persistenceFailureOutput -match 'SUCCESS: Complete sample installation finished' -or
        $persistenceFailureOutput -match 'SUMMARY-SHOULD-STAY-BUFFERED') {
        throw "The wrapper emitted buffered final output before completion persistence: $persistenceFailureOutput"
    }

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="5"',
        'ENABLE_W365="false"',
        'W365_ENABLED="false"',
        'DEPLOY_STATE="false"',
        'DEPLOY_VIEWER="false"'
    )
    $bootstrapOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    if ($bootstrapOutput -notmatch 'SUCCESS: Foundry bootstrap deployment finished' -or
        $bootstrapOutput -notmatch 'Verify the W365-disabled bootstrap agent' -or
        $bootstrapOutput -notmatch 'azd env set ENABLE_W365 true --environment sample-dev' -or
        $bootstrapOutput -match 'Run the repository invoice scenario') {
        throw "The wrapper reported incorrect Foundry-only completion guidance: $bootstrapOutput"
    }

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
        'ENABLE_W365="true"',
        'W365_ENABLED="true"',
        'DEPLOY_STATE="true"',
        'STATE_STORAGE_ACCOUNT_NAME="samplestorage"',
        'STATE_CONTAINER_NAME="desktop-state"',
        'SESSION_BLOB_URI="https://samplestorage.blob.core.windows.net/desktop-state/slot.json"',
        'DEPLOY_VIEWER="true"',
        'VIEWER_PUBLIC_URL="https://viewer.example.test"'
    )
    $env:TEST_AZD_UP_FAIL = 'true'
    $failed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $failed = $_.Exception.Message -match 'exit code 23'
    }
    if (!$failed) {
        throw 'The wrapper did not propagate the azd up failure.'
    }

    Write-Host 'azd up customer-output wrapper offline test passed.'
}
finally {
    $env:TEST_AZD_UP_CALLS_PATH = $previousCallsPath
    $env:TEST_AZD_UP_ENV_PATH = $previousEnvironmentPath
    $env:TEST_AZD_UP_PROMPT = $previousPrompt
    $env:TEST_AZD_UP_SKIP_COMPLETION = $previousSkipCompletion
    $env:TEST_AZD_UP_HANG = $previousHang
    $env:TEST_AZD_UP_HANG_STARTED_PATH = $previousHangStartedPath
    $env:TEST_AZD_UP_HANG_SURVIVED_PATH = $previousHangSurvivedPath
    Remove-Item Env:\TEST_AZD_UP_FAIL -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
