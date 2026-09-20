#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('agent', 'viewer')][string]$Mode = 'agent',
    [string]$EnvFile = '.env',
    [ValidateRange(1, 65535)][int]$AgentPort = 8088,
    [ValidateRange(1, 65535)][int]$ViewerPort = 5050
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
$path = (Resolve-Path -LiteralPath $EnvFile).Path
$previous = @{}
try {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $line = $line.Trim()
        if (!$line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { throw 'Invalid .env line; expected KEY=value. Shell expressions are not supported.' }
        $key = $Matches[1]; $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1, $value.Length - 2) }
        if (!$previous.ContainsKey($key)) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
        if ($null -eq $previous[$key]) { [Environment]::SetEnvironmentVariable($key, $value) }
    }
    if ($env:SAMPLE_LOCAL_MODE -ne 'true') { throw 'This launcher requires SAMPLE_LOCAL_MODE=true. Hosted mode uses platform configuration.' }
    if ($env:W365_ENABLED -eq 'true') { throw 'Local runs support bootstrap/offline development only. Deploy phase 2 to use the Foundry identity for W365.' }
    foreach ($key in @('ASPNETCORE_ENVIRONMENT', 'DOTNET_ENVIRONMENT')) {
        if (!$previous.ContainsKey($key)) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
        [Environment]::SetEnvironmentVariable($key, 'Development')
    }
    foreach ($setting in @{
        LOCAL_AGENT_PORT = $AgentPort.ToString()
        LOCAL_VIEWER_PORT = $ViewerPort.ToString()
    }.GetEnumerator()) {
        if (!$previous.ContainsKey($setting.Key)) {
            $previous[$setting.Key] = [Environment]::GetEnvironmentVariable($setting.Key)
        }
        [Environment]::SetEnvironmentVariable($setting.Key, $setting.Value)
    }
    $project = if ($Mode -eq 'viewer') {
        "$root\src\Win365Viewer\Win365Viewer.csproj"
    }
    else {
        "$root\src\Win365Agent\Win365Agent.csproj"
    }
    $args = @(
        'run',
        '--project', $project,
        '--configuration', 'Release',
        '--no-build',
        '--no-restore',
        '--no-launch-profile'
    )
    & dotnet @args
    if ($LASTEXITCODE -ne 0) { throw "Sample process exited with code $LASTEXITCODE." }
}
finally {
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
}
