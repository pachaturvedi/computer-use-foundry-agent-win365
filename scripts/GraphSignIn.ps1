#Requires -Version 7.4
<#
.SYNOPSIS
Provides shared Microsoft Graph delegated sign-in helpers.

.DESCRIPTION
Microsoft Graph enforces its own device-code inactivity window and it cannot be extended from Connect-MgGraph, so the only useful lever is reissuing the code. This module centralizes context validation, the device-code retry, and the optional device-code fallback so every interactive sign-in behaves the same way.

Key inputs: Connect-MgGraph parameters, required tenant and scopes, an interactive device-code switch, and a bounded attempt count.

.OUTPUTS
The resulting Microsoft Graph context.

.NOTES
Dot-source library. It never logs tokens, device codes, or credentials.
#>
Set-StrictMode -Version Latest

function Test-GraphContext {
    param(
        $Context,
        [guid]$RequiredTenantId,
        [string[]]$RequiredScopes
    )

    if ($null -eq $Context) {
        return $false
    }
    if ($RequiredTenantId -ne [guid]::Empty -and $Context.TenantId -ne $RequiredTenantId.ToString()) {
        return $false
    }
    if ($Context.AuthType -ne 'Delegated') {
        return $false
    }

    $missingScopes = @($RequiredScopes | Where-Object { $_ -notin $Context.Scopes })
    return @($missingScopes).Count -eq 0
}

function Test-IsDeviceCodeTimeoutError {
    param([Parameter(Mandatory)]$ErrorRecord)

    return [string]$ErrorRecord.Exception.Message -match 'Authentication timed out after \d+ seconds? due to inactivity'
}

function Write-W365DeviceCodeGuidance {
    param(
        [Parameter(Mandatory)][string]$Purpose,
        [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 3
    )

    Write-Host ''
    Write-Host "Microsoft Graph administrator sign-in is required $Purpose."
    Write-Host 'When the device code appears:'
    Write-Host '  1. Open https://login.microsoft.com/device in a browser.'
    Write-Host '  2. Enter the displayed code and sign in with the authorized tenant administrator.'
    Write-Host '  3. Complete the prompt before the code expires; the caller waits for the result.'
    Write-Host "     A timed-out code is reissued automatically up to $DeviceCodeMaxAttempts times."
    Write-Host ''
}

function Connect-W365GraphContext {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ConnectParameters,
        [switch]$UseDeviceCode,
        [switch]$FallbackToDeviceCode,
        [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 3
    )

    $parameters = @{}
    foreach ($entry in $ConnectParameters.GetEnumerator()) {
        $parameters[[string]$entry.Key] = $entry.Value
    }

    if ($UseDeviceCode) {
        $parameters.UseDeviceCode = $true
        $parameters.InformationAction = 'Continue'

        for ($attempt = 1; $attempt -le $DeviceCodeMaxAttempts; $attempt++) {
            try {
                Write-Host "Starting Microsoft Graph device-code sign-in attempt $attempt of $DeviceCodeMaxAttempts..."
                Connect-MgGraph @parameters | Out-Host
                return Get-MgContext
            }
            catch {
                if (!(Test-IsDeviceCodeTimeoutError -ErrorRecord $_) -or $attempt -eq $DeviceCodeMaxAttempts) {
                    throw
                }

                Write-Warning 'Microsoft Graph device-code sign-in timed out. Retrying with a fresh code...'
            }
        }
    }

    if (!$FallbackToDeviceCode) {
        Connect-MgGraph @parameters | Out-Host
        return Get-MgContext
    }

    try {
        Connect-MgGraph @parameters | Out-Host
        return Get-MgContext
    }
    catch {
        Write-Warning 'Interactive Microsoft Graph sign-in failed. Falling back to device-code sign-in...'
        return Connect-W365GraphContext `
            -ConnectParameters $parameters `
            -UseDeviceCode `
            -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
    }
}


