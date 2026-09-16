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
    foreach ($key in @('ASPNETCORE_ENVIRONMENT', 'DOTNET_ENVIRONMENT')) {
        if (!$previous.ContainsKey($key)) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
        [Environment]::SetEnvironmentVariable($key, 'Development')
    }
    if ($env:SESSION_FILE -and ![IO.Path]::IsPathRooted($env:SESSION_FILE)) {
        if (!$previous.ContainsKey('SESSION_FILE')) { $previous['SESSION_FILE'] = $env:SESSION_FILE }
        $env:SESSION_FILE = [IO.Path]::GetFullPath((Join-Path $root $env:SESSION_FILE))
    }
    if ($env:W365_CERTIFICATE_PATH -and ![IO.Path]::IsPathRooted($env:W365_CERTIFICATE_PATH)) {
        if (!$previous.ContainsKey('W365_CERTIFICATE_PATH')) { $previous['W365_CERTIFICATE_PATH'] = $env:W365_CERTIFICATE_PATH }
        $env:W365_CERTIFICATE_PATH = [IO.Path]::GetFullPath((Join-Path $root $env:W365_CERTIFICATE_PATH))
    }
    $args = @('run', '--project', "$root\src\Win365Agent\Win365Agent.csproj", '--no-launch-profile')
    if ($Mode -eq 'viewer') { $args += @('--', '--viewer') }
    & dotnet @args
    if ($LASTEXITCODE -ne 0) { throw "Sample process exited with code $LASTEXITCODE." }
}
finally {
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
}
