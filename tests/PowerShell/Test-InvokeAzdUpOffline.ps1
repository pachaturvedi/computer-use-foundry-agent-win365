#Requires -Version 7.4
# TestCategory: Offline
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
$previousCallsPath = $env:TEST_AZD_UP_CALLS_PATH
$previousEnvironmentPath = $env:TEST_AZD_UP_ENV_PATH
$previousPrompt = $env:TEST_AZD_UP_PROMPT
$previousSkipCompletion = $env:TEST_AZD_UP_SKIP_COMPLETION

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
    $env:TEST_AZD_UP_CALLS_PATH = $callsPath
    $env:TEST_AZD_UP_ENV_PATH = Join-Path $environmentDirectory '.env'

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
    Remove-Item Env:\TEST_AZD_UP_FAIL -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
