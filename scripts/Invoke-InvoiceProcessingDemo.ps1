#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [ValidateNotNullOrEmpty()]
    [string]$AgentName = 'win365-desktop-agent',
    [uri]$InvoiceUri = 'https://invoicemgmt.blob.core.windows.net/invoices/Invoice_6.png',
    [ValidateRange(60, 3600)]
    [int]$TimeoutSeconds = 1200,
    [string]$UserIdentity,
    [switch]$SkipOpenViewer,
    [string]$AzdPath,
    [string]$PromptTemplatePath = (Join-Path (Split-Path $PSScriptRoot) 'samples\prompts\invoice-processing.txt')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
$safeLogParameters = [ordered]@{
    Environment = $Environment
    AgentName = $AgentName
    TimeoutSeconds = $TimeoutSeconds
    HasUserIdentity = ![string]::IsNullOrWhiteSpace($UserIdentity)
    SkipOpenViewer = $SkipOpenViewer.IsPresent
}
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $safeLogParameters

if (!$IsWindows) {
    throw 'The invoice-processing demo is Windows-only. Use PowerShell 7.4 or later on Windows.'
}
if ($InvoiceUri.Scheme -ne 'https' -or !$InvoiceUri.IsAbsoluteUri -or
    !$InvoiceUri.IsDefaultPort -or
    ![string]::IsNullOrWhiteSpace($InvoiceUri.UserInfo) -or
    ![string]::IsNullOrWhiteSpace($InvoiceUri.Query) -or
    ![string]::IsNullOrWhiteSpace($InvoiceUri.Fragment)) {
    throw 'InvoiceUri must be an absolute HTTPS URL without credentials, query, fragment, or a custom port.'
}
if (!(Test-Path -LiteralPath $PromptTemplatePath -PathType Leaf)) {
    throw "Invoice prompt template '$PromptTemplatePath' was not found."
}

function Invoke-DemoAzdValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$EnvironmentName
    )

    $arguments = @('env', 'get-value', $Name)
    if (![string]::IsNullOrWhiteSpace($EnvironmentName)) {
        $arguments += @('--environment', $EnvironmentName)
    }

    $global:LASTEXITCODE = 0
    $output = & $script:AzdExecutable @arguments 2>&1
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw "Unable to read azd environment value '$Name'. Select a deployed environment and retry."
    }

    return ($output | Out-String).Trim().Trim('"')
}

function Invoke-DemoAzdJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $global:LASTEXITCODE = 0
    $output = (& $script:AzdExecutable @Arguments 2>&1 | Out-String).Trim()
    if (!$? -or $LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the deployed hosted-agent endpoint from the selected azd environment.'
    }

    $jsonStart = $output.IndexOf('{', [StringComparison]::Ordinal)
    $jsonEnd = $output.LastIndexOf('}')
    if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
        throw 'The hosted-agent lookup did not return valid JSON.'
    }

    try {
        return $output.Substring($jsonStart, $jsonEnd - $jsonStart + 1) |
            ConvertFrom-Json -Depth 30
    }
    catch {
        throw 'The hosted-agent lookup returned malformed JSON.'
    }
}

function Get-LiveViewerUri {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][uri]$ViewerOrigin
    )

    foreach ($match in [regex]::Matches($Line, 'https://[^\s\)\]]+')) {
        $candidate = $null
        if (![uri]::TryCreate($match.Value, [UriKind]::Absolute, [ref]$candidate)) {
            continue
        }
        if ($candidate.Scheme -ne 'https' -or
            !$candidate.IsDefaultPort -or
            ![string]::IsNullOrWhiteSpace($candidate.UserInfo) -or
            ![string]::IsNullOrWhiteSpace($candidate.Query) -or
            ![string]::IsNullOrWhiteSpace($candidate.Fragment) -or
            $candidate.GetLeftPart([UriPartial]::Authority) -ne
                $ViewerOrigin.GetLeftPart([UriPartial]::Authority)) {
            continue
        }
        if ($candidate.AbsolutePath -cmatch '^/live/[A-Za-z0-9_-]{1,64}/?$') {
            return $candidate
        }
    }

    return $null
}

