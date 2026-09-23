#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = New-Module -Name Microsoft.Graph.Authentication -ScriptBlock {
    $script:tenant = '01eed126-9f96-4d2d-a127-dc2e786a898b'
    $script:scopes = @()
    $script:state = $null

    function Reset-MockViewerGraphState {
        $script:state = @{
            Application = @{
                id = 'viewer-app-object'
                appId = 'viewer-app-id'
                passwordCredentials = @(
                    @{ keyId = 'viewer-key'; endDateTime = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o') }
                )
            }
            ServicePrincipals = @(
                @{ id = 'viewer-sp-object'; appId = 'viewer-app-id' }
            )
            FederatedIdentityCredentials = @(
                @{ id = 'viewer-fic'; name = 'w365-viewer-viewer-principal' }
            )
            Operations = @()
        }
    }

    function Get-MockViewerGraphState {
        return ($script:state | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)
    }

    function Connect-MgGraph {
        param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode, $InformationAction)
        $script:tenant = $TenantId.ToString()
        $script:scopes = $Scopes
    }

    function Get-MgContext {
        return @{ TenantId = $script:tenant; AuthType = 'Delegated'; Scopes = $script:scopes }
    }

    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Headers, $Body, $ContentType)

        $path = $Uri.Replace('https://graph.microsoft.com/', '')
        $bodyObject = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { @{} }

        if ($Method -eq 'GET') {
            switch -Wildcard ($path) {
                'v1.0/applications/viewer-app-object/federatedIdentityCredentials' {
                    return @{ value = @($script:state.FederatedIdentityCredentials) }
                }
                'v1.0/applications/viewer-app-object?*' {
                    if ($null -eq $script:state.Application) {
                        $ex = [System.Exception]::new('Application not found')
                        $ex | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue 404
                        throw $ex
                    }

                    return $script:state.Application
                }
                "v1.0/servicePrincipals?`$filter=appId eq 'viewer-app-id'&`$select=id,appId" {
                    return @{ value = @($script:state.ServicePrincipals) }
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        if ($Method -eq 'POST') {
            switch -Wildcard ($path) {
                'v1.0/applications/viewer-app-object/removePassword' {
                    $script:state.Operations += "POST $path"
                    $script:state.Application.passwordCredentials = @(
                        @($script:state.Application.passwordCredentials | Where-Object { [string]$_.keyId -ne [string]$bodyObject.keyId })
                    )
                    return @{}
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        if ($Method -eq 'DELETE') {
            $script:state.Operations += "DELETE $path"
            switch -Wildcard ($path) {
                'v1.0/applications/viewer-app-object/federatedIdentityCredentials/*' {
                    $ficId = $path.Split('/')[-1]
                    $script:state.FederatedIdentityCredentials = @(
                        $script:state.FederatedIdentityCredentials | Where-Object { $_.id -ne $ficId }
                    )
                    return
                }
                'v1.0/servicePrincipals/*' {
                    $servicePrincipalId = $path.Split('/')[-1]
                    $script:state.ServicePrincipals = @($script:state.ServicePrincipals | Where-Object { $_.id -ne $servicePrincipalId })
                    return
                }
                'v1.0/applications/*' {
                    $script:state.Application = $null
                    return
                }
                default { throw "Unexpected mocked Graph request: $Method $path" }
            }
        }

        throw "Unexpected mocked Graph request: $Method $path"
    }

    Reset-MockViewerGraphState
    Export-ModuleMember -Function Connect-MgGraph, Get-MgContext, Invoke-MgGraphRequest, Reset-MockViewerGraphState, Get-MockViewerGraphState
}

$module | Import-Module -Global

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot 'scripts'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("viewer-cleanup-{0}" -f ([guid]::NewGuid()))
$envName = 'viewer-cleanup-test'
$envDir = Join-Path $tempRoot $envName
$envFilePath = Join-Path $envDir '.env'
$viewerManifestDirectory = Join-Path $repoRoot ".azure\$envName"
$viewerManifestPath = Join-Path $viewerManifestDirectory 'viewer-ownership.json'
$previousCleanupApproval = [Environment]::GetEnvironmentVariable('W365_CLEANUP_CONFIRMED', 'Process')
$global:viewerRoleAssignments = @(
    [ordered]@{
        id = '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/operator'
        scope = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault'
        principalId = 'operator-object'
        roleDefinitionId = '/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    },
    [ordered]@{
        id = '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/viewer'
        scope = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault'
        principalId = 'viewer-principal'
        roleDefinitionId = '/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6'
    }
)
$global:viewerRoleDeletes = [System.Collections.Generic.List[string]]::new()

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0

    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'list') {
        $scope = $arguments[[Array]::IndexOf($arguments, '--scope') + 1]
        $principalId = $arguments[[Array]::IndexOf($arguments, '--assignee-object-id') + 1]
        $query = $arguments[[Array]::IndexOf($arguments, '--query') + 1]
        if ($query -match "roleDefinitionId=='([^']+)'") {
            $roleDefinitionId = $Matches[1]
            $assignment = @($global:viewerRoleAssignments | Where-Object {
                $_.scope -eq $scope -and $_.principalId -eq $principalId -and $_.roleDefinitionId -eq $roleDefinitionId
            }) | Select-Object -First 1
            if ($assignment) {
                return $assignment.id
            }

            return ''
        }
    }

    if ($arguments[0] -eq 'role' -and $arguments[1] -eq 'assignment' -and $arguments[2] -eq 'delete') {
        $assignmentId = $arguments[[Array]::IndexOf($arguments, '--ids') + 1]
        $global:viewerRoleDeletes.Add($assignmentId)
        $global:viewerRoleAssignments = @($global:viewerRoleAssignments | Where-Object { $_.id -ne $assignmentId })
        return
    }

    throw "Unexpected az call: $($arguments -join ' ')"
}

function Write-ViewerEnvironment {
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
    Set-Content -LiteralPath $envFilePath -Value @"
AZURE_TENANT_ID="01eed126-9f96-4d2d-a127-dc2e786a898b"
AZURE_SUBSCRIPTION_ID="sub"
W365_ENABLED="false"
"@
}

function Write-ViewerManifest {
    param(
        [string]$ApplicationDisposition,
        [string]$CredentialDisposition,
        [string]$ServicePrincipalDisposition
    )

    New-Item -ItemType Directory -Path $viewerManifestDirectory -Force | Out-Null
    $manifest = [ordered]@{
        schemaVersion = 1
        environmentName = $envName
        application = [ordered]@{
            objectId = 'viewer-app-object'
            appId = 'viewer-app-id'
            displayName = 'viewer-app'
            disposition = $ApplicationDisposition
            redirectUri = 'https://viewer.example.com/signin-oidc'
            servicePrincipal = [ordered]@{
                objectId = 'viewer-sp-object'
                disposition = $ServicePrincipalDisposition
            }
        }
        operator = [ordered]@{
            tenantId = '01eed126-9f96-4d2d-a127-dc2e786a898b'
            objectId = 'operator-object'
        }
        graph = [ordered]@{
            federatedIdentityCredentials = [ordered]@{
                viewerFederation = [ordered]@{
                    id = 'viewer-fic'
                    name = 'w365-viewer-viewer-principal'
                    disposition = $CredentialDisposition
                }
            }
        }
        keyVaultRoleAssignments = [ordered]@{
            operatorSecretsOfficer = [ordered]@{
                assignmentId = '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/operator'
                principalId = 'operator-object'
                principalType = 'User'
                roleDefinitionId = '/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
                roleName = 'Key Vault Secrets Officer'
                scope = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault'
                disposition = 'created'
            }
            viewerSecretsUser = [ordered]@{
                assignmentId = '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/viewer'
                principalId = 'viewer-principal'
                principalType = 'ServicePrincipal'
                roleDefinitionId = '/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6'
                roleName = 'Key Vault Secrets User'
                scope = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault'
                disposition = 'created'
            }
        }
    }

    Set-Content -LiteralPath $viewerManifestPath -Value (ConvertTo-Json $manifest -Depth 20)
}

try {
    Write-ViewerEnvironment

    $blockedWithoutApproval = $false
    Write-ViewerManifest -ApplicationDisposition 'created' -CredentialDisposition 'created' -ServicePrincipalDisposition 'created'
    try {
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath (Join-Path $envDir 'w365-ownership.json') -Confirm:$false | Out-Null
    }
    catch {
        $blockedWithoutApproval = $_.Exception.Message -like '*-ConfirmViewerOnlyCleanup or W365_CLEANUP_CONFIRMED=true*'
    }
    if (!$blockedWithoutApproval) {
        throw 'Viewer-only cleanup should fail closed without explicit protected approval.'
    }
    $state = Get-MockViewerGraphState
    if ($state.Operations.Count -ne 0 -or $global:viewerRoleDeletes.Count -ne 0) {
        throw 'Viewer-only cleanup mutated Graph or RBAC state before protected approval.'
    }

    Write-ViewerManifest -ApplicationDisposition 'created' -CredentialDisposition 'created' -ServicePrincipalDisposition 'created'
    $viewerCleanupOutput = @(
        & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath (Join-Path $envDir 'w365-ownership.json') -ConfirmViewerOnlyCleanup -Confirm:$false
    )
    $rbacPlan = "Deleting Azure RBAC role assignment 'Key Vault Secrets User' for principal 'viewer-principal' at scope '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault' (assignment '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/viewer')."
    $rbacResult = 'Removed viewer role assignment Key Vault Secrets User.'
    $rbacPlanIndex = $viewerCleanupOutput.IndexOf($rbacPlan)
    $rbacResultIndex = $viewerCleanupOutput.IndexOf($rbacResult)
    if ($rbacPlanIndex -lt 0 -or $rbacResultIndex -lt 0 -or $rbacPlanIndex -ge $rbacResultIndex) {
        throw 'Viewer cleanup did not log Azure RBAC assignment details before deletion.'
    }
    $expectedCompletion = "Pre-teardown cleanup completed for '$envName': no configured W365 state remains. Azure resource deletion can continue."
    if ($viewerCleanupOutput[-1] -ne $expectedCompletion) {
        throw "Viewer-only cleanup did not defer the Azure deletion continuation message until cleanup completed. Last output: [$($viewerCleanupOutput[-1])]"
    }

    $state = Get-MockViewerGraphState
    if ($null -ne $state.Application -or $state.ServicePrincipals.Count -ne 0) {
        throw 'Viewer cleanup did not delete the created app and service principal.'
    }
    if ($global:viewerRoleDeletes.Count -ne 2) {
        throw 'Viewer cleanup did not remove the created Key Vault RBAC assignments.'
    }
    $viewerManifest = Get-Content -LiteralPath $viewerManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($viewerManifest.cleanup.status -ne 'completed') {
        throw 'Viewer cleanup did not mark the viewer ownership manifest complete.'
    }

    & $module { Reset-MockViewerGraphState }
    $global:viewerRoleAssignments = @(
        [ordered]@{
            id = '/subscriptions/sub/providers/Microsoft.Authorization/roleAssignments/operator'
            scope = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/w365-vault'
            principalId = 'operator-object'
            roleDefinitionId = '/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
        }
    )
    $global:viewerRoleDeletes.Clear()
    [Environment]::SetEnvironmentVariable('W365_CLEANUP_CONFIRMED', 'true', 'Process')
    Write-ViewerManifest -ApplicationDisposition 'reused' -CredentialDisposition 'created' -ServicePrincipalDisposition 'reused'
    & "$scriptsRoot\Remove-W365Resources.ps1" -EnvironmentName $envName -EnvironmentFilePath $envFilePath -OwnershipManifestPath (Join-Path $envDir 'w365-ownership.json') -Confirm:$false | Out-Null

    $state = Get-MockViewerGraphState
    if ($null -eq $state.Application) {
        throw 'Viewer cleanup should preserve a reused viewer application.'
    }
    if ($state.FederatedIdentityCredentials.Count -ne 0) {
        throw 'Viewer cleanup did not remove the created federation from the reused viewer application.'
    }
    if ($state.Operations -notcontains 'DELETE v1.0/applications/viewer-app-object/federatedIdentityCredentials/viewer-fic') {
        throw 'Viewer cleanup did not remove the owned federation from the reused viewer application.'
    }
    if ($state.Operations -contains 'DELETE v1.0/applications/viewer-app-object') {
        throw 'Viewer cleanup should not delete a reused viewer application.'
    }

    Write-Output 'Offline viewer cleanup: viewer-only teardown, created artifact deletion, and reused-app federation cleanup passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('W365_CLEANUP_CONFIRMED', $previousCleanupApproval, 'Process')
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $viewerManifestDirectory) {
        Remove-Item -LiteralPath $viewerManifestDirectory -Recurse -Force
    }

    Remove-Variable -Name viewerRoleAssignments, viewerRoleDeletes -Scope Global -ErrorAction SilentlyContinue
    Remove-Module Microsoft.Graph.Authentication
}