<#
.SYNOPSIS
Runs the complete azd deployment and prints final guidance only after verified completion.

.DESCRIPTION
Invokes azd up for one existing azd environment, forwards line- or
carriage-return-delimited output and recognized interactive prompts, suppresses
premature generic Foundry next steps, verifies a run-specific post-up handshake
and persisted component state, then prints the repository deployment summary.

.PARAMETER Environment
The existing azd environment to deploy.

.PARAMETER RepositoryRoot
The repository root containing azure.yaml, scripts, and the selected .azure environment.

.PARAMETER ConfirmResourceChanges
Explicitly approves creation or update of billable Azure and Windows 365 resources.

.PARAMETER NoPrompt
Passes --no-prompt to azd. Protected automation must separately provide every required approval.

.PARAMETER AzdPath
Optional explicit Azure Developer CLI executable used by tests or controlled installations.

.PARAMETER DeploymentSummaryScriptPath
Optional deployment-summary script override used by offline tests.

.OUTPUTS
Streams sanitized deployment progress, followed by verified success and next-step guidance.

.NOTES
Mutating wrapper. It fails closed when azd, post-up setup, state validation,
summary generation, or run-specific completion persistence is incomplete.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [string]$RepositoryRoot = (Split-Path $PSScriptRoot),

    [switch]$ConfirmResourceChanges,

    [switch]$NoPrompt,

    [string]$AzdPath,

    [string]$DeploymentSummaryScriptPath = (Join-Path $PSScriptRoot 'Show-DeploymentSummary.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!$IsWindows) {
    throw 'This deployment wrapper is Windows-only. Use PowerShell 7.4 or later on Windows.'
}
if ($null -eq ('Win365Sample.ChildProcessJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Win365Sample
{
    public sealed class ChildProcessJob : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private IntPtr handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public ChildProcessJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var limits = new JobObjectExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int length = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            IntPtr information = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(limits, information, false);
                if (!SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformationClass,
                    information,
                    (uint)length))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            catch
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(information);
            }
        }

        public void Assign(Process process)
        {
            if (!AssignProcessToJobObject(handle, process.Handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
        }
    }
}
'@
}
if (!$ConfirmResourceChanges -and !$WhatIfPreference) {
    throw 'Deployment can create or update billable Azure and Windows 365 resources. Re-run with -ConfirmResourceChanges after reviewing the deployment plan.'
}
if (!(Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "RepositoryRoot '$RepositoryRoot' was not found."
}

$resolvedAzd = if (![string]::IsNullOrWhiteSpace($AzdPath)) {
    if (!(Test-Path -LiteralPath $AzdPath -PathType Leaf)) {
        throw "AzdPath '$AzdPath' was not found."
    }
    [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $AzdPath).Path }
}
else {
    Get-W365AzdCommand
}
if (!$resolvedAzd) {
    throw 'Azure Developer CLI 1.32.0 or later is required.'
}
if (!(Test-Path -LiteralPath $DeploymentSummaryScriptPath -PathType Leaf)) {
    throw "DeploymentSummaryScriptPath '$DeploymentSummaryScriptPath' was not found."
}

$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add('up')
$arguments.Add('--environment')
$arguments.Add($Environment)
if ($NoPrompt) {
    $arguments.Add('--no-prompt')
}

if (!$PSCmdlet.ShouldProcess(
        "azd environment '$Environment'",
        'Run the complete Foundry, shared-state, viewer, and Windows 365 deployment')) {
    return
}

