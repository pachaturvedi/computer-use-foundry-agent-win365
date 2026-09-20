#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $repositoryRoot 'scripts\Recover-StaleDesktopState.ps1'
if (!$IsWindows) {
    $platformOutput = & pwsh -NoLogo -NoProfile -File $scriptPath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $platformOutput -notmatch 'recovery is Windows-only') {
        throw "Recovery helper did not enforce its Windows platform guard: $platformOutput"
    }
    Write-Output 'Stale-state recovery helper: Windows platform guard passed.'
    return
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("stale-recovery-{0}" -f ([guid]::NewGuid()))
$mockAzd = Join-Path $tempRoot 'azd.ps1'
$mockDotNet = Join-Path $tempRoot 'dotnet.ps1'
$callLog = Join-Path $tempRoot 'calls.jsonl'
$powerShellExecutable = (Get-Process -Id $PID).Path

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
@{ tool = 'azd'; arguments = $Arguments } | ConvertTo-Json -Compress -Depth 5 |
    Add-Content -LiteralPath $env:MOCK_RECOVERY_CALLS
$global:LASTEXITCODE = 0
if ($Arguments[0] -eq 'env' -and $Arguments[1] -eq 'get-value') {
    $values = @{
        SESSION_BLOB_URI = 'https://stateacct.blob.core.windows.net/desktop-state/slot.json'
        W365_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        W365_BLUEPRINT_ID = '22222222-2222-2222-2222-222222222222'
        W365_AGENT_ID = '33333333-3333-3333-3333-333333333333'
        W365_AGENT_USER_ID = '44444444-4444-4444-4444-444444444444'
        W365_BLUEPRINT_CREDENTIAL_MODE = if (
            [string]::IsNullOrWhiteSpace($env:MOCK_RECOVERY_CREDENTIAL_MODE)
        ) { 'client_secret' } else { $env:MOCK_RECOVERY_CREDENTIAL_MODE }
        W365_KEY_VAULT_NAME = 'private-vault'
        OPERATOR_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        OPERATOR_OBJECT_ID = '55555555-5555-5555-5555-555555555555'
        FOUNDRY_AGENT_NAME = 'deployed-agent'
    }
    $values[$Arguments[2]]
    return
}
if ($Arguments[0] -eq 'ai' -and $Arguments[2] -eq 'sessions') {
    switch ($env:MOCK_RECOVERY_SESSION_MODE) {
        'running' { '{"sessions":[{"status":"Running","id":"must-not-print"}]}' }
        'unknown' { '{"sessions":[{"status":"Provisioning","id":"must-not-print"}]}' }
        'paged' { '{"sessions":[],"paginationToken":"must-not-print"}' }
        'nestedPaged' { '{"data":{"items":[],"pagination":{"nextToken":"must-not-print"}}}' }
        'blank' { '{"items":[{"status":"  ","id":"must-not-print"}]}' }
        'mixed' { '{"sessions":[],"items":[]}' }
        'array' { '[{"status":"STOPPED","id":"must-not-print"}]' }
        'items' { '{"items":[{"status":" deleted ","id":"must-not-print"}]}' }
        'value' { '{"value":[{"status":"Expired","id":"must-not-print"}]}' }
        'nested' { '{"data":{"sessions":[{"status":"Idle","id":"must-not-print"}]}}' }
        default { '{"data":[{"status":"idle","agent_session_id":"must-not-print"}]}' }
    }
    return
}
throw 'Unexpected mock azd command.'
'@ | Set-Content -LiteralPath $mockAzd

    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
