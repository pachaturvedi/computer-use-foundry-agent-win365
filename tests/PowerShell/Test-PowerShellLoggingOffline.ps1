#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'scripts\Logging.ps1')

$previousVerbose = $VerbosePreference
$previousDebug = $DebugPreference
try {
    $VerbosePreference = 'Continue'
    $DebugPreference = 'Continue'
    $messages = & {
        Initialize-SampleScriptLogging -ScriptName 'LoggingTest.ps1' -Parameters @{
            Environment = 'sample-dev'
            BlueprintClientSecret = 'must-not-appear'
            AccessToken = 'must-not-appear'
            CertificatePassword = 'must-not-appear'
        }
    } 4>&1 5>&1 | Out-String
}
finally {
    $VerbosePreference = $previousVerbose
    $DebugPreference = $previousDebug
}

if ($messages -notmatch 'Started' -or
    $messages -notmatch 'Parameters' -or
    $messages -notmatch 'sample-dev' -or
    $messages -notmatch '<redacted>') {
    throw "Verbose/debug logging did not include the expected sanitized context: $messages"
}
if ($messages -match 'must-not-appear') {
    throw 'Verbose/debug logging exposed a secret, token, or certificate password.'
}

$missing = foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Filter *.ps1) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $hasVerbose = $text -match 'Initialize-SampleScriptLogging|Write-SampleVerbose|Write-Verbose'
    $hasDebug = $text -match 'Initialize-SampleScriptLogging|Write-SampleDebug|Write-Debug'
    if (!$hasVerbose -or !$hasDebug) {
        $file.Name
    }
}
if (@($missing).Count -gt 0) {
    throw "Production scripts missing verbose/debug logging: $($missing -join ', ')."
}

Write-Host 'PowerShell logging offline tests passed.'
