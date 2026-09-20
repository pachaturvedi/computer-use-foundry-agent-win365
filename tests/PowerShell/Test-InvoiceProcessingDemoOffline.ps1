#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot 'scripts\Invoke-InvoiceProcessingDemo.ps1'
if (!$IsWindows) {
    $platformOutput = & pwsh -NoLogo -NoProfile -File $scriptPath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or
        $platformOutput -notmatch 'invoice-processing demo is Windows-only') {
        throw "Invoice demo helper did not enforce its Windows platform guard: $platformOutput"
    }
    Write-Output 'Invoice demo helper: Windows platform guard passed.'
    return
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("invoice-demo-{0}" -f ([guid]::NewGuid()))
$mockAzdPath = Join-Path $tempRoot 'azd.ps1'
$callLogPath = Join-Path $tempRoot 'calls.jsonl'
$viewerToken = 'Live_task-ABC_123'
$sessionId = 'b' * 64
$sessionGuid = '123e4567-e89b-42d3-a456-426614174000'
$powerShellExecutable = (Get-Process -Id $PID).Path

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

@{ arguments = $Arguments } | ConvertTo-Json -Compress -Depth 5 |
    Add-Content -LiteralPath $env:MOCK_INVOICE_DEMO_CALLS
$global:LASTEXITCODE = 0

if ($Arguments[0] -eq 'env' -and $Arguments[1] -eq 'get-value') {
    switch ($Arguments[2]) {
        'AZURE_ENV_NAME' { 'demo-dev' }
        'W365_ENABLED' { 'true' }
        'VIEWER_LIVE_ENABLED' { 'true' }
        'VIEWER_PUBLIC_URL' { 'https://viewer.example.com' }
        'AGENT_WIN365_DESKTOP_AGENT_VERSION' { '42' }
        default { throw "Unexpected env value '$($Arguments[2])'." }
    }
    return
}

if ($Arguments[0] -eq 'ai' -and $Arguments[1] -eq 'agent' -and $Arguments[2] -eq 'invoke') {
    $prompt = $Arguments[-1]
    $fileMatch = [regex]::Match($prompt, 'Invoice-Processing-Summary-[a-f0-9]{32}\.txt')
    ''
    "Session: $('b' * 64)"
    "Session ID: $env:MOCK_INVOICE_DEMO_SESSION_GUID"
    '{"session_id":"alternate_session-id","conversationId":"123e4567-e89b-42d3-a456-426614174000"}'
    switch ($env:MOCK_INVOICE_DEMO_MODE) {
        'no-viewer' { }
        'viewer-query' { '[win365-desktop-agent] [watch](https://viewer.example.com/live/Live_task-ABC_123?secret=value).' }
        'viewer-fragment' { '[win365-desktop-agent] [watch](https://viewer.example.com/live/Live_task-ABC_123#control).' }
        default { '[win365-desktop-agent] [watch](https://viewer.example.com/live/Live_task-ABC_123).' }
    }
    switch ($env:MOCK_INVOICE_DEMO_MODE) {
        'failed' { 'DEMO_RESULT: FAILED; REASON: simulated blocker' }
        'embedded-marker' { "prefix DEMO_RESULT: SUCCESS; FILE: $($fileMatch.Value)" }
        'duplicate-marker' {
            "DEMO_RESULT: SUCCESS; FILE: $($fileMatch.Value)"
            "DEMO_RESULT: SUCCESS; FILE: $($fileMatch.Value)"
        }
        'trailing-marker' {
            "DEMO_RESULT: SUCCESS; FILE: $($fileMatch.Value)"
            'provider trailer'
        }
        'missing-marker' { 'Agent completed without a marker.' }
        'mismatch-marker' { 'DEMO_RESULT: SUCCESS; FILE: wrong.txt' }
        'provider-failure' {
            'Provider disconnected before completion.'
            exit 17
        }
        default { "DEMO_RESULT: SUCCESS; FILE: $($fileMatch.Value)" }
    }
    return
}

