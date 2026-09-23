#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\ViewerConfiguration.ps1')

$valid = @{
    DeployState = 'true'
    StateResourceGroupName = 'sample-state-rg'
    StateStorageAccountName = 'samplestorage'
    StateContainerName = 'desktop-state'
    SessionBlobUri = 'https://samplestorage.blob.core.windows.net/desktop-state/slot.json'
}
Assert-ViewerSharedStateConfiguration @valid
Assert-ViewerManagedEnvironmentResourceId -ResourceId ''
Assert-ViewerManagedEnvironmentResourceId -ResourceId `
    '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/managedEnvironments/shared-cae'
Assert-ViewerCredentialMode -CredentialMode 'client_secret'
Assert-ViewerCredentialMode -CredentialMode 'managed_identity_federation'
Assert-ViewerCredentialMode -CredentialMode 'key_vault_certificate'
Assert-ViewerIdentityModeConfiguration `
    -CredentialMode 'client_secret' `
    -ViewerPrincipalId '' `
    -OwnershipManifestPath (Join-Path ([IO.Path]::GetTempPath()) 'absent-viewer-manifest.json')
Assert-ViewerIdentityModeConfiguration `
    -CredentialMode 'key_vault_certificate' `
    -ViewerPrincipalId '22222222-2222-2222-2222-222222222222' `
    -OwnershipManifestPath (Join-Path ([IO.Path]::GetTempPath()) 'absent-viewer-manifest.json')
if ((Get-ViewerOidcRedirectUri -ViewerPublicUrl 'https://viewer.example.com') -ne
    'https://viewer.example.com/signin-oidc') {
    throw 'Viewer OIDC redirect URI was not constructed correctly.'
}

foreach ($invalid in @(
    @{ DeployState = 'false' },
    @{ StateStorageAccountName = 'otherstorage' },
    @{ StateContainerName = 'other-state' },
    @{ SessionBlobUri = 'http://samplestorage.blob.core.windows.net/desktop-state/slot.json' },
    @{ SessionBlobUri = 'https://samplestorage.blob.core.windows.net/desktop-state/other.json' },
    @{ SessionBlobUri = 'https://samplestorage.blob.core.windows.net/desktop-state/slot.json?token=value' }
)) {
    $arguments = @{} + $valid
    foreach ($entry in $invalid.GetEnumerator()) {
        $arguments[$entry.Key] = $entry.Value
    }
    $failed = $false
    try {
        Assert-ViewerSharedStateConfiguration @arguments
    }
    catch {
        $failed = $true
    }
    if (!$failed) {
        throw "Invalid shared-state configuration was accepted: $($invalid | ConvertTo-Json -Compress)"
    }
}

$invalidEnvironmentAccepted = $false
try {
    Assert-ViewerManagedEnvironmentResourceId -ResourceId `
        '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.App/containerApps/not-an-environment'
    $invalidEnvironmentAccepted = $true
}
catch {}
if ($invalidEnvironmentAccepted) {
    throw 'An invalid managed-environment resource ID was accepted.'
}

$invalidCredentialModeAccepted = $false
try {
    Assert-ViewerCredentialMode -CredentialMode 'automatic'
    $invalidCredentialModeAccepted = $true
}
catch {}
if ($invalidCredentialModeAccepted) {
    throw 'An invalid viewer blueprint credential mode was accepted.'
}

$manifestPath = Join-Path ([IO.Path]::GetTempPath()) "viewer-config-$([guid]::NewGuid()).json"
try {
    $principalId = '22222222-2222-2222-2222-222222222222'
    @{
        graph = @{
            federatedIdentityCredentials = @{
                "w365-viewer-$principalId" = @{
                    subject = $principalId
                }
            }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath
    Assert-ViewerIdentityModeConfiguration `
        -CredentialMode 'managed_identity_federation' `
        -ViewerPrincipalId $principalId `
        -OwnershipManifestPath $manifestPath

    $missingFederationAccepted = $false
    try {
        Assert-ViewerIdentityModeConfiguration `
            -CredentialMode 'managed_identity_federation' `
            -ViewerPrincipalId '33333333-3333-3333-3333-333333333333' `
            -OwnershipManifestPath $manifestPath
        $missingFederationAccepted = $true
    }
    catch {}
    if ($missingFederationAccepted) {
        throw 'Managed-identity viewer mode was accepted without its exact federation.'
    }
}
finally {
    Remove-Item -LiteralPath $manifestPath -ErrorAction SilentlyContinue
}

foreach ($invalidViewerUrl in @(
    'http://viewer.example.com',
    'https://viewer.example.com/path',
    'https://viewer.example.com?query=value',
    'https://user@viewer.example.com'
)) {
    $accepted = $false
    try {
        Get-ViewerOidcRedirectUri -ViewerPublicUrl $invalidViewerUrl | Out-Null
        $accepted = $true
    }
    catch {}
    if ($accepted) {
        throw "Invalid viewer public URL '$invalidViewerUrl' was accepted."
    }
}

Write-Output 'Offline viewer configuration: exact shared Blob state validation passed.'
