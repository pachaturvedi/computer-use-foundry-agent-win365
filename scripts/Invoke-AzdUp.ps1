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
if ($null -eq ('Win365Sample.SuspendedJobProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Win365Sample
{
    public sealed class SuspendedJobProcess : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint DuplicateSameAccess = 0x00000002;
        private const long ProcThreadAttributeHandleList = 0x00020002;
        private const long ProcThreadAttributeJobList = 0x0002000D;
        private const uint Infinite = 0xFFFFFFFF;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitTimeout = 0x00000102;
        private const int StdInputHandle = -10;
        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private IntPtr jobHandle;
        private IntPtr processHandle;
        private readonly StreamReader standardOutput;
        private Task<int> pendingOutputRead;
        private readonly char[] outputBuffer = new char[1];

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public uint X;
            public uint Y;
            public uint XSize;
            public uint YSize;
            public uint XCountChars;
            public uint YCountChars;
            public uint FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StdInput;
            public IntPtr StdOutput;
            public IntPtr StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public uint ProcessId;
            public uint ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

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

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes,
            int size);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DuplicateHandle(
            IntPtr sourceProcess,
            IntPtr sourceHandle,
            IntPtr targetProcess,
            out IntPtr targetHandle,
            uint desiredAccess,
            bool inheritHandle,
            uint options);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private SuspendedJobProcess(
            IntPtr job,
            IntPtr childProcess,
            StreamReader childOutput)
        {
            jobHandle = job;
            processHandle = childProcess;
            standardOutput = childOutput;
        }

        private static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
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
                    job,
                    JobObjectExtendedLimitInformationClass,
                    information,
                    (uint)length))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            catch
            {
                CloseHandle(job);
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(information);
            }
            return job;
        }

        private static string Quote(string argument)
        {
            if (argument.Length > 0 &&
                argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return argument;
            }

            var result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static IntPtr CreateEnvironmentBlock(IDictionary<string, string> overrides)
        {
            var values = new SortedDictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                values[(string)entry.Key] = (string)entry.Value;
            }
            foreach (KeyValuePair<string, string> entry in overrides)
            {
                values[entry.Key] = entry.Value;
            }

            var block = new StringBuilder();
            foreach (KeyValuePair<string, string> entry in values)
            {
                block.Append(entry.Key);
                block.Append('=');
                block.Append(entry.Value);
                block.Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        private static IntPtr GetInheritedStandardInput(bool useNullInput)
        {
            IntPtr source = useNullInput ||
                IsTestHookEnabled() && Environment.GetEnvironmentVariable(
                "TEST_AZD_UP_FORCE_INVALID_STDIN") == "true"
                ? IntPtr.Zero
                : GetStdHandle(StdInputHandle);
            if (source == IntPtr.Zero || source == new IntPtr(-1))
            {
                var securityAttributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    InheritHandle = true
                };
                IntPtr nullInput = CreateFile(
                    "NUL",
                    GenericRead,
                    FileShareRead | FileShareWrite,
                    ref securityAttributes,
                    OpenExisting,
                    0,
                    IntPtr.Zero);
                if (nullInput == IntPtr.Zero || nullInput == new IntPtr(-1))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return nullInput;
            }
            IntPtr duplicate;
            IntPtr currentProcess = GetCurrentProcess();
            if (!DuplicateHandle(
                currentProcess,
                source,
                currentProcess,
                out duplicate,
                0,
                true,
                DuplicateSameAccess))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return duplicate;
        }

        private static StringBuilder BuildCommandLine(
            string fileName,
            string[] arguments,
            bool commandScript)
        {
            var commandLine = new StringBuilder(Quote(fileName));
            if (commandScript)
            {
                commandLine.Append(" /d /v:off /s /c \"\"%W365_AZD_BATCH_TARGET%\"");
                for (int index = 0; index < arguments.Length; index++)
                {
                    commandLine.Append(" \"%W365_AZD_BATCH_ARG_");
                    commandLine.Append(index);
                    commandLine.Append("%\"");
                }
                commandLine.Append('"');
                return commandLine;
            }

            foreach (string argument in arguments)
            {
                commandLine.Append(' ');
                commandLine.Append(Quote(argument));
            }
            return commandLine;
        }

        public static SuspendedJobProcess Start(
            string fileName,
            string[] arguments,
            string workingDirectory,
            IDictionary<string, string> environmentOverrides,
            bool commandScript,
            bool noPrompt)
        {
            IntPtr job = IntPtr.Zero;
            IntPtr readPipe = IntPtr.Zero;
            IntPtr writePipe = IntPtr.Zero;
            IntPtr childInput = IntPtr.Zero;
            IntPtr environment = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr jobValue = IntPtr.Zero;
            IntPtr handleListValue = IntPtr.Zero;
            ProcessInformation processInformation = new ProcessInformation();
            bool processCreated = false;
            try
            {
                job = CreateKillOnCloseJob();
                var pipeAttributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf<SecurityAttributes>(),
                    InheritHandle = true
                };
                if (!CreatePipe(
                    out readPipe,
                    out writePipe,
                    ref pipeAttributes,
                    0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                childInput = GetInheritedStandardInput(noPrompt);

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    2,
                    0,
                    ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(
                    attributeList,
                    2,
                    0,
                    ref attributeListSize))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                jobValue = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobValue, job);
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(ProcThreadAttributeJobList),
                    jobValue,
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                IntPtr[] inheritedHandles = { childInput, writePipe };
                handleListValue = Marshal.AllocHGlobal(IntPtr.Size * inheritedHandles.Length);
                for (int index = 0; index < inheritedHandles.Length; index++)
                {
                    Marshal.WriteIntPtr(
                        handleListValue,
                        index * IntPtr.Size,
                        inheritedHandles[index]);
                }
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    new IntPtr(ProcThreadAttributeHandleList),
                    handleListValue,
                    new IntPtr(IntPtr.Size * inheritedHandles.Length),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                var startupInfo = new StartupInfoEx
                {
                    StartupInfo = new StartupInfo
                    {
                        Size = Marshal.SizeOf<StartupInfoEx>(),
                        Flags = StartfUseStdHandles,
                        StdInput = childInput,
                        StdOutput = writePipe,
                        StdError = writePipe
                    },
                    AttributeList = attributeList
                };
                var commandLine = BuildCommandLine(fileName, arguments, commandScript);
                environment = CreateEnvironmentBlock(environmentOverrides);
                if (!CreateProcess(
                    fileName,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended |
                        CreateUnicodeEnvironment |
                        ExtendedStartupInfoPresent,
                    environment,
                    workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                processCreated = true;
                string launchPidPath = IsTestHookEnabled()
                    ? Environment.GetEnvironmentVariable(
                        "TEST_AZD_UP_LAUNCH_PID_PATH")
                    : null;
                if (!String.IsNullOrWhiteSpace(launchPidPath))
                {
                    File.WriteAllText(
                        launchPidPath,
                        processInformation.ProcessId.ToString());
                }
                int launchDelay;
                if (IsTestHookEnabled() && Int32.TryParse(
                    Environment.GetEnvironmentVariable(
                        "TEST_AZD_UP_LAUNCH_DELAY_MILLISECONDS"),
                    out launchDelay) &&
                    launchDelay > 0)
                {
                    Thread.Sleep(launchDelay);
                }

                var safeReadPipe = new SafeFileHandle(readPipe, true);
                readPipe = IntPtr.Zero;
                var output = new StreamReader(
                    new FileStream(safeReadPipe, FileAccess.Read),
                    Console.OutputEncoding,
                    true);
                if (ResumeThread(processInformation.Thread) == uint.MaxValue)
                {
                    output.Dispose();
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                CloseHandle(processInformation.Thread);
                processInformation.Thread = IntPtr.Zero;
                CloseHandle(writePipe);
                writePipe = IntPtr.Zero;
                IntPtr childProcess = processInformation.Process;
                processInformation.Process = IntPtr.Zero;
                return new SuspendedJobProcess(job, childProcess, output);
            }
            catch
            {
                if (processCreated && processInformation.Process != IntPtr.Zero)
                {
                    TerminateProcess(processInformation.Process, 1);
                }
                if (processInformation.Thread != IntPtr.Zero)
                {
                    CloseHandle(processInformation.Thread);
                }
                if (processInformation.Process != IntPtr.Zero)
                {
                    CloseHandle(processInformation.Process);
                }
                if (job != IntPtr.Zero)
                {
                    CloseHandle(job);
                }
                throw;
            }
            finally
            {
                if (environment != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environment);
                }
                if (attributeList != IntPtr.Zero)
                {
                    DeleteProcThreadAttributeList(attributeList);
                    Marshal.FreeHGlobal(attributeList);
                }
                if (handleListValue != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(handleListValue);
                }
                if (jobValue != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(jobValue);
                }
                if (childInput != IntPtr.Zero)
                {
                    CloseHandle(childInput);
                }
                if (writePipe != IntPtr.Zero)
                {
                    CloseHandle(writePipe);
                }
                if (readPipe != IntPtr.Zero)
                {
                    CloseHandle(readPipe);
                }
            }
        }

        public StreamReader StandardOutput { get { return standardOutput; } }
        public int ReadOutputCharacter(int timeoutMilliseconds)
        {
            if (pendingOutputRead == null)
            {
                pendingOutputRead = standardOutput.ReadAsync(outputBuffer, 0, 1);
            }
            if (!pendingOutputRead.Wait(timeoutMilliseconds))
            {
                return -2;
            }
            int count = pendingOutputRead.Result;
            pendingOutputRead = null;
            return count == 0 ? -1 : outputBuffer[0];
        }
        public void ThrowIfTestExecutionFailure()
        {
            if (IsTestHookEnabled() && Environment.GetEnvironmentVariable(
                "TEST_AZD_UP_EXECUTION_FAILURE") == "true")
            {
                throw new InvalidOperationException("Simulated execution failure.");
            }
        }
        public bool HasExited
        {
            get
            {
                uint result = WaitForSingleObject(processHandle, 0);
                if (result == WaitObject0)
                {
                    return true;
                }
                if (result == WaitTimeout)
                {
                    return false;
                }
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        public int WaitForExitAndGetCode()
        {
            uint waitResult = WaitForSingleObject(processHandle, Infinite);
            if (waitResult != WaitObject0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            uint exitCode;
            if (!GetExitCodeProcess(processHandle, out exitCode))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return unchecked((int)exitCode);
        }
        public bool WaitForExit(int milliseconds)
        {
            uint result = WaitForSingleObject(processHandle, (uint)milliseconds);
            if (result == WaitObject0)
            {
                return true;
            }
            if (result == WaitTimeout)
            {
                return false;
            }
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        public void Terminate(uint exitCode)
        {
            if (IsTestHookEnabled() && Environment.GetEnvironmentVariable(
                "TEST_AZD_UP_TERMINATE_FAILURE") == "true")
            {
                throw new InvalidOperationException("Simulated termination failure.");
            }
            if (!TerminateJobObject(jobHandle, exitCode))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public void Dispose()
        {
            standardOutput.Dispose();
            if (processHandle != IntPtr.Zero)
            {
                CloseHandle(processHandle);
                processHandle = IntPtr.Zero;
            }
            if (jobHandle != IntPtr.Zero)
            {
                CloseHandle(jobHandle);
                jobHandle = IntPtr.Zero;
            }
            if (IsTestHookEnabled() && Environment.GetEnvironmentVariable(
                "TEST_AZD_UP_DISPOSE_FAILURE") == "true")
            {
                throw new InvalidOperationException("Simulated disposal failure.");
            }
        }

        private static bool IsTestHookEnabled()
        {
            return String.Equals(
                Environment.GetEnvironmentVariable(
                    "WIN365_SAMPLE_INVOKE_AZD_UP_TEST_HOOK"),
                "InvokeAzdUpOffline",
                StringComparison.Ordinal);
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
$extension = [IO.Path]::GetExtension($resolvedAzd.Path)
$isCommandScript = $extension -in @('.cmd', '.bat')
if ($isCommandScript) {
    foreach ($value in @($resolvedAzd.Path) + @($arguments)) {
        if ($value -match '["\r\n]') {
            throw 'Batch-based azd paths and arguments cannot contain quotes or line breaks.'
        }
    }
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
$environmentLockPath = Join-Path (Split-Path -Parent $environmentPath) '.azd-up.lock'
try {
    $environmentLock = [IO.File]::Open(
        $environmentLockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
}
catch [IO.IOException] {
    throw "Another Invoke-AzdUp.ps1 process is already operating on azd environment '$Environment'. Wait for it to finish before retrying."
}
try {
$runId = [guid]::NewGuid().ToString('N')
Set-AzdEnvironmentFileValues -Path $environmentPath -Values @{
    W365_AZD_UP_POSTUP_RUN_ID = ''
    W365_AZD_UP_COMPLETED_RUN_ID = ''
}

$processArguments = [System.Collections.Generic.List[string]]::new()
if ($isCommandScript) {
    $processFileName = $env:ComSpec
}
else {
    $processFileName = $resolvedAzd.Path
}
foreach ($argument in $arguments) {
    $processArguments.Add($argument)
}
$environmentOverrides = [System.Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$environmentOverrides['W365_AZD_UP_WRAPPER'] = 'true'
$environmentOverrides['W365_AZD_UP_RUN_ID'] = $runId
if ($NoPrompt) {
    $environmentOverrides['AZD_NON_INTERACTIVE'] = 'true'
}
if ($isCommandScript) {
    $environmentOverrides['W365_AZD_BATCH_TARGET'] = $resolvedAzd.Path
    for ($index = 0; $index -lt $processArguments.Count; $index++) {
        $environmentOverrides["W365_AZD_BATCH_ARG_$index"] = $processArguments[$index]
    }
}

$process = $null
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
$maximumBufferedFragmentLength = 4096
$lineBuffer = [Text.StringBuilder]::new()
$lineWasTruncated = $false
$promptPassthrough = $false
$previousWasCarriageReturn = $false
$executionError = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$rootExitObservedAt = $null
$jobTerminatedAfterRootExit = $false
try {
    $process = [Win365Sample.SuspendedJobProcess]::Start(
        $processFileName,
        [string[]]$processArguments,
        $RepositoryRoot,
        $environmentOverrides,
        $isCommandScript,
        $NoPrompt.IsPresent)
    $process.ThrowIfTestExecutionFailure()

    while ($true) {
        $nextCharacter = $process.ReadOutputCharacter(100)
        $now = [DateTimeOffset]::UtcNow
        if ($process.HasExited) {
            if ($null -eq $processExitCode) {
                $processExitCode = $process.WaitForExitAndGetCode()
                $rootExitObservedAt = $now
            }
            elseif (!$jobTerminatedAfterRootExit -and
                $now -ge $rootExitObservedAt.AddSeconds(2)) {
                $process.Terminate(1)
                $jobTerminatedAfterRootExit = $true
                $rootExitObservedAt = $now
            }
            elseif ($jobTerminatedAfterRootExit -and
                $now -ge $rootExitObservedAt.AddSeconds(5)) {
                throw 'The azd output pipe remained open after its process tree was terminated.'
            }
        }
        if ($nextCharacter -eq -1) {
            break
        }
        if ($nextCharacter -eq -2) {
            continue
        }
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
            if ($lineWasTruncated) {
                $line += ' [output fragment truncated]'
            }
            [void]$lineBuffer.Clear()
            $lineWasTruncated = $false
            Write-FilteredAzdLine -Line $line
            continue
        }
        if ($character -eq "`r") {
            $line = $lineBuffer.ToString()
            if ($lineWasTruncated) {
                $line += ' [output fragment truncated]'
            }
            [void]$lineBuffer.Clear()
            $lineWasTruncated = $false
            Write-FilteredAzdLine -Line $line
            $previousWasCarriageReturn = $true
            continue
        }
        $previousWasCarriageReturn = $false

        if ($lineBuffer.Length -lt $maximumBufferedFragmentLength) {
            [void]$lineBuffer.Append($character)
            $bufferedFragment = $lineBuffer.ToString()
            if (Test-InteractivePromptFragment -Text $bufferedFragment) {
                Write-Host -NoNewline $bufferedFragment
                [void]$lineBuffer.Clear()
                $promptPassthrough = $true
            }
        }
        else {
            $lineWasTruncated = $true
        }
    }
    if ($lineBuffer.Length -gt 0) {
        $line = $lineBuffer.ToString()
        if ($lineWasTruncated) {
            $line += ' [output fragment truncated]'
        }
        Write-FilteredAzdLine -Line $line
    }
    if ($null -eq $processExitCode) {
        $processExitCode = $process.WaitForExitAndGetCode()
    }
}
catch {
    $executionError = $_
}
finally {
    try {
        if ($null -ne $process -and !$process.HasExited) {
            $process.Terminate(1)
            if (!$process.WaitForExit(10000)) {
                $cleanupErrors.Add(
                    'The azd process tree did not stop within ten seconds after wrapper cancellation.')
            }
        }
    }
    catch {
        $cleanupErrors.Add("Unable to terminate the azd process tree: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $process) {
            try {
                $process.Dispose()
            }
            catch {
                $cleanupErrors.Add("Unable to release azd process handles: $($_.Exception.Message)")
            }
        }
    }
}
$elapsed.Stop()
if ($null -ne $executionError) {
    foreach ($cleanupError in $cleanupErrors) {
        Write-Warning "Additional cleanup failure: $cleanupError"
    }
    throw $executionError
}
if ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join ' ')
}
if ($processExitCode -ne 0) {
    throw "azd up failed with exit code $processExitCode. Inspect the reported stage and ownership evidence before retrying the same environment. If abandoning it, run .\scripts\Invoke-AzdDown.ps1 -EnvironmentName '$Environment' -Purge -Force as documented under 'Operations and rollback' in docs\DEPLOYMENT.md."
}

if (!(Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "azd reported success, but environment '$Environment' has no persisted .env file. The installation is incomplete."
}
$values = Read-AzdEnvironmentFile -Path $environmentPath
if ([string]$values['W365_AZD_UP_POSTUP_RUN_ID'] -ne $runId) {
    throw "azd returned success, but the current post-deployment workflow did not complete. Inspect the reported stage and ownership evidence before retrying the same environment. If abandoning it, run .\scripts\Invoke-AzdDown.ps1 -EnvironmentName '$Environment' -Purge -Force as documented under 'Operations and rollback' in docs\DEPLOYMENT.md."
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
if ([string]$values['W365_AGENT_REDEPLOY_PENDING'] -cne 'false') {
    $missing.Add('W365_AGENT_REDEPLOY_PENDING=false')
}
if ([string]$values['W365_AGENT_REDEPLOY_CHECK_PENDING'] -cne 'false') {
    $missing.Add('W365_AGENT_REDEPLOY_CHECK_PENDING=false')
}
if ($missing.Count -gt 0) {
    throw "azd core deployment returned success, but the complete sample installation is unfinished. Missing completion state: $($missing -join ', '). Inspect the reported stage and ownership evidence before retrying the same environment. If abandoning it, run .\scripts\Invoke-AzdDown.ps1 -EnvironmentName '$Environment' -Purge -Force as documented under 'Operations and rollback' in docs\DEPLOYMENT.md."
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
}
finally {
    $environmentLock.Dispose()
}