function Protect-DemoOutput {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][uri]$ViewerOrigin
    )

    $safe = [regex]::Replace(
        $Line,
        "$([regex]::Escape($ViewerOrigin.GetLeftPart([UriPartial]::Authority)))/(?:live|view)/[^\s\)\]]+",
        '<viewer-link-redacted>',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(?<label>\s*(?:agent\s+)?(?:session|conversation)(?:\s+id)?\s*[:=]\s*).+$',
        '${label}<redacted>',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $safe = [regex]::Replace(
        $safe,
        '(?i)(?<prefix>"(?:agent_)?(?:session|conversation)(?:_?id)?"\s*:\s*")[^"]*(?<suffix>")',
        '${prefix}<redacted>${suffix}')
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[a-f0-9]{64}\b',
        '<opaque-id-redacted>')
    return [regex]::Replace(
        $safe,
        '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
        '<identifier-redacted>')
}

function Get-DemoRecoveryMessage {
    param([Parameter(Mandatory)][string]$EnvironmentName)

    return @"
The hosted-agent invocation ended with an unknown remote outcome.
Do not rerun the demo until the previous desktop cleanup is proven.
1. Inspect sanitized hosted logs:
   azd ai agent monitor --environment "$EnvironmentName" --tail 100
2. Confirm that EndSession completed and that no "session slot remains blocked for operator recovery" event is present.
3. If cleanup is not proven, inspect safely:
   pwsh -NoProfile -File .\scripts\Recover-StaleDesktopState.ps1 -Environment "$EnvironmentName"
4. Only after inspection passes, explicitly clear unchanged stale state:
   pwsh -NoProfile -File .\scripts\Recover-StaleDesktopState.ps1 -Environment "$EnvironmentName" -Apply
"@
}

function Write-DemoInvocationLine {
    param([AllowEmptyString()][string]$Line)

    $trimmedLine = $Line.Trim()
    if (![string]::IsNullOrWhiteSpace($trimmedLine)) {
        $script:lastNonEmptyLine = $trimmedLine
    }
    if (!$script:viewerDetected) {
        $liveViewerUri = Get-LiveViewerUri -Line $Line -ViewerOrigin $script:viewerOrigin
        if ($null -ne $liveViewerUri) {
            $script:viewerDetected = $true
            if ($SkipOpenViewer) {
                Write-Host 'Live viewer detected; browser launch was skipped.'
            }
            else {
                try {
                    Start-Process -FilePath $liveViewerUri.AbsoluteUri
                    $script:browserOpened = $true
                    Write-Host 'Live viewer opened in the default browser for observation.'
                }
                catch {
                    $script:browserOpenFailed = $true
                    Write-Warning 'The live viewer could not be opened. The agent will continue to completion.'
                }
            }
        }
    }

    if ($trimmedLine.Contains('DEMO_RESULT:', [StringComparison]::Ordinal)) {
        $script:resultMarkerLines.Add($trimmedLine)
    }

    Write-Host (Protect-DemoOutput -Line $Line -ViewerOrigin $script:viewerOrigin)
}

