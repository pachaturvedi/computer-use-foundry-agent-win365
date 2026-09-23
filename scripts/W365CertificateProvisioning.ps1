Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'certificate-role-lease' -Message 'Loaded temporary Key Vault certificate role helpers.'
Write-SampleDebug -Component 'certificate-role-lease' -Message 'Role propagation retries are bounded and cleanup preserves primary failures.'

function Enter-W365CertificateOfficerLease {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][guid]$OperatorObjectId,
        [switch]$ConfirmResourceChanges,
        [ValidateRange(1, 30)][int]$PropagationAttempts = 8,
        [ValidateRange(0, 30)][int]$PropagationDelaySeconds = 2,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $roleId = 'a4417e6f-fecd-4de8-b567-7b0420556985'
    $roleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$roleId"
    $existing = & az role assignment list `
        --subscription $SubscriptionId `
        --scope $VaultId `
        --assignee-object-id $OperatorObjectId `
        --include-inherited `
        --query "[?roleDefinitionId=='$roleDefinitionId'].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Key Vault Certificates Officer on '$VaultName'."
    }

    $assignmentId = $null
    if ([string]::IsNullOrWhiteSpace(($existing | Out-String))) {
        if (!$ConfirmResourceChanges) {
            throw "The current operator lacks Key Vault Certificates Officer on '$VaultName'. Re-run with -ConfirmResourceChanges to grant it, or have an administrator grant it."
        }
        if (!$PSCmdlet.ShouldProcess("$OperatorObjectId on $VaultName", 'Grant temporary Key Vault Certificates Officer')) {
            return [pscustomobject]@{
                SubscriptionId = $SubscriptionId
                VaultName = $VaultName
                VaultId = $VaultId
                OperatorObjectId = $OperatorObjectId
                TemporaryRoleAssignmentId = $null
                AcquisitionSkipped = $true
            }
        }
        $assignmentId = (& az role assignment create `
            --subscription $SubscriptionId `
            --scope $VaultId `
            --assignee-object-id $OperatorObjectId `
            --assignee-principal-type User `
            --role $roleId `
            --query id `
            --output tsv | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($assignmentId)) {
            throw "Unable to grant Key Vault Certificates Officer on '$VaultName'."
        }

        $pendingLease = [pscustomobject]@{
            SubscriptionId = $SubscriptionId
            VaultName = $VaultName
            VaultId = $VaultId
            OperatorObjectId = $OperatorObjectId
            TemporaryRoleAssignmentId = $assignmentId
        }
        $propagationError = $null
        try {
            for ($attempt = 1; $attempt -le $PropagationAttempts; $attempt++) {
                $CancellationToken.ThrowIfCancellationRequested()
                $probeOutput = (& az keyvault certificate list `
                    --subscription $SubscriptionId `
                    --vault-name $VaultName `
                    --maxresults 1 `
                    --output none 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) {
                    break
                }
                $isAuthorizationFailure = $probeOutput -match
                    '(?i)(^|\W)(403|Forbidden|AuthorizationFailed|AccessDenied)(\W|$)|Caller is not authorized'
                $hasPropagationHint = $probeOutput -match
                    '(?i)RBAC propagation|role assignments?.*(changed recently|propagat)|observe propagation time'
                $isPropagationDelay = $isAuthorizationFailure -and $hasPropagationHint
                if (!$isPropagationDelay) {
                    throw "Key Vault certificate access probe failed with a terminal error for '$VaultName'."
                }
                if ($attempt -eq $PropagationAttempts) {
                    throw "Key Vault Certificates Officer was assigned on '$VaultName', but certificate access was not authorized after $PropagationAttempts bounded propagation attempts."
                }
                if ($PropagationDelaySeconds -gt 0 -and
                    $CancellationToken.WaitHandle.WaitOne([TimeSpan]::FromSeconds($PropagationDelaySeconds))) {
                    throw [OperationCanceledException]::new(
                        'Key Vault role propagation wait was canceled.',
                        $CancellationToken)
                }
            }
        }
        catch {
            $propagationError = $_
        }
        if ($null -ne $propagationError) {
            Complete-W365CertificateOfficerLease -Lease $pendingLease -PrimaryError $propagationError
        }
    }

    return [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        VaultName = $VaultName
        VaultId = $VaultId
        OperatorObjectId = $OperatorObjectId
        TemporaryRoleAssignmentId = $assignmentId
        AcquisitionSkipped = $false
    }
}

function Exit-W365CertificateOfficerLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lease)

    if ([string]::IsNullOrWhiteSpace([string]$Lease.TemporaryRoleAssignmentId)) {
        return
    }

    & az role assignment delete `
        --subscription $Lease.SubscriptionId `
        --ids $Lease.TemporaryRoleAssignmentId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to revoke the temporary Key Vault Certificates Officer assignment on '$($Lease.VaultName)'."
    }
    $Lease.TemporaryRoleAssignmentId = $null
}

function Complete-W365CertificateOfficerLease {
    [CmdletBinding()]
    param(
        $Lease,
        [System.Management.Automation.ErrorRecord]$PrimaryError
    )

    $cleanupError = $null
    if ($null -ne $Lease) {
        try {
            Exit-W365CertificateOfficerLease -Lease $Lease
        }
        catch {
            $cleanupError = $_
        }
    }

    if ($null -ne $PrimaryError) {
        if ($null -ne $cleanupError) {
            throw [AggregateException]::new(
                'Certificate provisioning failed and temporary Key Vault role cleanup also failed.',
                [Exception[]]@($PrimaryError.Exception, $cleanupError.Exception))
        }
        throw $PrimaryError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}
