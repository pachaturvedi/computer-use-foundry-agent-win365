#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$global:viewerRoleCreates = [System.Collections.Generic.List[object]]::new()

function azd {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'env' -and $arguments[1] -eq 'get-value') {
        switch ($arguments[2]) {
            'AZURE_ENV_NAME' { return 'viewer-rbac-test' }
            'AZURE_SUBSCRIPTION_ID' { return '11111111-1111-1111-1111-111111111111' }
            'W365_KEY_VAULT_NAME' { return 'single-w365-vault' }
            'VIEWER_IDENTITY_PRINCIPAL_ID' { return '22222222-2222-2222-2222-222222222222' }
            default { return '' }
        }
    }
    throw "Unexpected azd call: $($arguments -join ' ')"
}

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'ad' -and $arguments[1] -eq 'signed-in-user') {
        return '33333333-3333-3333-3333-333333333333'
    }
    if ($arguments[0] -eq 'keyvault' -and $arguments[1] -eq 'show') {
        return '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample-rg/providers/Microsoft.KeyVault/vaults/single-w365-vault'
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        return ''
    }
    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'create') {
        $roleIndex = [Array]::IndexOf($arguments, '--role')
        $principalIndex = [Array]::IndexOf($arguments, '--assignee-object-id')
        $typeIndex = [Array]::IndexOf($arguments, '--assignee-principal-type')
        $global:viewerRoleCreates.Add([pscustomobject]@{
            Role = $arguments[$roleIndex + 1]
            PrincipalId = $arguments[$principalIndex + 1]
            PrincipalType = $arguments[$typeIndex + 1]
        })
        return "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/$($global:viewerRoleCreates.Count)"
    }
    throw "Unexpected az call: $($arguments -join ' ')"
}

try {
    & (Join-Path $root 'scripts\Set-W365KeyVaultRoles.ps1') -IncludeViewer

    if ($global:viewerRoleCreates.Count -ne 2) {
        throw "Expected exactly two vault-scoped RBAC assignments, received $($global:viewerRoleCreates.Count)."
    }
    $viewerRole = $global:viewerRoleCreates |
        Where-Object PrincipalId -eq '22222222-2222-2222-2222-222222222222'
    $operatorRole = $global:viewerRoleCreates |
        Where-Object PrincipalId -eq '33333333-3333-3333-3333-333333333333'
    if ($viewerRole.Role -ne '4633458b-17de-408a-b874-0445c86b69e6' -or
        $viewerRole.PrincipalType -ne 'ServicePrincipal') {
        throw 'The viewer identity was not assigned the built-in Key Vault Secrets User role.'
    }
    if ($operatorRole.Role -ne 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' -or
        $operatorRole.PrincipalType -ne 'User') {
        throw 'The setup operator was not assigned the built-in Key Vault Secrets Officer role.'
    }
    if ($global:viewerRoleCreates.Role -contains 'Owner' -or
        $global:viewerRoleCreates.Role -contains 'Contributor') {
        throw 'The viewer Key Vault flow assigned an overprivileged role.'
    }

    $manifestPath = Join-Path $root '.azure\viewer-rbac-test\viewer-ownership.json'
    if (!(Test-Path -LiteralPath $manifestPath)) {
        throw 'The viewer Key Vault flow did not record role ownership.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.keyVaultRoleAssignments.operatorSecretsOfficer.disposition -ne 'created' -or
        $manifest.keyVaultRoleAssignments.viewerSecretsUser.disposition -ne 'created') {
        throw 'The viewer Key Vault flow did not mark created RBAC assignments as owned.'
    }
}
finally {
    Remove-Item -LiteralPath (Join-Path $root '.azure\viewer-rbac-test') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name viewerRoleCreates -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'W365 Key Vault RBAC offline tests passed.'
