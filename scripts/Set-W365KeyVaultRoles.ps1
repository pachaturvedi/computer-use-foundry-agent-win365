#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [switch]$IncludeViewer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if (!(Get-Command az -ErrorAction SilentlyContinue) -or
    !(Get-Command azd -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI and Azure Developer CLI are required.'
}
if (![string]::IsNullOrWhiteSpace($Environment)) {
    & azd env select $Environment | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select azd environment '$Environment'."
    }
}

function Get-AzdRequiredValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = (& azd env get-value $Name 2>$null | Out-String).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "The selected azd environment does not contain $Name."
    }
    return $value
}

function Get-ManifestValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object -or !($Object -is [System.Collections.IDictionary]) -or !$Object.Contains($Name)) {
        return $null
    }

    return $Object[$Name]
}

$environmentName = Get-AzdRequiredValue 'AZURE_ENV_NAME'
$subscriptionId = Get-AzdRequiredValue 'AZURE_SUBSCRIPTION_ID'
$vaultName = (& azd env get-value W365_KEY_VAULT_NAME 2>$null | Out-String).Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    $vaultName = (& azd env get-value VIEWER_KEY_VAULT_NAME 2>$null | Out-String).Trim().Trim('"')
}
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    throw 'The selected azd environment does not contain W365_KEY_VAULT_NAME.'
}
$viewerPrincipalId = if ($IncludeViewer) {
    Get-AzdRequiredValue 'VIEWER_IDENTITY_PRINCIPAL_ID'
}
else {
    ''
}
$operatorObjectId = (& az ad signed-in-user show --query id --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($operatorObjectId)) {
    throw 'Unable to resolve the signed-in Azure user.'
}
$vaultId = (& az keyvault show `
    --subscription $subscriptionId `
    --name $vaultName `
    --query id `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
    throw "Unable to resolve Key Vault '$vaultName'."
}
Write-SampleVerbose -Component 'viewer-keyvault-rbac' -Message "Reconciling built-in RBAC assignments on '$vaultName'."
Write-SampleDebug -Component 'viewer-keyvault-rbac' -Message "VaultId=$vaultId; viewerPrincipalId=$viewerPrincipalId; operatorObjectId=$operatorObjectId."

$assignments = @(
    @{
        ManifestKey = 'operatorSecretsOfficer'
        PrincipalId = $operatorObjectId
        PrincipalType = 'User'
        RoleName = 'Key Vault Secrets Officer'
        RoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    }
)
if ($IncludeViewer) {
    $assignments += @{
        ManifestKey = 'viewerSecretsUser'
        PrincipalId = $viewerPrincipalId
        PrincipalType = 'ServicePrincipal'
        RoleName = 'Key Vault Secrets User'
        RoleId = '4633458b-17de-408a-b874-0445c86b69e6'
    }
}

$repositoryRoot = Split-Path $PSScriptRoot
$manifestPath = Get-ViewerOwnershipManifestPath -RepositoryRoot $repositoryRoot -EnvironmentName $environmentName
$viewerManifest = Read-W365OwnershipManifest -Path $manifestPath -AllowMissing
if ($null -eq $viewerManifest) {
    $viewerManifest = [ordered]@{}
}
if (!($viewerManifest.Contains('keyVaultRoleAssignments')) -or
    !($viewerManifest.keyVaultRoleAssignments -is [System.Collections.IDictionary])) {
    $viewerManifest['keyVaultRoleAssignments'] = [ordered]@{}
}

foreach ($assignment in $assignments) {
    $roleDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$($assignment.RoleId)"
    $existing = & az role assignment list `
        --subscription $subscriptionId `
        --scope $vaultId `
        --assignee-object-id $assignment.PrincipalId `
        --query "[?roleDefinitionId=='$roleDefinitionId'].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect $($assignment.RoleName) on Key Vault '$vaultName'."
    }
    if (![string]::IsNullOrWhiteSpace(($existing | Out-String))) {
        Write-SampleVerbose -Component 'viewer-keyvault-rbac' -Message "$($assignment.RoleName) already exists for $($assignment.PrincipalType)."
        $assignmentId = ([string]($existing | Out-String)).Trim().Split([Environment]::NewLine, [System.StringSplitOptions]::RemoveEmptyEntries)[0]
        $existingManifestEntry = if ($viewerManifest.keyVaultRoleAssignments.Contains($assignment.ManifestKey)) {
            $viewerManifest.keyVaultRoleAssignments[$assignment.ManifestKey]
        }
        else {
            $null
        }
        $disposition = if ([string](Get-ManifestValue -Object $existingManifestEntry -Name 'assignmentId') -eq $assignmentId -and
            [string](Get-ManifestValue -Object $existingManifestEntry -Name 'disposition') -eq 'created') {
            'created'
        }
        else {
            'reused'
        }
        $viewerManifest.keyVaultRoleAssignments[$assignment.ManifestKey] = [ordered]@{
            assignmentId = $assignmentId
            principalId = $assignment.PrincipalId
            principalType = $assignment.PrincipalType
            roleDefinitionId = $roleDefinitionId
            roleName = $assignment.RoleName
            scope = $vaultId
            disposition = $disposition
        }
        continue
    }

    Write-SampleVerbose -Component 'viewer-keyvault-rbac' -Message "Assigning $($assignment.RoleName) to $($assignment.PrincipalType)."
    Write-SampleDebug -Component 'viewer-keyvault-rbac' -Message "RoleId=$($assignment.RoleId); principalId=$($assignment.PrincipalId)."
    $createdAssignmentId = (& az role assignment create `
        --subscription $subscriptionId `
        --scope $vaultId `
        --assignee-object-id $assignment.PrincipalId `
        --assignee-principal-type $assignment.PrincipalType `
        --role $assignment.RoleId `
        --query id `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($createdAssignmentId)) {
        throw "Unable to grant $($assignment.RoleName) on Key Vault '$vaultName'."
    }

    $viewerManifest.keyVaultRoleAssignments[$assignment.ManifestKey] = [ordered]@{
        assignmentId = $createdAssignmentId
        principalId = $assignment.PrincipalId
        principalType = $assignment.PrincipalType
        roleDefinitionId = $roleDefinitionId
        roleName = $assignment.RoleName
        scope = $vaultId
        disposition = 'created'
    }
}

$viewerManifest['schemaVersion'] = 1
$viewerManifest['environmentName'] = $environmentName
$viewerManifest['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('o')
Write-W365OwnershipManifest -Path $manifestPath -Manifest $viewerManifest

$scopeDescription = if ($IncludeViewer) { 'the viewer identity and current operator' } else { 'the current operator' }
Write-Host "Key Vault RBAC is configured for $scopeDescription on '$vaultName'."