@{
    tool = 'dotnet'
    arguments = $Arguments
    hasBlob = ![string]::IsNullOrWhiteSpace($env:SESSION_BLOB_URI)
} | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $env:MOCK_RECOVERY_CALLS
'Mock C# recovery completed without displaying state.'
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $mockDotNet

    $env:MOCK_RECOVERY_CALLS = $callLog
    $env:MOCK_RECOVERY_SESSION_MODE = 'stopped'
    $readOnlyOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzd `
        -DotNetPath $mockDotNet 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $readOnlyOutput -notmatch 'read-only inspection') {
        throw "Recovery helper read-only path failed: $readOnlyOutput"
    }
    $calls = @(Get-Content -LiteralPath $callLog | ForEach-Object { ConvertFrom-Json $_ })
    $dotnetCall = @($calls | Where-Object tool -eq 'dotnet')
    if ($dotnetCall.Count -ne 1 -or
        '--apply' -in @($dotnetCall[0].arguments) -or
        !$dotnetCall[0].hasBlob) {
        throw 'Read-only recovery did not construct the safe C# inspection command.'
    }
    $sessionCall = @($calls | Where-Object {
        $_.tool -eq 'azd' -and $_.arguments[2] -eq 'sessions'
    })
    if ($sessionCall.Count -ne 1 -or
        '--user-identity' -in @($sessionCall[0].arguments) -or
        '--output' -notin @($sessionCall[0].arguments) -or
        $sessionCall[0].arguments[5] -ne 'deployed-agent' -or
        '--version' -in @($sessionCall[0].arguments)) {
        throw 'Recovery helper did not perform the required hosted-session check.'
    }
    if ($readOnlyOutput -match 'must-not-print|stateacct|private-vault') {
        throw 'Recovery helper exposed an identifier or private configuration.'
    }

    Clear-Content -LiteralPath $callLog
    $env:MOCK_RECOVERY_CREDENTIAL_MODE = 'key_vault_certificate'
    $certificateOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzd `
        -DotNetPath $mockDotNet 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $certificateOutput -notmatch 'read-only inspection') {
        throw "Recovery helper certificate-mode path failed: $certificateOutput"
    }
    $certificateCalls = @(
        Get-Content -LiteralPath $callLog | ForEach-Object { ConvertFrom-Json $_ }
    )
    $vaultReads = @($certificateCalls | Where-Object {
        $_.tool -eq 'azd' -and
        $_.arguments[0] -eq 'env' -and
        $_.arguments[1] -eq 'get-value' -and
        $_.arguments[2] -eq 'W365_KEY_VAULT_NAME'
    })
    if ($vaultReads.Count -ne 1) {
        throw 'Recovery helper did not load the deployed Key Vault binding for certificate mode.'
    }
    $env:MOCK_RECOVERY_CREDENTIAL_MODE = 'client_secret'

    Clear-Content -LiteralPath $callLog
    $applyOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzd `
        -DotNetPath $mockDotNet `
        -Apply `
        -Confirm:$false 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Recovery helper apply path failed: $applyOutput"
    }
    $applyCalls = @(Get-Content -LiteralPath $callLog | ForEach-Object { ConvertFrom-Json $_ })
    $applyDotNet = @($applyCalls | Where-Object tool -eq 'dotnet')
    if ($applyDotNet.Count -ne 1 -or
        '--apply' -notin @($applyDotNet[0].arguments) -or
        '--hosted-sessions-verified' -in @($applyDotNet[0].arguments) -or
        '--environment' -notin @($applyDotNet[0].arguments) -or
        'demo-dev' -notin @($applyDotNet[0].arguments)) {
        throw 'Recovery helper did not bind mutation to the selected environment.'
    }

    Clear-Content -LiteralPath $callLog
    $whatIfOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
        -Environment demo-dev `
        -AzdPath $mockAzd `
        -DotNetPath $mockDotNet `
        -Apply `
        -WhatIf 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $whatIfOutput -notmatch 'What if:') {
        throw "Recovery helper WhatIf path failed: $whatIfOutput"
    }
    $whatIfCalls = @(Get-Content -LiteralPath $callLog | ForEach-Object { ConvertFrom-Json $_ })
    $whatIfDotNet = @($whatIfCalls | Where-Object tool -eq 'dotnet')
    if ($whatIfDotNet.Count -gt 1 -or
        ($whatIfDotNet.Count -eq 1 -and '--apply' -in @($whatIfDotNet[0].arguments))) {
        throw 'Recovery helper WhatIf reached the mutating C# command.'
    }

    foreach ($safeMode in @('array', 'items', 'value', 'nested')) {
        Clear-Content -LiteralPath $callLog
        $env:MOCK_RECOVERY_SESSION_MODE = $safeMode
        $safeOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
            -Environment demo-dev `
            -AzdPath $mockAzd `
            -DotNetPath $mockDotNet 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $safeOutput -notmatch 'read-only inspection') {
            throw "Recovery helper rejected accepted session schema '$safeMode': $safeOutput"
        }
    }

    foreach ($unsafeMode in @('running', 'unknown', 'paged', 'nestedPaged', 'blank', 'mixed')) {
        Clear-Content -LiteralPath $callLog
        $env:MOCK_RECOVERY_SESSION_MODE = $unsafeMode
        $unsafeOutput = & $powerShellExecutable -NoLogo -NoProfile -File $scriptPath `
            -Environment demo-dev `
            -AzdPath $mockAzd `
            -DotNetPath $mockDotNet `
            -Apply `
            -Confirm:$false 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $unsafeOutput -notmatch 'Recovery blocked:') {
            throw "Recovery helper accepted unsafe hosted-session mode '$unsafeMode'."
        }
        $unsafeCalls = @(Get-Content -LiteralPath $callLog | ForEach-Object { ConvertFrom-Json $_ })
        if (@($unsafeCalls | Where-Object tool -eq 'dotnet').Count -ne 0) {
            throw "Recovery helper reached state inspection for unsafe mode '$unsafeMode'."
        }
        if ($unsafeOutput -match 'must-not-print') {
            throw "Recovery helper exposed protected data for unsafe mode '$unsafeMode'."
        }
    }

    Write-Output 'Stale-state recovery helper: deployed binding, schemas, read-only default, and explicit mutation passed.'
}
finally {
    Remove-Item Env:\MOCK_RECOVERY_CALLS -ErrorAction SilentlyContinue
    Remove-Item Env:\MOCK_RECOVERY_CREDENTIAL_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\MOCK_RECOVERY_SESSION_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