$environmentPath = Join-Path $RepositoryRoot ".azure\$Environment\.env"
if (!(Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "Azd environment '$Environment' has no persisted .env file. Run 'azd env new $Environment' before this command."
}
$runId = [guid]::NewGuid().ToString('N')
Set-AzdEnvironmentFileValues -Path $environmentPath -Values @{
    W365_AZD_UP_POSTUP_RUN_ID = ''
    W365_AZD_UP_COMPLETED_RUN_ID = ''
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$extension = [IO.Path]::GetExtension($resolvedAzd.Path)
if ($extension -in @('.cmd', '.bat')) {
    $startInfo.FileName = $env:ComSpec
    $startInfo.ArgumentList.Add('/d')
    $startInfo.ArgumentList.Add('/c')
    $startInfo.ArgumentList.Add($resolvedAzd.Path)
}
else {
    $startInfo.FileName = $resolvedAzd.Path
}
foreach ($argument in $arguments) {
    $startInfo.ArgumentList.Add($argument)
}
$startInfo.WorkingDirectory = $RepositoryRoot
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $false
$startInfo.RedirectStandardInput = $false
$startInfo.Environment['W365_AZD_UP_WRAPPER'] = 'true'
$startInfo.Environment['W365_AZD_UP_RUN_ID'] = $runId

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$processJob = [Win365Sample.ChildProcessJob]::new()
$processStarted = $false
$processExitCode = $null
$elapsed = [Diagnostics.Stopwatch]::StartNew()
function Write-FilteredAzdLine {
    param([AllowEmptyString()][string]$Line)

    $plainLine = [regex]::Replace($line, "`e\[[0-9;?]*[ -/]*[@-~]", '')
    $trimmedLine = $plainLine.Trim()

    if ($trimmedLine -like 'For information on invoking the agent, see *' -or
        $trimmedLine -like 'Set up an evaluation suite to measure quality and impact in one step with *') {
        $script:foundryGuidanceSeen = $true
        return
    }

    if ($script:foundryGuidanceSeen -and $trimmedLine -eq 'Next:') {
        $script:suppressNextBlock = $true
        return
    }

    if ($script:suppressNextBlock) {
        if ([string]::IsNullOrWhiteSpace($plainLine) -or
            [char]::IsWhiteSpace($plainLine[0])) {
            return
        }
        $script:suppressNextBlock = $false
        $script:foundryGuidanceSeen = $false
    }

    if ($trimmedLine -like 'SUCCESS: Your application was provisioned and deployed to Azure in *' -or
        $trimmedLine -match '^(Provisioning|Deploying):\s+') {
        return
    }

    Write-Host $line
}

function Test-InteractivePromptFragment {
    param([Parameter(Mandatory)][string]$Text)

    $plainText = [regex]::Replace($Text, "`e\[[0-9;?]*[ -/]*[@-~]", '')
    $trimmedText = $plainText.TrimStart()
    if ($trimmedText.StartsWith('?')) {
        return $true
    }

    return $trimmedText.EndsWith(':') -and (
        $trimmedText.StartsWith('Type ') -or
        $trimmedText.StartsWith('Enter ') -or
        $trimmedText.StartsWith('Blueprint client secret') -or
        $trimmedText.StartsWith('Viewer OIDC client secret'))
}

$script:foundryGuidanceSeen = $false
$script:suppressNextBlock = $false
$lineBuffer = [Text.StringBuilder]::new()
$promptPassthrough = $false
$previousWasCarriageReturn = $false
try {
    if (!$process.Start()) {
        throw "Unable to start '$($resolvedAzd.Path)'."
    }
    $processStarted = $true
    try {
        $processJob.Assign($process)
    }
    catch {
        $process.Kill($true)
        $process.WaitForExit()
        throw "Unable to attach azd to the wrapper's cancellation boundary: $($_.Exception.Message)"
    }

    while (($nextCharacter = $process.StandardOutput.Read()) -ne -1) {
        $character = [char]$nextCharacter
        if ($promptPassthrough) {
            Write-Host -NoNewline $character
            if ($character -eq "`n") {
                $promptPassthrough = $false
            }
            continue
        }

        if ($character -eq "`n") {
            if ($previousWasCarriageReturn) {
                $previousWasCarriageReturn = $false
                continue
            }
            $line = $lineBuffer.ToString()
            [void]$lineBuffer.Clear()
            Write-FilteredAzdLine -Line $line
            continue
        }
        if ($character -eq "`r") {
            $line = $lineBuffer.ToString()
            [void]$lineBuffer.Clear()
            Write-FilteredAzdLine -Line $line
            $previousWasCarriageReturn = $true
            continue
        }
        $previousWasCarriageReturn = $false

        [void]$lineBuffer.Append($character)
        if (Test-InteractivePromptFragment -Text $lineBuffer.ToString()) {
            Write-Host -NoNewline $lineBuffer.ToString()
            [void]$lineBuffer.Clear()
            $promptPassthrough = $true
        }
    }
    if ($lineBuffer.Length -gt 0) {
        Write-FilteredAzdLine -Line $lineBuffer.ToString()
    }

    $process.WaitForExit()
    $processExitCode = $process.ExitCode
}
finally {
    if ($processStarted -and !$process.HasExited) {
        $process.Kill($true)
        if (!$process.WaitForExit(10000)) {
            throw 'The azd process tree did not stop within ten seconds after wrapper cancellation.'
        }
    }
    $processJob.Dispose()
    $process.Dispose()
}
$elapsed.Stop()
if ($processExitCode -ne 0) {
    throw "azd up failed with exit code $processExitCode."
}

if (!(Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "azd reported success, but environment '$Environment' has no persisted .env file. The installation is incomplete."
}
$values = Read-AzdEnvironmentFile -Path $environmentPath
if ([string]$values['W365_AZD_UP_POSTUP_RUN_ID'] -ne $runId) {
    throw "azd returned success, but the current post-deployment workflow did not complete. Inspect the reported stage and ownership evidence before retrying the same environment. If abandoning it, use the documented ownership-driven teardown."
}
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($name in @(
    'FOUNDRY_AGENT_NAME',
    'AGENT_WIN365_DESKTOP_AGENT_VERSION'
)) {
    if ([string]::IsNullOrWhiteSpace([string]$values[$name])) {
        $missing.Add($name)
    }
}
if ([string]$values['ENABLE_W365'] -eq 'true' -and
    [string]$values['W365_ENABLED'] -ne 'true') {
    $missing.Add('W365_ENABLED=true')
}
if ([string]$values['DEPLOY_STATE'] -eq 'true') {
    foreach ($name in @('STATE_STORAGE_ACCOUNT_NAME', 'STATE_CONTAINER_NAME', 'SESSION_BLOB_URI')) {
        if ([string]::IsNullOrWhiteSpace([string]$values[$name])) {
            $missing.Add($name)
        }
    }
}
if ([string]$values['DEPLOY_VIEWER'] -eq 'true' -and
    [string]::IsNullOrWhiteSpace([string]$values['VIEWER_PUBLIC_URL'])) {
    $missing.Add('VIEWER_PUBLIC_URL')
}
if ($missing.Count -gt 0) {
    throw "azd core deployment returned success, but the complete sample installation is unfinished. Missing completion state: $($missing -join ', '). Inspect the reported stage and ownership evidence before retrying the same environment. If abandoning it, use the documented ownership-driven teardown."
}

$elapsedText = if ($elapsed.Elapsed.TotalHours -ge 1) {
    '{0}h {1}m {2}s' -f [int]$elapsed.Elapsed.TotalHours, $elapsed.Elapsed.Minutes, $elapsed.Elapsed.Seconds
}
elseif ($elapsed.Elapsed.TotalMinutes -ge 1) {
    '{0}m {1}s' -f [int]$elapsed.Elapsed.TotalMinutes, $elapsed.Elapsed.Seconds
}
else {
    '{0}s' -f [Math]::Max(1, [int][Math]::Ceiling($elapsed.Elapsed.TotalSeconds))
}
$summaryText = & $DeploymentSummaryScriptPath `
    -RepositoryRoot $RepositoryRoot `
    -Environment $Environment *>&1 |
    Out-String
Set-AzdEnvironmentFileValues -Path $environmentPath -Values @{
    W365_AZD_UP_COMPLETED_RUN_ID = $runId
}
$completedValues = Read-AzdEnvironmentFile -Path $environmentPath
if ([string]$completedValues['W365_AZD_UP_COMPLETED_RUN_ID'] -ne $runId) {
    throw 'The deployment completed, but its run-specific completion state could not be verified.'
}
Write-Host ''
$completionLabel = if ([string]$values['W365_ENABLED'] -eq 'true') {
    'Complete sample installation'
}
else {
    'Foundry bootstrap deployment'
}
Write-Host "SUCCESS: $completionLabel finished in $elapsedText."
Write-Host $summaryText.TrimEnd()
