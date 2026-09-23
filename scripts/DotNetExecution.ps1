#Requires -Version 7.4
<#
.SYNOPSIS
Provides shared dotnet command execution.

.DESCRIPTION
Runs dotnet with caller-supplied arguments and converts a nonzero process exit
code into a terminating PowerShell error with the attempted command.

Key inputs: the argument array passed to dotnet.

.OUTPUTS
The underlying dotnet command output.

.NOTES
Dot-source library. Callers remain responsible for SDK and workload validation.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'DotNetExecution' -Message 'Loaded shared dotnet process execution.'
Write-SampleDebug -Component 'DotNetExecution' -Message 'Nonzero dotnet exit codes are always surfaced as terminating errors.'

function Invoke-DotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}
