#Requires -Version 7.4
<#
.SYNOPSIS
Provides redacted logging helpers for repository PowerShell scripts.

.DESCRIPTION
Normalizes summary, verbose, and debug logging; removes sensitive parameter values before diagnostic output; and initializes consistent script-level telemetry context.


Key inputs: Log level environment settings and parameter dictionaries supplied to exported functions.

.OUTPUTS
Formatted host, verbose, and debug messages containing sanitized metadata only.

.NOTES
Dot-source library. It must never emit credentials, tokens, raw session identifiers, or private links.
#>
Set-StrictMode -Version Latest

function Get-SampleLogLevel {
    $level = if ([string]::IsNullOrWhiteSpace($env:SAMPLE_LOG_LEVEL)) {
        'summary'
    }
    else {
        $env:SAMPLE_LOG_LEVEL.Trim().ToLowerInvariant()
    }
    if ($level -notin @('summary', 'verbose', 'debug')) {
        throw "SAMPLE_LOG_LEVEL must be summary, verbose, or debug; received '$level'."
    }
    return $level
}

function ConvertTo-SampleSafeLogParameters {
    param([System.Collections.IDictionary]$Parameters)

    $safe = [ordered]@{}
    foreach ($entry in $Parameters.GetEnumerator() | Sort-Object Key) {
        $name = [string]$entry.Key
        $value = $entry.Value
        if ($name -match '(?i)secret|token|password|credential|certificate|privatekey') {
            $safe[$name] = '<redacted>'
        }
        elseif ($value -is [securestring]) {
            $safe[$name] = '<secure-string>'
        }
        elseif ($value -is [System.Array]) {
            $safe[$name] = "<$($value.Count) item(s)>"
        }
        elseif ($null -eq $value) {
            $safe[$name] = '<null>'
        }
        else {
            $safe[$name] = [string]$value
        }
    }
    return $safe
}

function Write-SampleVerbose {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Verbose ('[{0:HH:mm:ss}] [{1}] {2}' -f [DateTimeOffset]::Now, $Component, $Message)
}

function Write-SampleDebug {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Debug ('[{0:HH:mm:ss.fff}] [{1}] {2}' -f [DateTimeOffset]::Now, $Component, $Message)
}

function Initialize-SampleScriptLogging {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [System.Collections.IDictionary]$Parameters = @{}
    )

    $level = Get-SampleLogLevel
    if ($level -in @('verbose', 'debug')) {
        Set-Variable -Name VerbosePreference -Value Continue -Scope 1
        $VerbosePreference = 'Continue'
    }
    if ($level -eq 'debug') {
        Set-Variable -Name DebugPreference -Value Continue -Scope 1
        $DebugPreference = 'Continue'
    }

    Write-SampleVerbose -Component $ScriptName -Message "Started with log level '$level'."
    $safeParameters = ConvertTo-SampleSafeLogParameters -Parameters $Parameters
    Write-SampleDebug `
        -Component $ScriptName `
        -Message "Parameters: $($safeParameters | ConvertTo-Json -Compress -Depth 5)"
}
