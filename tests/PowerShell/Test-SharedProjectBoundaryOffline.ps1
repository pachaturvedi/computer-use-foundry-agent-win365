#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$viewerProject = Get-Content -LiteralPath (
    Join-Path $root 'src\Win365Viewer\Win365Viewer.csproj') -Raw
$agentProject = Get-Content -LiteralPath (
    Join-Path $root 'src\Win365Agent\Win365Agent.csproj') -Raw
$dockerfile = Get-Content -LiteralPath (Join-Path $root 'Dockerfile') -Raw

$sharedReference = '..\Win365Shared\Win365Shared.csproj'
if ($viewerProject -notmatch [regex]::Escape($sharedReference) -or
    $agentProject -notmatch [regex]::Escape($sharedReference)) {
    throw 'Both executable projects must reference Win365Shared.'
}
if ($viewerProject -match [regex]::Escape('..\Win365Agent\Win365Agent.csproj')) {
    throw 'Win365Viewer must not reference the Win365Agent executable project.'
}
if ($dockerfile -notmatch [regex]::Escape('COPY src/Win365Shared/Win365Shared.csproj src/Win365Shared/') -or
    $dockerfile -notmatch [regex]::Escape('COPY src/Win365Shared/ src/Win365Shared/')) {
    throw 'The viewer Docker build must restore and copy Win365Shared.'
}
if ($dockerfile -match [regex]::Escape('COPY src/Win365Agent/')) {
    throw 'The viewer Docker build must not copy Win365Agent source.'
}

Write-Output 'Offline shared boundary: agent and viewer depend on Win365Shared without executable-to-executable coupling.'