if ($Arguments[0] -eq 'ai' -and $Arguments[1] -eq 'agent' -and $Arguments[2] -eq 'show') {
    if ($env:MOCK_INVOICE_DEMO_SHOW_MODE -eq 'malformed') {
        '{not-json'
        return
    }
    $endpoint = switch ($env:MOCK_INVOICE_DEMO_SHOW_MODE) {
        'host' { 'https://untrusted.example/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?api-version=v1' }
        'path' { 'https://sample.services.ai.azure.com/api/projects/demo/agents/other/endpoint/protocols/openai/responses?api-version=v1' }
        'query' { 'https://sample.services.ai.azure.com/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?API-VERSION=v1' }
        'userinfo' { 'https://user@sample.services.ai.azure.com/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?api-version=v1' }
        'port' { 'https://sample.services.ai.azure.com:8443/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?api-version=v1' }
        'fragment' { 'https://sample.services.ai.azure.com/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?api-version=v1#unsafe' }
        default { 'https://sample.services.ai.azure.com/api/projects/demo/agents/win365-desktop-agent/endpoint/protocols/openai/responses?api-version=v1' }
    }
    @{
        name = if ($env:MOCK_INVOICE_DEMO_SHOW_MODE -eq 'name') { 'other-agent' } else { 'win365-desktop-agent' }
        version = if ($env:MOCK_INVOICE_DEMO_SHOW_MODE -eq 'version') { '41' } else { '42' }
        status = if ($env:MOCK_INVOICE_DEMO_SHOW_MODE -eq 'status') { 'failed' } else { 'active' }
        agent_endpoints = @{
            responses = $endpoint
        }
        privateMarker = 'endpoint-json-must-not-be-printed'
    } | ConvertTo-Json -Compress -Depth 5
    return
}

