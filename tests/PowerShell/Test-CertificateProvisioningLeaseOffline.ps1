#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'scripts\W365CertificateProvisioning.ps1')

$global:probeCalls = 0
$global:deleteCalls = 0
$global:probeBehavior = 'success'
$global:deleteFails = $false

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        return ''
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'create') {
        return '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/temporary'
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'delete') {
        $global:deleteCalls++
        if ($global:deleteFails) {
            $global:LASTEXITCODE = 1
        }
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

function New-TestLease {
    [pscustomobject]@{
        SubscriptionId = [guid]'11111111-1111-1111-1111-111111111111'
        VaultName = 'sample-vault'
        VaultId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample/providers/Microsoft.KeyVault/vaults/sample-vault'
        OperatorObjectId = [guid]'22222222-2222-2222-2222-222222222222'
        TemporaryRoleAssignmentId = '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/temporary'
    }
}

function Get-PrimaryError {
    try {
        throw 'primary certificate failure'
    }
    catch {
        return $_
    }
}

try {
    $global:probeBehavior = 'transient'
    $lease = Enter-W365CertificateOfficerLease `
        -SubscriptionId '11111111-1111-1111-1111-111111111111' `
        -VaultName sample-vault `
        -VaultId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample/providers/Microsoft.KeyVault/vaults/sample-vault' `
        -OperatorObjectId '22222222-2222-2222-2222-222222222222' `
        -ConfirmResourceChanges `
        -PropagationAttempts 3 `
        -PropagationDelaySeconds 0
    if ($global:probeCalls -ne 3 -or [string]::IsNullOrWhiteSpace($lease.TemporaryRoleAssignmentId)) {
        throw 'Transient authorization propagation was not retried deterministically.'
    }
    Exit-W365CertificateOfficerLease -Lease $lease

    $global:deleteCalls = 0
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.Cancel()
    $canceled = $false
    try {
        Enter-W365CertificateOfficerLease `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -VaultName sample-vault `
            -VaultId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample/providers/Microsoft.KeyVault/vaults/sample-vault' `
            -OperatorObjectId '22222222-2222-2222-2222-222222222222' `
            -ConfirmResourceChanges `
            -CancellationToken $cancellation.Token | Out-Null
    }
    catch {
        $canceled = $_.Exception -is [OperationCanceledException] -or
            $_.Exception.InnerException -is [OperationCanceledException]
    }
    if (!$canceled -or $global:deleteCalls -ne 1) {
        throw 'Cancellation did not stop propagation and clean up the temporary role.'
    }

    foreach ($behavior in @('terminal', 'timeout')) {
        $global:probeCalls = 0
        $global:deleteCalls = 0
        $global:probeBehavior = $behavior
        $failed = $false
        try {
            Enter-W365CertificateOfficerLease `
                -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -VaultName sample-vault `
                -VaultId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample/providers/Microsoft.KeyVault/vaults/sample-vault' `
                -OperatorObjectId '22222222-2222-2222-2222-222222222222' `
                -ConfirmResourceChanges `
                -PropagationAttempts 3 `
                -PropagationDelaySeconds 0 | Out-Null
        }
        catch {
            $failed = $true
        }
        $expectedCalls = if ($behavior -eq 'terminal') { 1 } else { 3 }
        if (!$failed -or $global:probeCalls -ne $expectedCalls -or $global:deleteCalls -ne 1) {
            throw "$behavior propagation failure was not terminal/bounded with cleanup."
        }
    }

    $global:deleteFails = $false
    $primary = Get-PrimaryError
    $primaryOnly = $null
    try {
        Complete-W365CertificateOfficerLease -Lease (New-TestLease) -PrimaryError $primary
    }
    catch {
        $primaryOnly = $_
    }
    if ($null -eq $primaryOnly -or $primaryOnly.Exception.Message -ne 'primary certificate failure') {
        throw 'Primary failure was not preserved when cleanup succeeded.'
    }

    $global:deleteFails = $true
    $aggregate = $null
    try {
        Complete-W365CertificateOfficerLease -Lease (New-TestLease) -PrimaryError (Get-PrimaryError)
    }
    catch {
        $aggregate = $_
    }
    if ($aggregate.Exception -isnot [AggregateException] -or
        $aggregate.Exception.InnerExceptions.Count -ne 2 -or
        $aggregate.Exception.InnerExceptions[0].Message -ne 'primary certificate failure') {
        throw 'Primary and cleanup failures were not retained in an aggregate error.'
    }

    $cleanupOnly = $null
    try {
        Complete-W365CertificateOfficerLease -Lease (New-TestLease)
    }
    catch {
        $cleanupOnly = $_
    }
    if ($null -eq $cleanupOnly -or $cleanupOnly.Exception.Message -notmatch 'Unable to revoke') {
        throw 'Cleanup failure after successful work did not fail explicitly.'
    }
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Variable probeCalls, deleteCalls, probeBehavior, deleteFails -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Certificate officer lease offline tests passed.'
