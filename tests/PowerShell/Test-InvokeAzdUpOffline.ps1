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
$complexFakeAzdPath = Join-Path $tempRoot 'fake azd & (test) % ! Ω.cmd'
$callsPath = Join-Path $tempRoot 'calls.txt'
$environmentDirectory = Join-Path $tempRoot '.azure\sample-dev'
$complexEnvironment = 'sample dev & (test) % ! Ω'
$complexEnvironmentDirectory = Join-Path $tempRoot ".azure\$complexEnvironment"
$failingSummaryPath = Join-Path $tempRoot 'Failing-Summary.ps1'
$destructiveSummaryPath = Join-Path $tempRoot 'Destructive-Summary.ps1'
$unicodeValuePath = Join-Path $tempRoot 'unicode-value.txt'
$launchPidPath = Join-Path $tempRoot 'launch-pid.txt'
$hangStartedPath = Join-Path $tempRoot 'hang-started.txt'
$hangChildPidPath = Join-Path $tempRoot 'hang-child-pid.txt'
$hangSurvivedPath = Join-Path $tempRoot 'hang-survived.txt'
$pipeHolderPidPath = Join-Path $tempRoot 'pipe-holder-pid.txt'
$pipeWriterPidPath = Join-Path $tempRoot 'pipe-writer-pid.txt'
$previousTestHook = $env:WIN365_SAMPLE_INVOKE_AZD_UP_TEST_HOOK
$previousCallsPath = $env:TEST_AZD_UP_CALLS_PATH
$previousEnvironmentPath = $env:TEST_AZD_UP_ENV_PATH
$previousPrompt = $env:TEST_AZD_UP_PROMPT
$previousSkipCompletion = $env:TEST_AZD_UP_SKIP_COMPLETION
$previousHang = $env:TEST_AZD_UP_HANG
$previousHangStartedPath = $env:TEST_AZD_UP_HANG_STARTED_PATH
$previousHangChildPidPath = $env:TEST_AZD_UP_HANG_CHILD_PID_PATH
$previousHangSurvivedPath = $env:TEST_AZD_UP_HANG_SURVIVED_PATH
$previousIncompleteRedeploy = $env:TEST_AZD_UP_INCOMPLETE_REDEPLOY
$previousUnicodePath = $env:TEST_AZD_UP_UNICODE_PATH
$previousUnicodeValue = $env:TEST_AZD_UP_UNICODE_VALUE
$previousLaunchPidPath = $env:TEST_AZD_UP_LAUNCH_PID_PATH
$previousLaunchDelay = $env:TEST_AZD_UP_LAUNCH_DELAY_MILLISECONDS
$previousForceInvalidStdin = $env:TEST_AZD_UP_FORCE_INVALID_STDIN
$previousStderrGuidance = $env:TEST_AZD_UP_STDERR_GUIDANCE
$previousRequireEof = $env:TEST_AZD_UP_REQUIRE_EOF
$previousExecutionFailure = $env:TEST_AZD_UP_EXECUTION_FAILURE
$previousTerminateFailure = $env:TEST_AZD_UP_TERMINATE_FAILURE
$previousDisposeFailure = $env:TEST_AZD_UP_DISPOSE_FAILURE
$previousPreserveMarkers = $env:TEST_AZD_UP_PRESERVE_MARKERS
$previousPipeHolder = $env:TEST_AZD_UP_PIPE_HOLDER
$previousPipeHolderPidPath = $env:TEST_AZD_UP_PIPE_HOLDER_PID_PATH
$previousPipeWriter = $env:TEST_AZD_UP_PIPE_WRITER
$previousPipeWriterPidPath = $env:TEST_AZD_UP_PIPE_WRITER_PID_PATH