throw "Unexpected azd arguments: $($Arguments -join ' ')"
'@ | Set-Content -LiteralPath $mockAzdPath

    $env:MOCK_INVOICE_DEMO_CALLS = $callLogPath
    $env:MOCK_INVOICE_DEMO_MODE = 'success'
    $env:MOCK_INVOICE_DEMO_SESSION_GUID = $sessionGuid
    $env:MOCK_INVOICE_DEMO_SHOW_MODE = 'valid'
    $output = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzdPath `
        -SkipOpenViewer 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Invoice demo helper failed unexpectedly: $output"
    }
    $savedFileMatch = [regex]::Match(
        $output,
        'Saved file: (?<file>Invoice-Processing-Summary-[a-f0-9]{32}\.txt)')
    if (!$savedFileMatch.Success -or
        $output -notmatch 'Human handoff: disabled' -or
        $output -notmatch 'Progress heartbeat: elapsed' -or
        $output -notmatch 'Invocation finished. Elapsed:' -or
        $output -notmatch 'Live viewer detected; browser launch was skipped') {
        throw "Invoice demo helper did not report the expected safe workflow: $output"
    }
    $expectedFile = $savedFileMatch.Groups['file'].Value
    if ($output.Contains("https://viewer.example.com/live/$viewerToken", [StringComparison]::Ordinal) -or
        $output.Contains($sessionId, [StringComparison]::Ordinal) -or
        $output.Contains($sessionGuid, [StringComparison]::Ordinal) -or
        $output.Contains('alternate_session-id', [StringComparison]::Ordinal) -or
        $output.Contains('endpoint-json-must-not-be-printed', [StringComparison]::Ordinal) -or
        $output.Contains('sample.services.ai.azure.com', [StringComparison]::Ordinal)) {
        throw 'Invoice demo helper exposed a raw viewer link or hosted session ID.'
    }

    $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object {
        ConvertFrom-Json -InputObject $_
    })
    $showCalls = @($calls | Where-Object {
        $_.arguments[0] -eq 'ai' -and $_.arguments[2] -eq 'show'
    })
    if ($showCalls.Count -ne 1 -or
        'win365-desktop-agent' -notin @($showCalls[0].arguments) -or
        'demo-dev' -notin @($showCalls[0].arguments)) {
        throw 'Invoice demo helper did not verify the named agent in the selected environment.'
    }
    $invokeCalls = @($calls | Where-Object { $_.arguments[0] -eq 'ai' })
    $invokeCalls = @($invokeCalls | Where-Object { $_.arguments[2] -eq 'invoke' })
    if ($invokeCalls.Count -ne 1) {
        throw "Expected exactly one invoice invocation, found $($invokeCalls.Count)."
    }
    $showIndex = [array]::IndexOf($calls, $showCalls[0])
    $invokeIndex = [array]::IndexOf($calls, $invokeCalls[0])
    if ($showIndex -lt 0 -or $invokeIndex -le $showIndex) {
        throw 'Invoice demo helper invoked before verifying the deployed endpoint.'
    }
    $invoke = $invokeCalls[0]
    $invokeArguments = @($invoke.arguments)
    foreach ($requiredArgument in @('--new-session', '--new-conversation', '42')) {
        if ($requiredArgument -notin $invokeArguments) {
            throw "Invoice invocation omitted '$requiredArgument'."
        }
    }
    $prompt = [string]$invokeArguments[-1]
    $expectedPrompt = (Get-Content -LiteralPath (
        Join-Path $repositoryRoot 'samples\prompts\invoice-processing.txt') -Raw).
        Replace(
            '{{INVOICE_URI}}',
            'https://invoicemgmt.blob.core.windows.net/invoices/Invoice_6.png',
            [StringComparison]::Ordinal).
        Replace('{{OUTPUT_FILE_NAME}}', $expectedFile, [StringComparison]::Ordinal)
    if ($prompt -cne $expectedPrompt) {
        throw 'Generated invoice prompt did not exactly preserve the canonical template.'
    }
    foreach ($requiredPromptText in @(
        'Do not pause, request human',
        'DEMO_RESULT: SUCCESS; FILE:',
        'DEMO_RESULT: FAILED; REASON:'
    )) {
        if (!$prompt.Contains($requiredPromptText, [StringComparison]::Ordinal)) {
            throw "Generated invoice prompt omitted '$requiredPromptText'."
        }
    }
    if ($prompt.Contains('{{', [StringComparison]::Ordinal)) {
        throw 'Generated invoice prompt retained an unresolved placeholder.'
    }

    $env:MOCK_INVOICE_DEMO_MODE = 'failed'
    $failureOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzdPath `
        -SkipOpenViewer 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or
        $failureOutput -notmatch 'agent reported that the invoice task failed') {
        throw "Invoice demo helper did not fail closed for an agent-reported failure: $failureOutput"
    }

    foreach ($runtimeMode in @(
        'embedded-marker',
        'duplicate-marker',
        'trailing-marker',
        'missing-marker',
        'mismatch-marker',
        'no-viewer',
        'viewer-query',
        'viewer-fragment',
        'provider-failure'
    )) {
        $env:MOCK_INVOICE_DEMO_MODE = $runtimeMode
        $runtimeOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
            -Environment demo-dev `
            -AzdPath $mockAzdPath `
            -SkipOpenViewer 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            throw "Invoice demo helper accepted invalid runtime mode '$runtimeMode'."
        }
        if ($runtimeMode -eq 'provider-failure' -and
            (!$runtimeOutput.Contains('unknown remote outcome', [StringComparison]::Ordinal) -or
            !$runtimeOutput.Contains('Recover-StaleDesktopState.ps1', [StringComparison]::Ordinal) -or
            !$runtimeOutput.Contains('-Apply', [StringComparison]::Ordinal))) {
            throw "Provider failure did not return actionable unknown-outcome recovery: $runtimeOutput"
        }
        if ($runtimeOutput.Contains("https://viewer.example.com/live/$viewerToken", [StringComparison]::Ordinal)) {
            throw "Runtime failure mode '$runtimeMode' exposed a usable viewer link."
        }
    }

    $env:MOCK_INVOICE_DEMO_MODE = 'success'
    $env:SAMPLE_LOG_LEVEL = 'debug'
    $debugOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzdPath `
        -InvoiceUri 'https://private.example/invoice.png' `
        -UserIdentity 'caller-sensitive-partition' `
        -SkipOpenViewer 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or
        $debugOutput.Contains('caller-sensitive-partition', [StringComparison]::Ordinal) -or
        $debugOutput.Contains('https://private.example/invoice.png', [StringComparison]::Ordinal)) {
        throw "Debug logging exposed sensitive invocation parameters: $debugOutput"
    }
    Remove-Item Env:\SAMPLE_LOG_LEVEL -ErrorAction SilentlyContinue

    $invalidInvoiceOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzdPath `
        -InvoiceUri 'https://private.example/invoice.png?sig=credential' `
        -SkipOpenViewer 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or
        $invalidInvoiceOutput.Contains('sig=credential', [StringComparison]::Ordinal)) {
        throw "Invoice demo helper accepted or exposed a credential-bearing invoice URI: $invalidInvoiceOutput"
    }

    function global:Start-Process {
        throw "browser rejected https://viewer.example.com/live/$viewerToken"
    }
    try {
        $browserError = $null
        try {
            & $scriptPath `
                -Environment demo-dev `
                -AzdPath $mockAzdPath 2>&1 | Out-Null
        }
        catch {
            $browserError = $_.Exception.Message
        }
        if ([string]::IsNullOrWhiteSpace($browserError) -or
            $browserError -notmatch 'default browser could not open the redacted live-view link' -or
            $browserError.Contains($viewerToken, [StringComparison]::Ordinal)) {
            throw "Browser-launch failure was not safely redacted: $browserError"
        }
    }
    finally {
        Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
    }

    foreach ($invalidMode in @(
        'malformed', 'name', 'version', 'status', 'host', 'path', 'query',
        'userinfo', 'port', 'fragment'
    )) {
        Clear-Content -LiteralPath $callLogPath
        $env:MOCK_INVOICE_DEMO_MODE = 'success'
        $env:MOCK_INVOICE_DEMO_SHOW_MODE = $invalidMode
        $invalidOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
            -Environment demo-dev `
            -AzdPath $mockAzdPath `
            -SkipOpenViewer 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            throw "Invoice demo helper accepted invalid endpoint mode '$invalidMode'."
        }
        $invalidCalls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object {
            ConvertFrom-Json -InputObject $_
        })
        if (@($invalidCalls | Where-Object {
            $_.arguments[0] -eq 'ai' -and $_.arguments[2] -eq 'invoke'
        }).Count -ne 0) {
            throw "Invoice demo helper invoked after endpoint validation failed for '$invalidMode'."
        }
        if ($invalidOutput.Contains('endpoint-json-must-not-be-printed', [StringComparison]::Ordinal) -or
            $invalidOutput.Contains('sample.services.ai.azure.com', [StringComparison]::Ordinal)) {
            throw "Invoice demo helper printed endpoint metadata for invalid mode '$invalidMode'."
        }
    }

    Write-Output 'Invoice demo helper: unique filename, no-handoff prompt, viewer redaction, and failure handling passed.'
}
finally {
    Remove-Item Env:\MOCK_INVOICE_DEMO_CALLS -ErrorAction SilentlyContinue
    Remove-Item Env:\MOCK_INVOICE_DEMO_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\MOCK_INVOICE_DEMO_SESSION_GUID -ErrorAction SilentlyContinue
    Remove-Item Env:\MOCK_INVOICE_DEMO_SHOW_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\SAMPLE_LOG_LEVEL -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
