#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ConfigureOidcScriptPath = (Join-Path $PSScriptRoot 'Configure-ViewerOidc.ps1'),
    [string]$RoleSetupScriptPath = (Join-Path $PSScriptRoot 'Set-ViewerKeyVaultRoles.ps1'),
    [string]$ViewerBootstrapScriptPath = (Join-Path $PSScriptRoot 'Deploy-ViewerBootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'W365Provisioning.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$root = Split-Path $PSScriptRoot
$azd = Get-W365AzdCommand
if (!$azd) {
    throw 'azd 1.32.0 or later is required.'
}
if (![string]::IsNullOrWhiteSpace($Environment)) {
    Invoke-W365Azd -Azd $azd -Arguments @('env', 'select', $Environment) | Out-Null
}
$environmentName = Get-W365AzdValue -Azd $azd -Name 'AZURE_ENV_NAME'

Write-SampleVerbose -Component 'viewer-activation' -Message 'Reconciling least-privilege Key Vault RBAC.'
& $RoleSetupScriptPath -Environment $environmentName
if (!$?) {
    throw 'Viewer Key Vault RBAC setup failed.'
}

Write-SampleVerbose -Component 'viewer-activation' -Message 'Creating or reconciling the viewer OIDC application and credential.'
& $ConfigureOidcScriptPath -Environment $environmentName -UseDeviceCode
if (!$?) {
    throw 'Viewer OIDC configuration failed.'
}

Write-SampleVerbose -Component 'viewer-activation' -Message 'Enabling live viewer configuration in the selected azd environment.'
Invoke-W365Azd -Azd $azd -Arguments @(
    'env', 'set', 'VIEWER_LIVE_ENABLED', 'true'
) | Out-Null
Write-SampleVerbose -Component 'viewer-activation' -Message 'Reprovisioning the existing viewer with Key Vault secret references.'
Invoke-W365Azd -Azd $azd -Arguments @(
    'provision', 'viewer', '--no-prompt'
) | Out-Null

$environmentPath = Join-Path $root ".azure\$environmentName\.env"
Write-SampleDebug -Component 'viewer-activation' -Message "Reloading generated azd outputs from $environmentPath."
$values = Read-AzdEnvironmentFile -Path $environmentPath
foreach ($entry in $values.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
}

Write-SampleVerbose -Component 'viewer-activation' -Message 'Deploying the viewer image and verifying its health endpoint.'
& $ViewerBootstrapScriptPath
if (!$?) {
    throw 'Viewer image deployment failed after live activation.'
}

Write-Host "Live viewer activation completed for '$($values['VIEWER_PUBLIC_URL'])'."
