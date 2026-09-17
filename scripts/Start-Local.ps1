#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateRange(5, 120)]
    [int]$StartupTimeoutSeconds = 45,
    [ValidateRange(1, 65535)]
    [int]$AgentPort = 8088,
    [ValidateRange(1, 65535)]
    [int]$ViewerPort = 5050
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$IsWindows) {
    throw 'This launcher is Windows-only. Use Windows with PowerShell 7.4 or later.'
}

$root = Split-Path $PSScriptRoot
$envFile = Join-Path $root '.env'
$localFolder = Join-Path $root '.local'
$pwsh = (Get-Process -Id $PID).Path

if (!(Test-Path -LiteralPath $envFile)) {
    throw 'Missing .env. Run .\scripts\Setup-Local.ps1 first.'
}
if ($AgentPort -eq $ViewerPort) {
    throw 'AgentPort and ViewerPort must be different.'
}

foreach ($port in @($AgentPort, $ViewerPort)) {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($listener) {
        throw "Local port $port is already in use by process $($listener.OwningProcess). Stop it or choose another port."
    }
}

New-Item -ItemType Directory -Path $localFolder -Force | Out-Null

function Start-SampleProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('agent', 'viewer')][string]$Mode
    )

    $stdout = Join-Path $localFolder "$Mode.log"
    $stderr = Join-Path $localFolder "$Mode.error.log"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    $arguments = @(
        '-NoProfile',
        '-File', (Join-Path $PSScriptRoot 'Run-Local.ps1'),
        '-Mode', $Mode,
        '-EnvFile', $envFile,
        '-AgentPort', $AgentPort,
        '-ViewerPort', $ViewerPort
    )
    Start-Process -FilePath $pwsh -ArgumentList $arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
}

function Wait-ForHealth {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][Diagnostics.Process]$Process
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        if ($Process.HasExited) {
            throw "$Name exited during startup. Check .local\$($Name.ToLowerInvariant()).error.log."
        }
        try {
            $response = Invoke-RestMethod -Uri $Uri -TimeoutSec 2
            if ($response.status -eq 'healthy') {
                return
            }
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "$Name did not become healthy within $StartupTimeoutSeconds seconds."
}

$agent = $null
$viewer = $null
try {
    $agent = Start-SampleProcess -Mode agent
    $viewer = Start-SampleProcess -Mode viewer

    $agentHealth = "http://localhost:$AgentPort/health"
    $viewerHealth = "http://localhost:$ViewerPort/health"
    Wait-ForHealth -Name 'Agent' -Uri $agentHealth -Process $agent
    Wait-ForHealth -Name 'Viewer' -Uri $viewerHealth -Process $viewer

    Write-Host ''
    Write-Host 'Windows 365 Foundry sample is running locally.'
    Write-Host "  Agent health:  $agentHealth"
    Write-Host "  Viewer health: $viewerHealth"
    Write-Host '  Logs:          .local\'
    Write-Host ''
    Write-Host 'Local mode intentionally returns HTTP 503 for desktop/Responses requests.'
    Write-Host 'Press Ctrl+C to stop both processes.'

    while (!$agent.HasExited -and !$viewer.HasExited) {
        Start-Sleep -Seconds 1
    }
    throw 'A sample process exited unexpectedly. Check the .local logs.'
}
finally {
    foreach ($process in @($agent, $viewer)) {
        if ($null -ne $process -and !$process.HasExited) {
            Stop-Process -Id $process.Id
            $process.WaitForExit(5000)
        }
    }
}
