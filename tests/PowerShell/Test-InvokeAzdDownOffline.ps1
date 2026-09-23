#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path (Join-Path $repoRoot 'scripts') 'Invoke-AzdDown.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("invoke-azd-down-{0}" -f ([guid]::NewGuid()))
$environmentFilePath = Join-Path $tempRoot '.env'
$ownershipManifestPath = Join-Path $tempRoot 'missing-ownership.json'
$commandLogPath = Join-Path $tempRoot 'azd-commands.log'
$azCommandLogPath = Join-Path $tempRoot 'az-commands.log'
$deletedMarkerPath = Join-Path $tempRoot 'group-deleted.marker'
$fakeAzdFileName = if ($IsWindows) { 'azd.cmd' } else { 'azd' }
$fakeAzFileName = if ($IsWindows) { 'az.cmd' } else { 'az' }
$fakeAzdPath = Join-Path $tempRoot $fakeAzdFileName
$fakeAzPath = Join-Path $tempRoot $fakeAzFileName

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath $environmentFilePath -Value @(
        'AZURE_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"'
        'W365_ENABLED="false"'
    )

    if ($IsWindows) {
        Set-Content -LiteralPath $fakeAzdPath -Value @(
            '@echo off'
            'if "%1"=="version" (echo azd version 1.34.1 ^(commit offline-test^) & exit /b 0)'
            "echo %*>>`"$commandLogPath`""
            'if "%2"=="viewer" (echo ERROR: deleting infrastructure: error deleting Azure resources: deployment not found 1>&2 & exit /b 1)'
            'if "%2"=="state" if "%AZD_OFFLINE_STATE_FAILURE%"=="true" (echo ERROR: authorization failed 1>&2 & exit /b 1)'
            'exit /b 0'
        )
        Set-Content -LiteralPath $fakeAzPath -Value @(
            '@echo off'
            "echo %*>>`"$azCommandLogPath`""
            'if "%1"=="account" (echo 00000000-0000-0000-0000-000000000000 & exit /b 0)'
            "if `"%1`"==`"group`" if `"%2`"==`"delete`" if `"%AZD_OFFLINE_REMAINING_GROUP_ONCE%`"==`"true`" (echo done>`"$deletedMarkerPath`")"
            'if "%1"=="group" if "%2"=="delete" exit /b 0'
            "if `"%1`"==`"group`" if `"%2`"==`"list`" if exist `"$deletedMarkerPath`" exit /b 0"
            'if "%1"=="group" if "%2"=="list" if "%AZD_OFFLINE_REMAINING_GROUP%"=="true" (echo sample-dev-rg & exit /b 0)'
            'if "%1"=="group" if "%2"=="list" if "%AZD_OFFLINE_REMAINING_GROUP_ONCE%"=="true" (echo sample-dev-rg & exit /b 0)'
            'if "%1"=="group" if "%2"=="list" exit /b 0'
            'exit /b 0'
        )
    }
    else {
        $escapedLogPath = $commandLogPath.Replace("'", "'\''")
        Set-Content -LiteralPath $fakeAzdPath -Value @"
#!/bin/sh
if [ "`$1" = "version" ]; then
  echo "azd version 1.34.1 (commit offline-test)"
  exit 0
fi
printf '%s\n' "`$*" >> '$escapedLogPath'
if [ "`$2" = "viewer" ]; then
  echo "ERROR: deleting infrastructure: error deleting Azure resources: deployment not found" >&2
  exit 1
fi
if [ "`$2" = "state" ] && [ "`$AZD_OFFLINE_STATE_FAILURE" = "true" ]; then
  echo "ERROR: authorization failed" >&2
  exit 1
fi
exit 0
"@
        $escapedAzLogPath = $azCommandLogPath.Replace("'", "'\''")
        $escapedMarkerPath = $deletedMarkerPath.Replace("'", "'\''")
        Set-Content -LiteralPath $fakeAzPath -Value @"
#!/bin/sh
printf '%s\n' "`$*" >> '$escapedAzLogPath'
if [ "`$1" = "account" ]; then
  echo "00000000-0000-0000-0000-000000000000"
  exit 0
fi
if [ "`$1" = "group" ] && [ "`$2" = "delete" ]; then
  if [ "`$AZD_OFFLINE_REMAINING_GROUP_ONCE" = "true" ]; then
    echo done > '$escapedMarkerPath'
  fi
  exit 0
fi
if [ "`$1" = "group" ] && [ "`$2" = "list" ]; then
  if [ -f '$escapedMarkerPath' ]; then
    exit 0
  fi
  if [ "`$AZD_OFFLINE_REMAINING_GROUP" = "true" ] || [ "`$AZD_OFFLINE_REMAINING_GROUP_ONCE" = "true" ]; then
    echo "sample-dev-rg"
  fi
  exit 0
fi
exit 0
"@
        $executableMode = [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        [IO.File]::SetUnixFileMode($fakeAzdPath, $executableMode)
        [IO.File]::SetUnixFileMode($fakeAzPath, $executableMode)
    }

    $output = @(
        & $scriptPath `
            -EnvironmentName 'sample-dev' `
            -EnvironmentFilePath $environmentFilePath `
            -OwnershipManifestPath $ownershipManifestPath `
            -AzdPath $fakeAzdPath `
            -AzureCliPath $fakeAzPath `
            -Force *>&1
    )
    $outputText = ($output | Out-String)
    if ($outputText -notmatch "The 'viewer' deployment is already absent" -or
        $outputText -notmatch "Teardown completed for 'sample-dev'") {
        throw "Recoverable missing-layer output was incomplete: $outputText"
    }

    $commands = @(Get-Content -LiteralPath $commandLogPath)
    $expectedCommands = @(
        'down viewer --environment sample-dev --force --purge'
        'down state --environment sample-dev --force --purge'
        'down foundry --environment sample-dev --force --purge'
    )
    if ($commands.Count -ne $expectedCommands.Count -or
        (Compare-Object -ReferenceObject $expectedCommands -DifferenceObject $commands -SyncWindow 0)) {
        throw "Layer teardown order was unexpected: $($commands -join ' | ')"
    }

    Remove-Item -LiteralPath $commandLogPath -Force
    $env:AZD_OFFLINE_STATE_FAILURE = 'true'
    $nonMissingFailureBlocked = $false
    try {
        & $scriptPath `
            -EnvironmentName 'sample-dev' `
            -EnvironmentFilePath $environmentFilePath `
            -OwnershipManifestPath $ownershipManifestPath `
            -AzdPath $fakeAzdPath `
            -AzureCliPath $fakeAzPath `
            -Force *>&1 | Out-Null
    }
    catch {
        $nonMissingFailureBlocked = $_.Exception.Message -match 'authorization failed'
    }
    finally {
        $env:AZD_OFFLINE_STATE_FAILURE = $null
    }
    if (!$nonMissingFailureBlocked) {
        throw 'A non-missing azd layer failure did not stop teardown.'
    }
    $failedCommands = @(Get-Content -LiteralPath $commandLogPath)
    if ($failedCommands.Count -ne 2 -or $failedCommands[1] -notmatch '^down state ') {
        throw "Teardown continued after a non-recoverable state failure: $($failedCommands -join ' | ')"
    }

    Remove-Item -LiteralPath $commandLogPath -Force
    Remove-Item -LiteralPath $azCommandLogPath -Force -ErrorAction SilentlyContinue
    $env:AZD_OFFLINE_REMAINING_GROUP = 'true'
    $remainingGroupBlocked = $false
    try {
        & $scriptPath `
            -EnvironmentName 'sample-dev' `
            -EnvironmentFilePath $environmentFilePath `
            -OwnershipManifestPath $ownershipManifestPath `
            -AzdPath $fakeAzdPath `
            -AzureCliPath $fakeAzPath `
            -ResidualGroupPollAttempts 2 `
            -ResidualGroupPollDelaySeconds 0 `
            -Force *>&1 | Out-Null
    }
    catch {
        $remainingGroupBlocked = $_.Exception.Message -match 'sample-dev-rg' -and
            $_.Exception.Message -match 'after fallback deletion'
    }
    finally {
        $env:AZD_OFFLINE_REMAINING_GROUP = $null
    }
    if (!$remainingGroupBlocked) {
        throw 'Teardown reported success, or reported an unexpected error, while a managed resource group remained after the fallback deletion attempt.'
    }
    $azCommandsAfterFailedFallback = @(Get-Content -LiteralPath $azCommandLogPath)
    if (@($azCommandsAfterFailedFallback | Where-Object { $_ -match '^group delete --name sample-dev-rg\b' }).Count -eq 0) {
        throw "Fallback resource group deletion was not attempted: $($azCommandsAfterFailedFallback -join ' | ')"
    }

    Remove-Item -LiteralPath $commandLogPath -Force
    Remove-Item -LiteralPath $azCommandLogPath -Force -ErrorAction SilentlyContinue
    $env:AZD_OFFLINE_REMAINING_GROUP_ONCE = 'true'
    $fallbackOutput = $null
    try {
        $fallbackOutput = @(
            & $scriptPath `
                -EnvironmentName 'sample-dev' `
                -EnvironmentFilePath $environmentFilePath `
                -OwnershipManifestPath $ownershipManifestPath `
                -AzdPath $fakeAzdPath `
                -AzureCliPath $fakeAzPath `
                -ResidualGroupPollAttempts 2 `
                -ResidualGroupPollDelaySeconds 0 `
                -Force *>&1
        )
    }
    finally {
        $env:AZD_OFFLINE_REMAINING_GROUP_ONCE = $null
    }
    $fallbackOutputText = ($fallbackOutput | Out-String)
    if ($fallbackOutputText -notmatch "Requested direct deletion of resource group 'sample-dev-rg'" -or
        $fallbackOutputText -notmatch "Teardown completed for 'sample-dev'") {
        throw "Successful fallback resource group deletion output was incomplete: $fallbackOutputText"
    }
    $azCommandsAfterSuccessfulFallback = @(Get-Content -LiteralPath $azCommandLogPath)
    if (@($azCommandsAfterSuccessfulFallback | Where-Object { $_ -match '^group delete --name sample-dev-rg\b' }).Count -eq 0) {
        throw "Successful fallback deletion did not invoke 'az group delete': $($azCommandsAfterSuccessfulFallback -join ' | ')"
    }

    Write-Output 'Offline azd teardown recovery: missing-layer continuation, strict error propagation, and residual-resource fallback deletion (success and still-remaining cases) passed.'
}
finally {
    $env:AZD_OFFLINE_STATE_FAILURE = $null
    $env:AZD_OFFLINE_REMAINING_GROUP = $null
    $env:AZD_OFFLINE_REMAINING_GROUP_ONCE = $null
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
