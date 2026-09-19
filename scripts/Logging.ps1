#Requires -Version 7.4

Set-StrictMode -Version Latest

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

    Write-SampleVerbose -Component $ScriptName -Message 'Started.'
    $safeParameters = ConvertTo-SampleSafeLogParameters -Parameters $Parameters
    Write-SampleDebug `
        -Component $ScriptName `
        -Message "Parameters: $($safeParameters | ConvertTo-Json -Compress -Depth 5)"
}