function Invoke-DemoProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($Executable) -eq '.ps1') {
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.ArgumentList.Add('-NoLogo')
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-File')
        $startInfo.ArgumentList.Add($Executable)
    }
    else {
        $startInfo.FileName = $Executable
    }
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        if (!$started) {
            throw 'The hosted-agent invocation process did not start.'
        }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = [TimeSpan]::FromSeconds(15)
        $standardOutput = $process.StandardOutput.ReadLineAsync()
        $standardError = $process.StandardError.ReadLineAsync()
        Write-Host 'Invocation started. Progress heartbeat: elapsed 00:00.'
        while ($null -ne $standardOutput -or $null -ne $standardError -or !$process.HasExited) {
            if ($null -ne $standardOutput -and $standardOutput.IsCompleted) {
                $line = $standardOutput.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $standardOutput = $null
                }
                else {
                    Write-DemoInvocationLine -Line $line
                    $standardOutput = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $standardError -and $standardError.IsCompleted) {
                $line = $standardError.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $standardError = $null
                }
                else {
                    Write-DemoInvocationLine -Line $line
                    $standardError = $process.StandardError.ReadLineAsync()
                }
            }
            if ($stopwatch.Elapsed -ge $nextHeartbeat) {
                Write-Host ("Invocation in progress. Elapsed: {0:mm\:ss}." -f $stopwatch.Elapsed)
                $nextHeartbeat = $nextHeartbeat.Add([TimeSpan]::FromSeconds(15))
            }
            if (!$process.HasExited) {
                $null = $process.WaitForExit(100)
            }
        }

        $process.WaitForExit()
        Write-Host ("Invocation finished. Elapsed: {0:mm\:ss}." -f $stopwatch.Elapsed)
        return $process.ExitCode
    }
    finally {
        if ($started -and !$process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
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
$AzdExecutable = $resolvedAzd.Path

$repositoryRoot = Split-Path $PSScriptRoot
$previousUserAgent = $env:AZURE_DEV_USER_AGENT
Push-Location $repositoryRoot
try {
    $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'

    $environmentName = if ([string]::IsNullOrWhiteSpace($Environment)) {
        Invoke-DemoAzdValue -Name 'AZURE_ENV_NAME'
    }
    else {
        $Environment
    }
    if ([string]::IsNullOrWhiteSpace($environmentName)) {
        throw 'No azd environment is selected. Pass -Environment or run azd env select.'
    }

    $w365Enabled = Invoke-DemoAzdValue -Name 'W365_ENABLED' -EnvironmentName $environmentName
    if ($w365Enabled -cne 'true') {
        throw "Azd environment '$environmentName' does not have W365_ENABLED=true."
    }
    $viewerEnabled = Invoke-DemoAzdValue -Name 'VIEWER_LIVE_ENABLED' -EnvironmentName $environmentName
    if ($viewerEnabled -cne 'true') {
        throw "Azd environment '$environmentName' does not have VIEWER_LIVE_ENABLED=true."
    }

    $viewerUrl = Invoke-DemoAzdValue -Name 'VIEWER_PUBLIC_URL' -EnvironmentName $environmentName
    $viewerOrigin = $null
    if (![uri]::TryCreate($viewerUrl, [UriKind]::Absolute, [ref]$viewerOrigin) -or
        $viewerOrigin.Scheme -ne 'https' -or
        ![string]::IsNullOrWhiteSpace($viewerOrigin.UserInfo) -or
        ![string]::IsNullOrWhiteSpace($viewerOrigin.Query) -or
        ![string]::IsNullOrWhiteSpace($viewerOrigin.Fragment)) {
        throw "Azd environment '$environmentName' has an invalid VIEWER_PUBLIC_URL."
    }

    $version = Invoke-DemoAzdValue `
        -Name 'AGENT_WIN365_DESKTOP_AGENT_VERSION' `
        -EnvironmentName $environmentName
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Azd environment '$environmentName' does not identify a deployed agent version."
    }

    $agent = Invoke-DemoAzdJson -Arguments @(
        'ai', 'agent', 'show', $AgentName,
        '--environment', $environmentName,
        '--output', 'json'
    )
    $responsesEndpointText = [string]$agent.agent_endpoints.responses
    $responsesEndpoint = $null
    $expectedEndpointPath = '^/api/projects/[^/]+/agents/' +
        [regex]::Escape($AgentName) +
        '/endpoint/protocols/openai/responses$'
    if ([string]$agent.name -cne $AgentName -or
        [string]$agent.version -cne $version -or
        [string]$agent.status -cne 'active' -or
        ![uri]::TryCreate($responsesEndpointText, [UriKind]::Absolute, [ref]$responsesEndpoint) -or
        $responsesEndpoint.Scheme -ne 'https' -or
        ![string]::IsNullOrWhiteSpace($responsesEndpoint.UserInfo) -or
        !$responsesEndpoint.IsDefaultPort -or
        ![string]::IsNullOrWhiteSpace($responsesEndpoint.Fragment) -or
        !$responsesEndpoint.Host.EndsWith('.services.ai.azure.com', [StringComparison]::OrdinalIgnoreCase) -or
        $responsesEndpoint.AbsolutePath -cnotmatch $expectedEndpointPath -or
        $responsesEndpoint.Query -cne '?api-version=v1') {
        throw "Agent '$AgentName' version '$version' is not active on the expected Foundry Responses endpoint."
    }

    $runSuffix = [guid]::NewGuid().ToString('N')
    $outputFileName = "Invoice-Processing-Summary-$runSuffix.txt"
    $promptTemplate = Get-Content -LiteralPath $PromptTemplatePath -Raw
    foreach ($placeholder in @('{{INVOICE_URI}}', '{{OUTPUT_FILE_NAME}}')) {
        if (!$promptTemplate.Contains($placeholder, [StringComparison]::Ordinal)) {
            throw "Invoice prompt template is missing required placeholder '$placeholder'."
        }
    }
    $prompt = $promptTemplate.
        Replace('{{INVOICE_URI}}', $InvoiceUri.AbsoluteUri, [StringComparison]::Ordinal).
        Replace('{{OUTPUT_FILE_NAME}}', $outputFileName, [StringComparison]::Ordinal)

    Write-Host 'Invoice demo mode: live agent invocation; no Azure or Blob infrastructure will be provisioned or migrated.'
    Write-Host "Environment: $environmentName"
    Write-Host "Agent target: $AgentName version $version (active Responses endpoint verified)"
    Write-Host "Run suffix:  $runSuffix"
    Write-Host "Output file: $outputFileName"
    Write-Host 'Human handoff: disabled for this basic scenario; the viewer is observation-only.'

    $arguments = @(
        'ai', 'agent', 'invoke', $AgentName,
        '--environment', $environmentName,
        '--version', $version,
        '--new-session',
        '--new-conversation',
        '--timeout', [string]$TimeoutSeconds
    )
    if (![string]::IsNullOrWhiteSpace($UserIdentity)) {
        $arguments += @('--user-identity', $UserIdentity)
    }
    $arguments += $prompt

    $script:viewerOrigin = $viewerOrigin
    $script:viewerDetected = $false
    $script:browserOpened = $false
    $script:browserOpenFailed = $false
    $script:resultMarkerLines = [System.Collections.Generic.List[string]]::new()
    $script:lastNonEmptyLine = ''

    $invokeExitCode = Invoke-DemoProcess -Executable $AzdExecutable -Arguments $arguments

    if ($invokeExitCode -ne 0) {
        throw "$(Get-DemoRecoveryMessage -EnvironmentName $environmentName)`nProvider exit code: $invokeExitCode."
    }
    if (!$script:viewerDetected) {
        throw 'The invocation completed without returning the expected authenticated live-view link.'
    }
    if ($script:browserOpenFailed) {
        throw 'The agent completed, but the default browser could not open the redacted live-view link.'
    }
    if ($script:resultMarkerLines.Count -ne 1) {
        throw "The invocation returned $($script:resultMarkerLines.Count) result markers; exactly one terminal marker is required."
    }
    $resultMarker = $script:resultMarkerLines[0]
    if ($resultMarker -cne $script:lastNonEmptyLine) {
        throw 'The result marker was not the final non-empty invocation line.'
    }
    if ($resultMarker -cmatch '^DEMO_RESULT: FAILED; REASON: .{1,200}$') {
        throw 'The agent reported that the invoice task failed. Review the sanitized invocation output above.'
    }
    $expectedSuccessMarker = "DEMO_RESULT: SUCCESS; FILE: $outputFileName"
    if ($resultMarker -cne $expectedSuccessMarker) {
        throw "The invocation ended without confirming DEMO_RESULT: SUCCESS for '$outputFileName'."
    }

    $viewerStatus = if ($SkipOpenViewer) { 'detected' } elseif ($script:browserOpened) { 'opened' } else { 'not opened' }
    Write-Host "Invoice processing completed. Viewer: $viewerStatus. Saved file: $outputFileName"
}
finally {
    Pop-Location
    $env:AZURE_DEV_USER_AGENT = $previousUserAgent
}
