Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'certificate-role-access' -Message 'Loaded permanent Key Vault certificate role helpers.'
Write-SampleDebug -Component 'certificate-role-access' -Message 'Certificates Officer access is granted idempotently and retained; role propagation retries are bounded.'

function Wait-W365CertificateDataPlaneAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$VaultName,
        [ValidateRange(1, 30)][int]$PropagationAttempts = 8,
        [ValidateRange(0, 30)][int]$PropagationDelaySeconds = 2,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    for ($attempt = 1; $attempt -le $PropagationAttempts; $attempt++) {
        $CancellationToken.ThrowIfCancellationRequested()
        $probeOutput = (& az keyvault certificate list `
            --subscription $SubscriptionId `
            --vault-name $VaultName `
            --maxresults 1 `
            --output none 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            return
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

function Get-W365CertificateOfficerAssignmentId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][guid]$OperatorObjectId
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
    return ($existing | Out-String).Trim()
}

function Grant-W365CertificateOfficerAccess {
    <#
    .SYNOPSIS
    Ensures the operator permanently holds Key Vault Certificates Officer on the blueprint vault.

    .DESCRIPTION
    Subscription Owner is a control-plane role and conveys no Key Vault data-plane access on an
    RBAC-enabled vault, so certificate reads require this explicit assignment. The grant is
    permanent and idempotent: every run that needs certificate data-plane access calls this, and a
    run that already has the role makes no change. Access is deliberately not revoked, because the
    certificate is read again by W365 readiness verification and by the hosted-agent deployment
    preflight on every subsequent `azd up`, not only on the run that creates it. The assignment is
    scoped to the vault and is removed with the vault during teardown.
    #>
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
    $existingId = Get-W365CertificateOfficerAssignmentId `
        -SubscriptionId $SubscriptionId `
        -VaultName $VaultName `
        -VaultId $VaultId `
        -OperatorObjectId $OperatorObjectId

    # Access is permanent, so there is no assignment to release and no lease object to complete.
    $result = [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        VaultName = $VaultName
        VaultId = $VaultId
        OperatorObjectId = $OperatorObjectId
        RoleAssignmentId = $existingId
        AlreadyPresent = $true
        AcquisitionSkipped = $false
    }

    if (![string]::IsNullOrWhiteSpace($existingId)) {
        Write-SampleVerbose -Component 'certificate-role-access' -Message "Operator already holds Key Vault Certificates Officer on '$VaultName'."
        return $result
    }

    if (!$ConfirmResourceChanges) {
        throw "The current operator lacks Key Vault Certificates Officer on '$VaultName'. Re-run with -ConfirmResourceChanges to grant it, or have an administrator grant it."
    }
    if (!$PSCmdlet.ShouldProcess("$OperatorObjectId on $VaultName", 'Grant Key Vault Certificates Officer')) {
        $result.AlreadyPresent = $false
        $result.AcquisitionSkipped = $true
        return $result
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

    $result.RoleAssignmentId = $assignmentId
    $result.AlreadyPresent = $false

    # The grant is retained even if propagation has not completed within the bounded wait, so the
    # next run observes the existing assignment instead of re-granting it.
    Wait-W365CertificateDataPlaneAccess `
        -SubscriptionId $SubscriptionId `
        -VaultName $VaultName `
        -PropagationAttempts $PropagationAttempts `
        -PropagationDelaySeconds $PropagationDelaySeconds `
        -CancellationToken $CancellationToken

    Write-SampleVerbose -Component 'certificate-role-access' -Message "Granted Key Vault Certificates Officer on '$VaultName' to the operator."
    return $result
}