try {
    $env:WIN365_SAMPLE_INVOKE_AZD_UP_TEST_HOOK = 'InvokeAzdUpOffline'
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
if defined TEST_AZD_UP_UNICODE_PATH pwsh -NoProfile -Command "[IO.File]::WriteAllText($env:TEST_AZD_UP_UNICODE_PATH, $env:TEST_AZD_UP_UNICODE_VALUE)"
if "%TEST_AZD_UP_HANG%"=="true" (
  echo started>"%TEST_AZD_UP_HANG_STARTED_PATH%"
  start "" /b pwsh -NoProfile -Command "$PID | Set-Content -LiteralPath $env:TEST_AZD_UP_HANG_CHILD_PID_PATH; Start-Sleep -Seconds 30; 'survived' | Set-Content -LiteralPath $env:TEST_AZD_UP_HANG_SURVIVED_PATH"
  ping 127.0.0.1 -n 31 >nul
  exit /b 0
)
if "%TEST_AZD_UP_PIPE_HOLDER%"=="true" (
  start "" /b pwsh -NoProfile -Command "$PID | Set-Content -LiteralPath $env:TEST_AZD_UP_PIPE_HOLDER_PID_PATH; Start-Sleep -Seconds 30"
)
if "%TEST_AZD_UP_PIPE_WRITER%"=="true" (
  start "" /b pwsh -NoProfile -Command "$PID | Set-Content -LiteralPath $env:TEST_AZD_UP_PIPE_WRITER_PID_PATH; while ($true) { [Console]::Out.Write('x'); Start-Sleep -Milliseconds 10 }"
)
if "%TEST_AZD_UP_LARGE_FRAGMENT%"=="true" (
  pwsh -NoProfile -Command "[Console]::Out.Write('z' * 1048576); Start-Sleep -Milliseconds 500"
)
if "%TEST_AZD_UP_PROMPT%"=="true" (
  <nul set /p "=Type YES to continue: "
  ping 127.0.0.1 -n 3 >nul
  echo approved
)
if "%TEST_AZD_UP_STDERR_GUIDANCE%"=="true" (
  >&2 echo For information on invoking the agent, see https://aka.ms/azd-agents-invoke
  >&2 echo SUCCESS: Your application was provisioned and deployed to Azure in 1 second.
)
if "%TEST_AZD_UP_REQUIRE_EOF%"=="true" (
  pwsh -NoProfile -Command "if ($null -ne [Console]::In.ReadLine()) { exit 91 }"
  if errorlevel 1 exit /b 91
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
if not "%TEST_AZD_UP_PRESERVE_MARKERS%"=="true" (
  echo W365_AGENT_REDEPLOY_PENDING="false">>"%TEST_AZD_UP_ENV_PATH%"
  echo W365_AGENT_REDEPLOY_CHECK_PENDING="false">>"%TEST_AZD_UP_ENV_PATH%"
)
if "%TEST_AZD_UP_INCOMPLETE_REDEPLOY%"=="true" (
  echo Hosted-agent redeployment is required after the viewer configuration changed.
) else (
  if not "%TEST_AZD_UP_SKIP_COMPLETION%"=="true" echo W365_AZD_UP_POSTUP_RUN_ID="%W365_AZD_UP_RUN_ID%">>"%TEST_AZD_UP_ENV_PATH%"
)
echo SUCCESS: Your application was provisioned and deployed to Azure in 1 minute 20 seconds.
echo   Provisioning: 58 seconds
echo   Deploying:    20 seconds
if "%TEST_AZD_UP_FAIL%"=="true" exit /b 23
'@
    Copy-Item -LiteralPath $fakeAzdPath -Destination $complexFakeAzdPath
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
    $env:TEST_AZD_UP_HANG_CHILD_PID_PATH = $hangChildPidPath
    $env:TEST_AZD_UP_HANG_SURVIVED_PATH = $hangSurvivedPath
    $env:TEST_AZD_UP_PIPE_HOLDER_PID_PATH = $pipeHolderPidPath
    $env:TEST_AZD_UP_PIPE_WRITER_PID_PATH = $pipeWriterPidPath
    $env:TEST_AZD_UP_UNICODE_PATH = $unicodeValuePath
    $env:TEST_AZD_UP_UNICODE_VALUE = 'välue-測試'

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
    if ($call.Trim() -notin @(
        'up --environment sample-dev',
        '"up" "--environment" "sample-dev"'
    )) {
        throw "The wrapper invoked unexpected azd arguments: $call"
    }
    if ((Get-Content -LiteralPath $unicodeValuePath -Raw) -ne 'välue-測試') {
        throw 'The launcher did not preserve a Unicode environment value.'
    }
    $callsBeforeInvalidArguments = @(Get-Content -LiteralPath $callsPath).Count
    foreach ($invalidEnvironment in @(
        "invalid`"environment",
        "invalid`nenvironment"
    )) {
        $invalidArgumentFailed = $false
        try {
            & $scriptPath `
                -Environment $invalidEnvironment `
                -ConfirmResourceChanges `
                -AzdPath $fakeAzdPath `
                -RepositoryRoot $tempRoot *> $null
        }
        catch {
            $invalidArgumentFailed = $_.Exception.Message -match 'quotes or line breaks'
        }
        if (!$invalidArgumentFailed) {
            throw 'The batch launcher accepted a quote or line break in an argument.'
        }
    }
    if (@(Get-Content -LiteralPath $callsPath).Count -ne $callsBeforeInvalidArguments) {
        throw 'The batch launcher created a process before rejecting an unsafe argument.'
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
    if (!$promptProcess.WaitForExit(10000)) {
        $promptProcess.Kill($true)
        throw 'The prompt-streaming wrapper process did not exit within ten seconds.'
    }
    if ($promptProcess.ExitCode -ne 0) {
        $promptError = Get-Content -LiteralPath $promptErrorPath -Raw
        throw "The prompt-streaming wrapper process failed: $promptError"
    }
    $env:TEST_AZD_UP_PROMPT = $null

    $env:TEST_AZD_UP_FORCE_INVALID_STDIN = 'true'
    $headlessOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -NoPrompt `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    if ($headlessOutput -notmatch 'SUCCESS: Complete sample installation finished') {
        throw "The launcher did not provide a safe stdin handle for headless execution: $headlessOutput"
    }
    $env:TEST_AZD_UP_FORCE_INVALID_STDIN = $null

    $headlessInputPath = Join-Path $tempRoot 'headless-input.txt'
    $headlessOutputPath = Join-Path $tempRoot 'headless-output.txt'
    $headlessErrorPath = Join-Path $tempRoot 'headless-error.txt'
    Set-Content -LiteralPath $headlessInputPath -Value 'unexpected-input'
    $env:TEST_AZD_UP_REQUIRE_EOF = 'true'
    $headlessProcess = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @(
            '-NoProfile',
            '-File', $scriptPath,
            '-Environment', 'sample-dev',
            '-ConfirmResourceChanges',
            '-NoPrompt',
            '-AzdPath', $fakeAzdPath,
            '-RepositoryRoot', $tempRoot
        ) `
        -RedirectStandardInput $headlessInputPath `
        -RedirectStandardOutput $headlessOutputPath `
        -RedirectStandardError $headlessErrorPath `
        -NoNewWindow `
        -PassThru
    if (!$headlessProcess.WaitForExit(10000)) {
        $headlessProcess.Kill($true)
        throw 'The valid-stdin headless wrapper process did not exit within ten seconds.'
    }
    if ($headlessProcess.ExitCode -ne 0) {
        $headlessError = Get-Content -LiteralPath $headlessErrorPath -Raw
        throw "The -NoPrompt wrapper inherited readable parent stdin: $headlessError"
    }
    $env:TEST_AZD_UP_REQUIRE_EOF = $null

    $env:TEST_AZD_UP_STDERR_GUIDANCE = 'true'
    $stderrOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    if ($stderrOutput -match 'For information on invoking the agent' -or
        $stderrOutput -match 'SUCCESS: Your application was provisioned') {
        throw "The wrapper exposed unverified guidance from stderr: $stderrOutput"
    }
    $env:TEST_AZD_UP_STDERR_GUIDANCE = $null

    $env:TEST_AZD_UP_EXECUTION_FAILURE = 'true'
    $env:TEST_AZD_UP_TERMINATE_FAILURE = 'true'
    $env:TEST_AZD_UP_DISPOSE_FAILURE = 'true'
    $env:TEST_AZD_UP_HANG = 'true'
    $cleanupFailureRecords = [System.Collections.Generic.List[object]]::new()
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *>&1 |
            ForEach-Object { $cleanupFailureRecords.Add($_) }
    }
    catch {
        $cleanupFailureRecords.Add($_)
    }
    $cleanupFailureOutput = $cleanupFailureRecords | Out-String
    if ($cleanupFailureOutput -notmatch 'Simulated execution failure' -or
        $cleanupFailureOutput -notmatch 'Additional cleanup failure: Unable to terminate' -or
        $cleanupFailureOutput -notmatch 'Additional cleanup failure: Unable to release') {
        throw "Cleanup failures replaced the original execution error or were not reported: $cleanupFailureOutput"
    }
    $env:TEST_AZD_UP_EXECUTION_FAILURE = $null
    $env:TEST_AZD_UP_TERMINATE_FAILURE = $null
    $env:TEST_AZD_UP_DISPOSE_FAILURE = $null
    $env:TEST_AZD_UP_HANG = $null
    Remove-Item -LiteralPath `
        $hangStartedPath, `
        $hangChildPidPath, `
        $hangSurvivedPath `
        -ErrorAction SilentlyContinue

    $env:TEST_AZD_UP_PIPE_HOLDER = 'true'
    $pipeHolderTimer = [Diagnostics.Stopwatch]::StartNew()
    $pipeHolderOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    $pipeHolderTimer.Stop()
    if ($pipeHolderOutput -notmatch 'SUCCESS: Complete sample installation finished' -or
        $pipeHolderTimer.Elapsed.TotalSeconds -ge 10 -or
        !(Test-Path -LiteralPath $pipeHolderPidPath)) {
        throw "The wrapper did not bound output drain after the root process exited: $pipeHolderOutput"
    }
    $pipeHolderPid = [int](Get-Content -LiteralPath $pipeHolderPidPath -Raw)
    if ($null -ne (Get-Process -Id $pipeHolderPid -ErrorAction SilentlyContinue)) {
        throw "Output-holding descendant process $pipeHolderPid survived bounded drain cleanup."
    }
    $env:TEST_AZD_UP_PIPE_HOLDER = $null

    $env:TEST_AZD_UP_PIPE_WRITER = 'true'
    $pipeWriterTimer = [Diagnostics.Stopwatch]::StartNew()
    $pipeWriterOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    $pipeWriterTimer.Stop()
    if ($pipeWriterOutput -notmatch 'SUCCESS: Complete sample installation finished' -or
        $pipeWriterTimer.Elapsed.TotalSeconds -ge 10 -or
        !(Test-Path -LiteralPath $pipeWriterPidPath)) {
        throw "The wrapper did not bound continuously produced descendant output: $pipeWriterOutput"
    }
    $pipeWriterPid = [int](Get-Content -LiteralPath $pipeWriterPidPath -Raw)
    if ($null -ne (Get-Process -Id $pipeWriterPid -ErrorAction SilentlyContinue)) {
        throw "Continuously writing descendant process $pipeWriterPid survived bounded drain cleanup."
    }
    $env:TEST_AZD_UP_PIPE_WRITER = $null

    $env:TEST_AZD_UP_LARGE_FRAGMENT = 'true'
    $largeFragmentOutput = & $scriptPath `
        -Environment 'sample-dev' `
        -ConfirmResourceChanges `
        -AzdPath $fakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    if ($largeFragmentOutput -notmatch '\[output fragment truncated\]' -or
        $largeFragmentOutput -notmatch 'SUCCESS: Complete sample installation finished' -or
        $largeFragmentOutput.Length -ge 20000) {
        throw "The wrapper did not safely bound a large delimiter-free output fragment: length=$($largeFragmentOutput.Length)"
    }
    $env:TEST_AZD_UP_LARGE_FRAGMENT = $null

    $env:TEST_AZD_UP_LAUNCH_PID_PATH = $launchPidPath
    $env:TEST_AZD_UP_LAUNCH_DELAY_MILLISECONDS = '30000'
    $launchOutputPath = Join-Path $tempRoot 'launch-output.txt'
    $launchErrorPath = Join-Path $tempRoot 'launch-error.txt'
    $launchProcess = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @(
            '-NoProfile',
            '-File', $scriptPath,
            '-Environment', 'sample-dev',
            '-ConfirmResourceChanges',
            '-AzdPath', $fakeAzdPath,
            '-RepositoryRoot', $tempRoot
        ) `
        -RedirectStandardOutput $launchOutputPath `
        -RedirectStandardError $launchErrorPath `
        -NoNewWindow `
        -PassThru
    $launchDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    $launchChildPid = 0
    while ([DateTimeOffset]::UtcNow -lt $launchDeadline) {
        if (Test-Path -LiteralPath $launchPidPath) {
            $launchPidText = Get-Content -LiteralPath $launchPidPath -Raw
            if ([int]::TryParse($launchPidText, [ref]$launchChildPid) -and
                $launchChildPid -gt 0) {
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($launchChildPid -le 0) {
        $launchProcess.Kill($true)
        throw 'The launcher did not expose the suspended child for the launch-boundary cancellation test.'
    }
    Stop-Process -Id $launchProcess.Id
    if (!$launchProcess.WaitForExit(10000)) {
        $launchProcess.Kill($true)
        throw 'The launch-boundary wrapper process did not exit within ten seconds.'
    }
    $launchChildExitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ($null -ne (Get-Process -Id $launchChildPid -ErrorAction SilentlyContinue) -and
        [DateTimeOffset]::UtcNow -lt $launchChildExitDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne (Get-Process -Id $launchChildPid -ErrorAction SilentlyContinue)) {
        throw "Suspended launch process $launchChildPid survived termination of the wrapper host."
    }
    $launchValues = Read-AzdEnvironmentFile -Path (Join-Path $environmentDirectory '.env')
    if (![string]::IsNullOrWhiteSpace([string]$launchValues['W365_AZD_UP_COMPLETED_RUN_ID'])) {
        throw 'Launch-boundary cancellation persisted completion state.'
    }
    $env:TEST_AZD_UP_LAUNCH_PID_PATH = $null
    $env:TEST_AZD_UP_LAUNCH_DELAY_MILLISECONDS = $null

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
    while ((!(Test-Path -LiteralPath $hangStartedPath) -or
        !(Test-Path -LiteralPath $hangChildPidPath)) -and
        [DateTimeOffset]::UtcNow -lt $cancellationDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path -LiteralPath $hangStartedPath) -or
        !(Test-Path -LiteralPath $hangChildPidPath)) {
        $cancellationProcess.Kill($true)
        throw 'The fake azd provider did not start its descendant cancellation scenario.'
    }
    $callsBeforeContention = @(Get-Content -LiteralPath $callsPath).Count
    $concurrentFailure = try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $_.Exception.Message
    }
    if ($concurrentFailure -notmatch 'already operating on azd environment' -or
        @(Get-Content -LiteralPath $callsPath).Count -ne $callsBeforeContention) {
        $cancellationProcess.Kill($true)
        throw "Concurrent same-environment execution was not rejected before process creation: $concurrentFailure"
    }
    $hangChildPid = [int](Get-Content -LiteralPath $hangChildPidPath -Raw)
    Stop-Process -Id $cancellationProcess.Id
    if (!$cancellationProcess.WaitForExit(10000)) {
        $cancellationProcess.Kill($true)
        throw 'The cancellation wrapper process did not exit within ten seconds.'
    }
    $childExitDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ($null -ne (Get-Process -Id $hangChildPid -ErrorAction SilentlyContinue) -and
        [DateTimeOffset]::UtcNow -lt $childExitDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne (Get-Process -Id $hangChildPid -ErrorAction SilentlyContinue)) {
        throw "Descendant process $hangChildPid survived termination of the wrapper host."
    }
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

    New-Item -ItemType Directory -Path $complexEnvironmentDirectory -Force | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $environmentDirectory '.env') `
        -Destination (Join-Path $complexEnvironmentDirectory '.env')
    $env:TEST_AZD_UP_ENV_PATH = Join-Path $complexEnvironmentDirectory '.env'
    $complexOutput = & $scriptPath `
        -Environment $complexEnvironment `
        -ConfirmResourceChanges `
        -AzdPath $complexFakeAzdPath `
        -RepositoryRoot $tempRoot *>&1 | Out-String
    if ($complexOutput -notmatch 'SUCCESS: Complete sample installation finished') {
        throw "The batch launcher did not preserve a metacharacter-containing environment argument: $complexOutput"
    }
    $complexCall = (Get-Content -LiteralPath $callsPath)[-1]
    if ($complexCall -notmatch [regex]::Escape($complexEnvironment)) {
        throw "The batch launcher changed the metacharacter-containing argument: $complexCall"
    }
    $env:TEST_AZD_UP_ENV_PATH = Join-Path $environmentDirectory '.env'

    $nativeAzdPath = Join-Path $tempRoot 'native azd & (test) % Ω.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\findstr.exe') -Destination $nativeAzdPath
    $nativeFailure = try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $nativeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $_.Exception.Message
    }
    if ($nativeFailure -notmatch 'azd up failed with exit code 1') {
        throw "The native executable launch path did not propagate its exit status: $nativeFailure"
    }

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

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
        'ENABLE_W365="false"',
        'W365_ENABLED="false"',
        'DEPLOY_STATE="false"',
        'DEPLOY_VIEWER="false"',
        'W365_AGENT_REDEPLOY_PENDING="true"'
    )
    $env:TEST_AZD_UP_PRESERVE_MARKERS = 'true'
    $pendingDisabledFailed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $pendingDisabledFailed = $_.Exception.Message -match 'W365_AGENT_REDEPLOY_PENDING=false'
    }
    if (!$pendingDisabledFailed) {
        throw 'The wrapper accepted pending hosted-agent redeployment in a W365-disabled environment.'
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
        'W365_AGENT_REDEPLOY_PENDING="true"'
    )
    $pendingMissingViewerFailed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $pendingMissingViewerFailed = $_.Exception.Message -match 'W365_AGENT_REDEPLOY_PENDING=false' -and
            $_.Exception.Message -match 'VIEWER_PUBLIC_URL'
    }
    if (!$pendingMissingViewerFailed) {
        throw 'The wrapper accepted pending hosted-agent redeployment with a missing viewer URL.'
    }

    Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value @(
        'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
        'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
        'ENABLE_W365="false"',
        'W365_ENABLED="false"',
        'DEPLOY_STATE="false"',
        'DEPLOY_VIEWER="false"',
        'W365_AGENT_REDEPLOY_CHECK_PENDING="true"'
    )
    $comparisonPendingFailed = $false
    try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *> $null
    }
    catch {
        $comparisonPendingFailed = $_.Exception.Message -match 'W365_AGENT_REDEPLOY_CHECK_PENDING=false'
    }
    if (!$comparisonPendingFailed) {
        throw 'The wrapper accepted unresolved viewer comparison state.'
    }

    foreach ($markerValue in @($null, '', 'invalid', 'False')) {
        $markerLines = @(
            'FOUNDRY_AGENT_NAME="win365-desktop-agent"',
            'AGENT_WIN365_DESKTOP_AGENT_VERSION="4"',
            'ENABLE_W365="false"',
            'W365_ENABLED="false"',
            'DEPLOY_STATE="false"',
            'DEPLOY_VIEWER="false"'
        )
        if ($null -ne $markerValue) {
            $markerLines += "W365_AGENT_REDEPLOY_PENDING=`"$markerValue`""
            $markerLines += "W365_AGENT_REDEPLOY_CHECK_PENDING=`"$markerValue`""
        }
        Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Value $markerLines
        $env:TEST_AZD_UP_PRESERVE_MARKERS = 'true'
        $invalidMarkerFailed = $false
        try {
            & $scriptPath `
                -Environment 'sample-dev' `
                -ConfirmResourceChanges `
                -AzdPath $fakeAzdPath `
                -RepositoryRoot $tempRoot *> $null
        }
        catch {
            $invalidMarkerFailed =
                $_.Exception.Message -match 'W365_AGENT_REDEPLOY_PENDING=false' -and
                $_.Exception.Message -match 'W365_AGENT_REDEPLOY_CHECK_PENDING=false'
        }
        if (!$invalidMarkerFailed) {
            throw "The wrapper accepted invalid completion marker value '$markerValue'."
        }
    }
    $env:TEST_AZD_UP_PRESERVE_MARKERS = $null

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

    $env:TEST_AZD_UP_INCOMPLETE_REDEPLOY = 'true'
    $incompleteRedeployOutput = try {
        & $scriptPath `
            -Environment 'sample-dev' `
            -ConfirmResourceChanges `
            -AzdPath $fakeAzdPath `
            -RepositoryRoot $tempRoot *>&1 | Out-String
    }
    catch {
        $_ | Out-String
    }
    if ($incompleteRedeployOutput -notmatch 'current post-deployment workflow did not complete' -or
        $incompleteRedeployOutput -match 'SUCCESS:') {
        throw "The wrapper accepted a skipped required hosted-agent redeployment: $incompleteRedeployOutput"
    }
    $env:TEST_AZD_UP_INCOMPLETE_REDEPLOY = $null

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
        $failed = $_.Exception.Message -match 'exit code 23' -and
            $_.Exception.Message -match 'reported stage and ownership evidence' -and
            $_.Exception.Message -match 'retrying the same environment' -and
            $_.Exception.Message -match 'Invoke-AzdDown.ps1' -and
            $_.Exception.Message -match 'UseDeviceCode' -and
            $_.Exception.Message -match 'Operations and rollback'
    }
    if (!$failed) {
        throw 'The wrapper did not propagate the azd up failure.'
    }

    Write-Host 'azd up customer-output wrapper offline test passed.'
}
finally {
    $env:WIN365_SAMPLE_INVOKE_AZD_UP_TEST_HOOK = $previousTestHook
    $env:TEST_AZD_UP_CALLS_PATH = $previousCallsPath
    $env:TEST_AZD_UP_ENV_PATH = $previousEnvironmentPath
    $env:TEST_AZD_UP_PROMPT = $previousPrompt
    $env:TEST_AZD_UP_SKIP_COMPLETION = $previousSkipCompletion
    $env:TEST_AZD_UP_HANG = $previousHang
    $env:TEST_AZD_UP_HANG_STARTED_PATH = $previousHangStartedPath
    $env:TEST_AZD_UP_HANG_CHILD_PID_PATH = $previousHangChildPidPath
    $env:TEST_AZD_UP_HANG_SURVIVED_PATH = $previousHangSurvivedPath
    $env:TEST_AZD_UP_INCOMPLETE_REDEPLOY = $previousIncompleteRedeploy
    $env:TEST_AZD_UP_UNICODE_PATH = $previousUnicodePath
    $env:TEST_AZD_UP_UNICODE_VALUE = $previousUnicodeValue
    $env:TEST_AZD_UP_LAUNCH_PID_PATH = $previousLaunchPidPath
    $env:TEST_AZD_UP_LAUNCH_DELAY_MILLISECONDS = $previousLaunchDelay
    $env:TEST_AZD_UP_FORCE_INVALID_STDIN = $previousForceInvalidStdin
    $env:TEST_AZD_UP_STDERR_GUIDANCE = $previousStderrGuidance
    $env:TEST_AZD_UP_REQUIRE_EOF = $previousRequireEof
    $env:TEST_AZD_UP_EXECUTION_FAILURE = $previousExecutionFailure
    $env:TEST_AZD_UP_TERMINATE_FAILURE = $previousTerminateFailure
    $env:TEST_AZD_UP_DISPOSE_FAILURE = $previousDisposeFailure
    $env:TEST_AZD_UP_PRESERVE_MARKERS = $previousPreserveMarkers
    $env:TEST_AZD_UP_PIPE_HOLDER = $previousPipeHolder
    $env:TEST_AZD_UP_PIPE_HOLDER_PID_PATH = $previousPipeHolderPidPath
    $env:TEST_AZD_UP_PIPE_WRITER = $previousPipeWriter
    $env:TEST_AZD_UP_PIPE_WRITER_PID_PATH = $previousPipeWriterPidPath
    Remove-Item Env:\TEST_AZD_UP_LARGE_FRAGMENT -ErrorAction SilentlyContinue
    Remove-Item Env:\TEST_AZD_UP_FAIL -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
