#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'scripts\W365CertificateProvisioning.ps1')

$subscriptionId = '11111111-1111-1111-1111-111111111111'
$operatorObjectId = '22222222-2222-2222-2222-222222222222'
$vaultId = "/subscriptions/$subscriptionId/resourceGroups/sample/providers/Microsoft.KeyVault/vaults/sample-vault"
$existingAssignmentId = "$vaultId/providers/Microsoft.Authorization/roleAssignments/existing"

$global:probeCalls = 0
$global:createCalls = 0
$global:deleteCalls = 0
$global:listCalls = 0
$global:probeBehavior = 'success'
$global:existingAssignment = ''

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        $global:listCalls++
        return $global:existingAssignment
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'create') {
        $global:createCalls++
        return "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/granted"
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'delete') {
        $global:deleteCalls++
        return
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'certificate' -and $arguments[2] -eq 'list') {
        $global:probeCalls++
        switch ($global:probeBehavior) {
            'transient' {
                if ($global:probeCalls -lt 3) {
                    $global:LASTEXITCODE = 1
                    return 'Forbidden: Caller is not authorized because RBAC propagation is pending.'
                }
            }
            'terminal' {
                $global:LASTEXITCODE = 1
                return 'Network connection refused.'
            }
            'timeout' {
                $global:LASTEXITCODE = 1
                return 'AuthorizationFailed: RBAC propagation is pending.'
            }
        }
        return
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

function Reset-AccessMocks {
    param([string]$Behavior = 'success', [string]$Existing = '')

    $global:probeCalls = 0
    $global:createCalls = 0
    $global:deleteCalls = 0
    $global:listCalls = 0
    $global:probeBehavior = $Behavior
    $global:existingAssignment = $Existing
}

function Invoke-Grant {
    param([hashtable]$Extra = @{})

    $parameters = @{
        SubscriptionId = $subscriptionId
        VaultName = 'sample-vault'
        VaultId = $vaultId
        OperatorObjectId = $operatorObjectId
        PropagationAttempts = 3
        PropagationDelaySeconds = 0
    }
    foreach ($entry in $Extra.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }
    return Grant-W365CertificateOfficerAccess @parameters
}

try {
    # The role is granted once and the bounded propagation wait tolerates RBAC replication lag.
    Reset-AccessMocks -Behavior 'transient'
    $access = Invoke-Grant -Extra @{ ConfirmResourceChanges = $true }
    if ($global:createCalls -ne 1) {
        throw 'Certificates Officer access was not granted exactly once.'
    }
    if ($global:probeCalls -ne 3) {
        throw 'Transient authorization propagation was not retried deterministically.'
    }
    if ($access.AlreadyPresent -or $access.AcquisitionSkipped) {
        throw 'A newly granted assignment was reported as pre-existing or skipped.'
    }
    if ([string]::IsNullOrWhiteSpace($access.RoleAssignmentId)) {
        throw 'The granted role assignment ID was not returned.'
    }

    # Access is permanent: nothing is ever revoked, on success or on any failure path.
    if ($global:deleteCalls -ne 0) {
        throw 'A permanent Certificates Officer assignment was revoked.'
    }

    # A run that already holds the role makes no change and does not re-probe.
    Reset-AccessMocks -Existing $existingAssignmentId
    $reused = Invoke-Grant -Extra @{ ConfirmResourceChanges = $true }
    if ($global:createCalls -ne 0) {
        throw 'An existing Certificates Officer assignment was granted again.'
    }
    if ($global:probeCalls -ne 0) {
        throw 'An existing Certificates Officer assignment triggered an unnecessary access probe.'
    }
    if (!$reused.AlreadyPresent -or $reused.RoleAssignmentId -ne $existingAssignmentId) {
        throw 'A pre-existing assignment was not reported as already present.'
    }

    # Without explicit authorization the missing role fails closed instead of granting silently.
    Reset-AccessMocks
    $refused = $false
    try { Invoke-Grant | Out-Null } catch { $refused = $true }
    if (!$refused -or $global:createCalls -ne 0) {
        throw 'A missing role was granted without -ConfirmResourceChanges.'
    }

    # Terminal and bounded-timeout probe failures surface, and the grant is deliberately retained
    # so the next run reuses it instead of re-granting.
    foreach ($behavior in @('terminal', 'timeout')) {
        Reset-AccessMocks -Behavior $behavior
        $failed = $false
        try { Invoke-Grant -Extra @{ ConfirmResourceChanges = $true } | Out-Null } catch { $failed = $true }
        $expectedProbes = if ($behavior -eq 'terminal') { 1 } else { 3 }
        if (!$failed -or $global:probeCalls -ne $expectedProbes) {
            throw "$behavior propagation failure was not terminal and bounded."
        }
        if ($global:deleteCalls -ne 0) {
            throw "$behavior propagation failure revoked the permanent assignment."
        }
    }

    # Cancellation stops the wait without revoking the granted access.
    Reset-AccessMocks -Behavior 'timeout'
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.Cancel()
    $canceled = $false
    try {
        Invoke-Grant -Extra @{ ConfirmResourceChanges = $true; CancellationToken = $cancellation.Token } | Out-Null
    }
    catch {
        $canceled = $_.Exception -is [OperationCanceledException] -or
            $_.Exception.InnerException -is [OperationCanceledException]
    }
    if (!$canceled) { throw 'Cancellation did not stop the propagation wait.' }
    if ($global:deleteCalls -ne 0) {
        throw 'Cancellation revoked the permanent assignment.'
    }

    # The revoking lease model must not come back: it strips the access that later runs depend on.
    foreach ($removed in @(
            'Enter-W365CertificateOfficerLease',
            'Exit-W365CertificateOfficerLease',
            'Complete-W365CertificateOfficerLease')) {
        if (Get-Command $removed -ErrorAction SilentlyContinue) {
            throw "$removed still exists; Certificates Officer access must be permanent, not leased."
        }
    }
    $provisioningText = Get-Content -LiteralPath (Join-Path $root 'scripts\W365CertificateProvisioning.ps1') -Raw
    if ($provisioningText -match 'role assignment.*delete|az role assignment delete') {
        throw 'The certificate provisioning helper can still revoke a Certificates Officer assignment.'
    }
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Variable probeCalls, createCalls, deleteCalls, listCalls, probeBehavior, existingAssignment `
        -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Certificate officer access offline tests passed.'
