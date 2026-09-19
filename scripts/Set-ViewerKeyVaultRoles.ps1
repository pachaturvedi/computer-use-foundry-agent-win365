#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
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

$subscriptionId = Get-AzdRequiredValue 'AZURE_SUBSCRIPTION_ID'
$vaultName = Get-AzdRequiredValue 'VIEWER_KEY_VAULT_NAME'
$viewerPrincipalId = Get-AzdRequiredValue 'VIEWER_IDENTITY_PRINCIPAL_ID'
$operatorObjectId = (& az ad signed-in-user show --query id --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($operatorObjectId)) {
    throw 'Unable to resolve the signed-in Azure user.'
}
$vaultId = (& az keyvault show `
    --subscription $subscriptionId `
    --name $vaultName `
    --query id `
    --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
    throw "Unable to resolve Key Vault '$vaultName'."
}
Write-SampleVerbose -Component 'viewer-keyvault-rbac' -Message "Reconciling built-in RBAC assignments on '$vaultName'."
Write-SampleDebug -Component 'viewer-keyvault-rbac' -Message "VaultId=$vaultId; viewerPrincipalId=$viewerPrincipalId; operatorObjectId=$operatorObjectId."

$assignments = @(
    @{
        PrincipalId = $viewerPrincipalId
        PrincipalType = 'ServicePrincipal'
        RoleName = 'Key Vault Secrets User'
        RoleId = '4633458b-17de-408a-b874-0445c86b69e6'
    },
    @{
        PrincipalId = $operatorObjectId
        PrincipalType = 'User'
        RoleName = 'Key Vault Secrets Officer'
        RoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    }
)

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
        continue
    }

    Write-SampleVerbose -Component 'viewer-keyvault-rbac' -Message "Assigning $($assignment.RoleName) to $($assignment.PrincipalType)."
    Write-SampleDebug -Component 'viewer-keyvault-rbac' -Message "RoleId=$($assignment.RoleId); principalId=$($assignment.PrincipalId)."
    & az role assignment create `
        --subscription $subscriptionId `
        --scope $vaultId `
        --assignee-object-id $assignment.PrincipalId `
        --assignee-principal-type $assignment.PrincipalType `
        --role $assignment.RoleId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to grant $($assignment.RoleName) on Key Vault '$vaultName'."
    }
}

Write-Host "Key Vault RBAC is configured for the viewer identity and current operator on '$vaultName'."
