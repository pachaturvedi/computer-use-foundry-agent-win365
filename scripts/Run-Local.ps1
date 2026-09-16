#Requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('agent', 'viewer')][string]$Mode = 'agent', [string]$EnvFile = '.env')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
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
    $args = @('run', '--project', "$root\src\Win365Agent\Win365Agent.csproj", '--no-launch-profile')
    if ($Mode -eq 'viewer') { $args += @('--', '--viewer') }
    & dotnet @args
    if ($LASTEXITCODE -ne 0) { throw "Sample process exited with code $LASTEXITCODE." }
}
finally {
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
}
