#Requires -Version 7.4
<#
.SYNOPSIS
Removes sample-owned W365, Entra, viewer, and RBAC artifacts.

.DESCRIPTION
Loads the ownership manifests, validates reused shared dependencies, connects to Graph, and removes or restores recorded resources in reverse dependency order before Azure teardown.


Key inputs: EnvironmentName and optional environment/manifest paths, shared-project override, viewer-only confirmation, device-code option, and Graph timeout.

.OUTPUTS
Redacted cleanup progress and an explicit indication that Azure resource deletion may continue.

.NOTES
Destructive and ownership-driven. Missing evidence, drift, unexpected assignments, or unapproved shared-project cleanup blocks all mutation.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$EnvironmentName,
    [string]$EnvironmentFilePath,
    [string]$OwnershipManifestPath,
    [switch]$AllowExistingProjectCleanup,
    [switch]$ConfirmViewerOnlyCleanup,
    [switch]$UseDeviceCode,
    [ValidateRange(30, 3600)][int]$GraphClientTimeoutSeconds = 600,
    [ValidateRange(1, 5)][int]$DeviceCodeMaxAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'W365OwnershipManifest.ps1')
. (Join-Path $PSScriptRoot 'GraphSignIn.ps1')
. (Join-Path $PSScriptRoot 'AzdCommand.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

function Test-TrueString {
    param([string]$Value)

    return @('1', 'true', 'yes', 'on') -contains ([string]$Value).Trim().ToLowerInvariant()
}
function Write-AzdDownRecoveryTip {
    if (Test-TrueString -Value $env:W365_PREDOWN_ALREADY_COMPLETED) {
        return
    }

    Write-Output "If 'azd down' now reports 'deployment not found' for a layer (a known azd layered-infra limitation), rerun teardown with '.\scripts\Invoke-AzdDown.ps1 -EnvironmentName <azd-environment-name> -Purge -Force' instead. It treats an already-missing deployment as complete for that layer and, if the environment's resource group still remains afterward, deletes it directly so no resources are left behind."
}
function Test-OwnershipCleanupCompleted {
    param($Manifest)

    $cleanup = Get-OptionalObjectValue -Object $Manifest -Name 'cleanup'
    return $cleanup -is [System.Collections.IDictionary] -and
        [string](Get-OptionalObjectValue -Object $cleanup -Name 'status') -eq 'completed'
}
function Test-GraphResourceNotFound {
    param([Parameter(Mandatory)]$ErrorRecord)

    $statusCode = Get-OptionalObjectValue -Object $ErrorRecord.Exception -Name 'ResponseStatusCode'
    if ($null -eq $statusCode) {
        $response = Get-OptionalObjectValue -Object $ErrorRecord.Exception -Name 'Response'
        $statusCode = Get-OptionalObjectValue -Object $response -Name 'StatusCode'
    }

    if ($null -ne $statusCode -and [int]$statusCode -eq 404) {
        return $true
    }

    return $ErrorRecord.Exception.Message -eq 'Pool not found'
}
function Get-RequiredStringValue {
    param(
        [hashtable]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Map -or !$Map.Contains($Key) -or [string]::IsNullOrWhiteSpace([string]$Map[$Key])) {
        throw "Required manifest field '$Key' is missing."
    }

    return [string]$Map[$Key]
}
function Resolve-CleanupTenantId {
    param(
        [Parameter(Mandatory)][hashtable]$EnvironmentValues,
        $W365Manifest,
        $ViewerManifest
    )

    if (![string]::IsNullOrWhiteSpace([string]$EnvironmentValues['W365_TENANT_ID']) -and [string]$EnvironmentValues['W365_TENANT_ID'] -ne '00000000-0000-0000-0000-000000000000') {
        return [string]$EnvironmentValues['W365_TENANT_ID']
    }
    if (![string]::IsNullOrWhiteSpace([string]$EnvironmentValues['AZURE_TENANT_ID'])) {
        return [string]$EnvironmentValues['AZURE_TENANT_ID']
    }
    if ($W365Manifest -and $W365Manifest.foundry -and ![string]::IsNullOrWhiteSpace([string]$W365Manifest.foundry.tenantId)) {
        return [string]$W365Manifest.foundry.tenantId
    }

    $viewerOperator = Get-OptionalObjectValue -Object $ViewerManifest -Name 'operator'
    $viewerTenantId = [string](Get-OptionalObjectValue -Object $viewerOperator -Name 'tenantId')
    if (![string]::IsNullOrWhiteSpace($viewerTenantId)) {
        return $viewerTenantId
    }

    throw 'Tenant ID is unavailable. Cleanup requires a valid tenant from the azd environment.'
}
function List-MapValues {
    param([hashtable]$Map)

    if ($null -eq $Map) {
        return @()
    }

    return @($Map.Keys | Sort-Object | ForEach-Object { $Map[$_] })
}
function Connect-GraphForCleanup {
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][string[]]$Scopes
    )

    $requiredScopes = @($Scopes | Select-Object -Unique)
    $graphContext = Get-MgContext
    if (Test-GraphContext -Context $graphContext -RequiredTenantId $TenantId -RequiredScopes $requiredScopes) {
        Write-Output 'Reusing the validated delegated Microsoft Graph context for teardown.'
        return
    }

    $connectParameters = @{
        TenantId = $TenantId
        Scopes = $requiredScopes
        ClientTimeout = $GraphClientTimeoutSeconds
        ContextScope = 'CurrentUser'
        NoWelcome = $true
    }
    if ($UseDeviceCode) {
        Write-W365DeviceCodeGuidance `
            -Purpose 'to remove the Entra and Windows 365 objects this environment owns' `
            -RequiredAccess 'the roles that created these objects (for example Agent ID Administrator and Cloud Device Administrator)' `
            -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts
    }

    # Device code must be the primary method when the caller asked for it, never a catch-based
    # fallback. Interactive sign-in brokers through native MSAL/WAM, and a native access violation
    # there terminates the process outright, so no catch can ever reach a fallback. Every other
    # Graph sign-in in this repository passes -UseDeviceCode the same way.
    $graphContext = Connect-W365GraphContext `
        -ConnectParameters $connectParameters `
        -UseDeviceCode:$UseDeviceCode `
        -DeviceCodeMaxAttempts $DeviceCodeMaxAttempts

    if (!(Test-GraphContext -Context $graphContext -RequiredTenantId $TenantId -RequiredScopes $requiredScopes)) {
        throw 'A delegated Graph connection in the requested tenant is required for cleanup.'
    }

    Write-Output 'Microsoft Graph sign-in completed and the delegated teardown context was validated.'
}
function Assert-CleanupApproved {
    param(
        [string]$TargetName,
        [switch]$RequireProtectedApproval
    )

    $cleanupApproval = [Environment]::GetEnvironmentVariable('W365_CLEANUP_CONFIRMED')
    if (![string]::IsNullOrWhiteSpace($cleanupApproval) -and $cleanupApproval -notin @('true', 'false')) {
        throw "W365_CLEANUP_CONFIRMED must be 'true' or 'false', received '$cleanupApproval'."
    }

    $protectedCleanupApproved = $cleanupApproval -eq 'true'
    if ($RequireProtectedApproval -and
        !$protectedCleanupApproved -and
        !$ConfirmViewerOnlyCleanup) {
        throw 'Viewer-only cleanup requires -ConfirmViewerOnlyCleanup or W365_CLEANUP_CONFIRMED=true before any mutation runs.'
    }

    if (!$protectedCleanupApproved -and
        !$PSCmdlet.ShouldProcess(($TargetName ?? 'current azd environment'), 'Remove W365 and Entra resources before azd down')) {
        throw 'Cleanup confirmation was declined.'
    }
}
function Graph([string]$Method, [string]$Path, $Body = $null) {
    Invoke-W365GraphRequest `
        -Method $Method `
        -Path $Path `
        -Body $Body `
        -OriginErrorMessage 'Graph request resolved to an unexpected origin.'
}
function List([string]$Path) {
    Get-W365GraphCollection `
        -Path $Path `
        -OriginErrorMessage 'Graph request resolved to an unexpected origin.'
}
function SingleOrNone($Items, [string]$Label) {
    Select-W365GraphSingleResult `
        -Items $Items `
        -Label $Label `
        -AmbiguousMessage 'Resolve manually before rerunning cleanup.'
}
function Get-CurrentViewerRoleAssignmentId {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $scope = [string]$Entry.scope
    $scopeMatch = [regex]::Match(
        $scope,
        '^/subscriptions/(?<subscriptionId>[^/]+)/resourceGroups/(?<resourceGroupName>[^/]+)(?:/|$)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($scopeMatch.Success -and
        $scopeMatch.Groups['subscriptionId'].Value -eq $SubscriptionId) {
        $resourceGroupName = $scopeMatch.Groups['resourceGroupName'].Value
        $resourceGroupExists = (& az group exists `
            --subscription $SubscriptionId `
            --name $resourceGroupName `
            --output tsv 2>$null | Out-String).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $resourceGroupExists -notin @('true', 'false')) {
            throw "Unable to inspect resource group '$resourceGroupName' before viewer RBAC cleanup."
        }
        if ($resourceGroupExists -eq 'false') {
            return ''
        }

        $resourceExistsError = (& az resource show --ids $scope --output none 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            if ($resourceExistsError -match '(?i)ResourceNotFound|could not be found|was not found') {
                return ''
            }
            throw "Unable to inspect resource '$scope' before viewer RBAC cleanup: $resourceExistsError"
        }
    }

    $query = "[?roleDefinitionId=='$([string]$Entry.roleDefinitionId)'].id | [0]"
    $assignmentId = (& az role assignment list `
        --subscription $SubscriptionId `
        --scope $scope `
        --assignee-object-id ([string]$Entry.principalId) `
        --query $query `
        --output tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect viewer role assignment '$([string]$Entry.roleName)' on '$scope'."
    }

    return $assignmentId
}
function Remove-ViewerArtifacts {
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][hashtable]$EnvironmentValues,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $viewerApplication = Get-OptionalObjectValue -Object $Manifest -Name 'application'
    $viewerRoleAssignments = Get-OptionalObjectValue -Object $Manifest -Name 'keyVaultRoleAssignments'
    if (!($viewerApplication -is [System.Collections.IDictionary]) -and
        !($viewerRoleAssignments -is [System.Collections.IDictionary])) {
        return
    }

    Write-Output 'Cleaning viewer bootstrap artifacts recorded in viewer-ownership.json.'

    if ($viewerApplication -is [System.Collections.IDictionary]) {
        $viewerAppObjectId = [string](Get-OptionalObjectValue -Object $viewerApplication -Name 'objectId')
        $viewerAppId = [string](Get-OptionalObjectValue -Object $viewerApplication -Name 'appId')
        $viewerApplicationDisposition = [string](Get-OptionalObjectValue -Object $viewerApplication -Name 'disposition')
        $viewerServicePrincipal = Get-OptionalObjectValue -Object $viewerApplication -Name 'servicePrincipal'
        $viewerFederations = Get-OptionalObjectValue -Object (Get-OptionalObjectValue -Object $Manifest -Name 'graph') -Name 'federatedIdentityCredentials'

        $currentApplication = $null
        if (![string]::IsNullOrWhiteSpace($viewerAppObjectId)) {
            try {
                $currentApplication = Graph GET "v1.0/applications/${viewerAppObjectId}?`$select=id,appId"
            }
            catch {
                if (Test-GraphResourceNotFound -ErrorRecord $_) {
                    $currentApplication = $null
                }
                else {
                    throw
                }
            }
        }

        if ($viewerFederations -is [System.Collections.IDictionary] -and $currentApplication) {
            $currentFederations = @(List "v1.0/applications/$viewerAppObjectId/federatedIdentityCredentials")
            foreach ($entry in @(List-MapValues $viewerFederations)) {
                if ([string](Get-OptionalObjectValue -Object $entry -Name 'disposition') -ne 'created') {
                    continue
                }
                $ficId = [string](Get-OptionalObjectValue -Object $entry -Name 'id')
                $ficName = [string](Get-OptionalObjectValue -Object $entry -Name 'name')
                $matches = @($currentFederations | Where-Object {
                    (![string]::IsNullOrWhiteSpace($ficId) -and [string]$_.id -eq $ficId) -or
                    (![string]::IsNullOrWhiteSpace($ficName) -and [string]$_.name -eq $ficName)
                })
                if ($matches.Count -gt 1) {
                    throw "Viewer federation '$ficName' is ambiguous; cleanup is blocked."
                }
                if ($matches.Count -eq 1) {
                    if (![string]::IsNullOrWhiteSpace($ficId) -and [string]$matches[0].id -ne $ficId) {
                        throw "Viewer federation '$ficName' does not match the ownership manifest."
                    }
                    Graph DELETE "v1.0/applications/$viewerAppObjectId/federatedIdentityCredentials/$([string]$matches[0].id)" | Out-Null
                }
            }
        }

        $currentServicePrincipals = if (![string]::IsNullOrWhiteSpace($viewerAppId)) {
            @(List "v1.0/servicePrincipals?`$filter=appId eq '$viewerAppId'&`$select=id,appId")
        }
        else {
            @()
        }
        if (($viewerServicePrincipal -is [System.Collections.IDictionary]) -and
            [string](Get-OptionalObjectValue -Object $viewerServicePrincipal -Name 'disposition') -eq 'created') {
            $viewerServicePrincipalId = [string](Get-OptionalObjectValue -Object $viewerServicePrincipal -Name 'objectId')
            $currentServicePrincipal = if (![string]::IsNullOrWhiteSpace($viewerServicePrincipalId)) {
                SingleOrNone @($currentServicePrincipals | Where-Object { [string]$_.id -eq $viewerServicePrincipalId }) 'viewer service principal'
            }
            else {
                SingleOrNone $currentServicePrincipals 'viewer service principal'
            }

            if ($currentServicePrincipal) {
                Write-Output "Deleting viewer service principal '$([string]$currentServicePrincipal.id)' for application '$viewerAppId'."
                Graph DELETE "v1.0/servicePrincipals/$([string]$currentServicePrincipal.id)" | Out-Null
                Write-Output "Removed viewer service principal $([string]$currentServicePrincipal.id)."
            }
            else {
                Write-Output 'Viewer service principal was already absent.'
            }
        }

        if ($viewerApplicationDisposition -eq 'created') {
            if ($currentApplication) {
                if ([string]$currentApplication.appId -ne $viewerAppId) {
                    throw 'The current viewer application does not match the recorded ownership manifest.'
                }

                Write-Output "Deleting viewer application '$viewerAppObjectId' with app ID '$viewerAppId'."
                Graph DELETE "v1.0/applications/$viewerAppObjectId" | Out-Null
                Write-Output "Removed viewer application $viewerAppObjectId."
            }
            else {
                Write-Output 'Viewer application was already absent.'
            }
        }
    }

    if ($viewerRoleAssignments -is [System.Collections.IDictionary] -and $viewerRoleAssignments.Keys.Count -gt 0) {
        if (!(Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required to remove viewer Key Vault RBAC assignments.'
        }

        $subscriptionId = [string]$EnvironmentValues['AZURE_SUBSCRIPTION_ID']
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            throw 'AZURE_SUBSCRIPTION_ID is required to remove viewer Key Vault RBAC assignments.'
        }

        foreach ($entry in @(List-MapValues $viewerRoleAssignments)) {
            if ([string](Get-OptionalObjectValue -Object $entry -Name 'disposition') -ne 'created') {
                continue
            }

            $currentAssignmentId = Get-CurrentViewerRoleAssignmentId -Entry $entry -SubscriptionId $subscriptionId
            $recordedAssignmentId = [string](Get-OptionalObjectValue -Object $entry -Name 'assignmentId')
            if (![string]::IsNullOrWhiteSpace($currentAssignmentId) -and
                ![string]::IsNullOrWhiteSpace($recordedAssignmentId) -and
                $currentAssignmentId -ne $recordedAssignmentId) {
                throw "Viewer role assignment '$([string]$entry.roleName)' does not match the ownership manifest ID."
            }

            if ([string]::IsNullOrWhiteSpace($currentAssignmentId)) {
                Write-Output "Viewer role assignment $([string]$entry.roleName) was already absent."
                continue
            }

            Write-Output "Deleting Azure RBAC role assignment '$([string]$entry.roleName)' for principal '$([string]$entry.principalId)' at scope '$([string]$entry.scope)' (assignment '$currentAssignmentId')."
            & az role assignment delete --ids $currentAssignmentId --output none 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to remove viewer role assignment '$([string]$entry.roleName)'."
            }

            Write-Output "Removed viewer role assignment $([string]$entry.roleName)."
        }
    }

    $Manifest['cleanup'] = [ordered]@{
        status = 'completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-W365OwnershipManifest -Path $ManifestPath -Manifest $Manifest
}
function Assert-ReusedManifestDependenciesPresent {
    param(
        [Parameter(Mandatory)][object[]]$PermissionGrants,
        [Parameter(Mandatory)][object[]]$CurrentGrants,
        [Parameter(Mandatory)][object[]]$InheritablePermissions,
        [Parameter(Mandatory)][object[]]$CurrentInheritances
    )

    foreach ($grant in @($PermissionGrants | Where-Object { [string]$_.disposition -eq 'reused' })) {
        $currentGrant = SingleOrNone @($CurrentGrants | Where-Object { $_.resourceId -eq $grant.resourceId }) "permission grant $($grant.resourceAppId)"
        if (!$currentGrant) {
            throw "A reused permission grant for $($grant.resourceAppId) is missing, so cleanup cannot safely restore its previous scope."
        }
        $recordedGrantId = [string](Get-OptionalObjectValue -Object $grant -Name 'grantId')
        if (![string]::IsNullOrWhiteSpace($recordedGrantId) -and [string]$currentGrant.id -ne $recordedGrantId) {
            throw "A reused permission grant for $($grant.resourceAppId) does not match the ownership manifest ID."
        }
    }

    foreach ($inheritance in @($InheritablePermissions | Where-Object { [string]$_.disposition -eq 'reused' })) {
        $currentInheritance = SingleOrNone @($CurrentInheritances | Where-Object { $_.resourceAppId -eq $inheritance.resourceAppId }) "inheritance $($inheritance.resourceAppId)"
        if (!$currentInheritance) {
            throw "A reused inheritance entry for $($inheritance.resourceAppId) is missing, so cleanup cannot safely preserve shared blueprint state."
        }
        $recordedInheritanceId = [string](Get-OptionalObjectValue -Object $inheritance -Name 'entryId')
        if (![string]::IsNullOrWhiteSpace($recordedInheritanceId) -and [string]$currentInheritance.id -ne $recordedInheritanceId) {
            throw "A reused inheritance entry for $($inheritance.resourceAppId) does not match the ownership manifest ID."
        }
    }
}
function Resolve-EnvironmentContext {
    $repositoryRoot = Split-Path $PSScriptRoot
    $azd = $null
    $resolvedEnvironmentName = $EnvironmentName
    $resolvedEnvironmentFilePath = $EnvironmentFilePath
    $resolvedManifestPath = $OwnershipManifestPath

    if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentName) -or
        [string]::IsNullOrWhiteSpace($resolvedEnvironmentFilePath) -or
        [string]::IsNullOrWhiteSpace($resolvedManifestPath)) {
        $azd = Get-AzdCommand
        if ($azd) {
            if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentName)) {
                $resolvedEnvironmentName = Invoke-Azd -Azd $azd -Arguments @('env', 'get-value', 'AZURE_ENV_NAME') -CaptureOutput
            }

            if (![string]::IsNullOrWhiteSpace($resolvedEnvironmentName)) {
                if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentFilePath)) {
                    $resolvedEnvironmentFilePath = Join-Path (Join-Path $repositoryRoot ".azure\$resolvedEnvironmentName") '.env'
                }
                if ([string]::IsNullOrWhiteSpace($resolvedManifestPath)) {
                    $resolvedManifestPath = Get-W365OwnershipManifestPath -RepositoryRoot $repositoryRoot -EnvironmentName $resolvedEnvironmentName
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentName) -and ![string]::IsNullOrWhiteSpace($resolvedManifestPath)) {
        $resolvedEnvironmentName = Split-Path (Split-Path $resolvedManifestPath -Parent) -Leaf
    }

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        Azd = $azd
        EnvironmentName = $resolvedEnvironmentName
        EnvironmentFilePath = $resolvedEnvironmentFilePath
        OwnershipManifestPath = $resolvedManifestPath
    }
}

if (Test-TrueString -Value $env:W365_PREDOWN_ALREADY_COMPLETED) {
    Write-Output 'W365 pre-teardown cleanup was already completed by Invoke-AzdDown.ps1. Azure resource deletion can continue.'
    return
}

$context = Resolve-EnvironmentContext
if ([string]::IsNullOrWhiteSpace($context.EnvironmentFilePath) -and
    [string]::IsNullOrWhiteSpace($context.OwnershipManifestPath)) {
    throw 'Unable to resolve the azd environment or W365 ownership manifest. Cleanup cannot prove whether tenant resources remain, so azd down is blocked.'
}
$envValues = if (![string]::IsNullOrWhiteSpace($context.EnvironmentFilePath) -and (Test-Path -LiteralPath $context.EnvironmentFilePath)) {
    Read-AzdEnvironmentFile -Path $context.EnvironmentFilePath
}
else {
    [ordered]@{}
}
$manifest = if (![string]::IsNullOrWhiteSpace($context.OwnershipManifestPath)) {
    Read-W365OwnershipManifest -Path $context.OwnershipManifestPath -AllowMissing
}
else {
    $null
}
$viewerManifestPath = if (![string]::IsNullOrWhiteSpace($context.EnvironmentName)) {
    Get-ViewerOwnershipManifestPath -RepositoryRoot $context.RepositoryRoot -EnvironmentName $context.EnvironmentName
}
else {
    ''
}
$viewerManifest = if (![string]::IsNullOrWhiteSpace($viewerManifestPath)) {
    Read-W365OwnershipManifest -Path $viewerManifestPath -AllowMissing
}
else {
    $null
}
$w365CleanupCompleted = Test-OwnershipCleanupCompleted -Manifest $manifest
$viewerCleanupCompleted = Test-OwnershipCleanupCompleted -Manifest $viewerManifest

if ($null -eq $manifest) {
    $hasW365State = (Test-TrueString -Value ([string]$envValues['W365_ENABLED'])) -or
        ![string]::IsNullOrWhiteSpace([string]$envValues['W365_POOL_ID']) -or
        ![string]::IsNullOrWhiteSpace([string]$envValues['W365_AGENT_USER_ID'])
    if ($hasW365State) {
        throw 'No W365 ownership manifest was found for this environment. Cleanup cannot prove ownership, so azd down is blocked.'
    }

    $cleanupEnvironmentName = $context.EnvironmentName ?? 'current azd environment'

    if ($viewerManifest) {
        if ($viewerCleanupCompleted) {
            Write-Output 'Viewer ownership cleanup was already completed; no Graph or Azure RBAC cleanup is required.'
        }
        else {
            Write-Output "No Windows 365 ownership manifest or configured W365 state was found for '$cleanupEnvironmentName'. Evaluating viewer-owned artifacts before Azure resource deletion."
            Assert-CleanupApproved -TargetName ($context.EnvironmentName ?? 'current azd environment') -RequireProtectedApproval
            $viewerTenantId = [guid](Resolve-CleanupTenantId -EnvironmentValues $envValues -W365Manifest $manifest -ViewerManifest $viewerManifest)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Connect-GraphForCleanup -TenantId $viewerTenantId -Scopes @('Application.ReadWrite.All')
            Remove-ViewerArtifacts -Manifest $viewerManifest -EnvironmentValues $envValues -ManifestPath $viewerManifestPath
        }
    }

    Write-Output "Pre-teardown cleanup completed for '$cleanupEnvironmentName': no configured W365 state remains. Azure resource deletion can continue."
    Write-AzdDownRecoveryTip
    return
}

$projectOwnership = [string](Get-OptionalObjectValue -Object $manifest.foundry -Name 'projectOwnership')
if ([string]::IsNullOrWhiteSpace($projectOwnership) -or $projectOwnership -eq 'unknown') {
    $projectOwnership = [string]$envValues['FOUNDRY_PROJECT_OWNERSHIP']
}
if (([string]::IsNullOrWhiteSpace($projectOwnership) -or $projectOwnership -eq 'unknown') -and
    ![string]::IsNullOrWhiteSpace([string]$envValues['FOUNDRY_PROJECT_ENDPOINT'])) {
    $projectOwnership = 'existing'
}
$allowExistingProjectCleanup = $AllowExistingProjectCleanup -or (Test-TrueString ([Environment]::GetEnvironmentVariable('ALLOW_EXISTING_FOUNDRY_CLEANUP')))
if ($projectOwnership -eq 'existing' -and !$allowExistingProjectCleanup) {
    throw 'This environment is bound to an existing Foundry project. Set ALLOW_EXISTING_FOUNDRY_CLEANUP=true or pass -AllowExistingProjectCleanup only after confirming azd down may delete that shared project resource group.'
}

if ($w365CleanupCompleted) {
    if ($viewerManifest -and !$viewerCleanupCompleted) {
        Assert-CleanupApproved -TargetName ($context.EnvironmentName ?? 'current azd environment')
        $viewerTenantId = [guid](Resolve-CleanupTenantId -EnvironmentValues $envValues -W365Manifest $manifest -ViewerManifest $viewerManifest)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Connect-GraphForCleanup -TenantId $viewerTenantId -Scopes @('Application.ReadWrite.All')
        Remove-ViewerArtifacts -Manifest $viewerManifest -EnvironmentValues $envValues -ManifestPath $viewerManifestPath
    }
    elseif ($viewerCleanupCompleted) {
        Write-Output 'Viewer ownership cleanup was already completed; no Graph or Azure RBAC cleanup is required.'
    }

    Write-Output 'W365 ownership cleanup was already completed. Azure resource deletion can continue.'
    Write-AzdDownRecoveryTip
    return
}

Assert-CleanupApproved -TargetName ($context.EnvironmentName ?? 'current azd environment')

$tenantIdValue = Resolve-CleanupTenantId -EnvironmentValues $envValues -W365Manifest $manifest -ViewerManifest $viewerManifest
$tenantId = [guid]$tenantIdValue

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @(
    'Application.Read.All',
    'AgentIdentityBlueprint.ReadWrite.All', 'AgentIdentityBlueprint.UpdateAuthProperties.All',
    'AgentIdUser.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'CloudPC.ReadWrite.All'
)
if ((List-MapValues $manifest.graph.federatedIdentityCredentials).Count -gt 0) {
    $scopes += 'AgentIdentityBlueprint.AddRemoveCreds.All'
}

if ($viewerManifest -and !$viewerCleanupCompleted -and
    ($viewerManifest.application -is [System.Collections.IDictionary])) {
    $scopes += 'Application.ReadWrite.All'
}
Connect-GraphForCleanup -TenantId $tenantId -Scopes $scopes

$blueprint = $manifest.graph.blueprint
$blueprintObjectId = Get-RequiredStringValue -Map $blueprint -Key 'objectId'
$blueprintAppId = Get-RequiredStringValue -Map $blueprint -Key 'appId'
$blueprintPrincipalId = Get-RequiredStringValue -Map $blueprint -Key 'principalId'
$poolManifest = $manifest.w365.pool
$agentUserManifest = $manifest.w365.agentUser
$assignmentManifest = $manifest.w365.assignment
$permissionGrants = @(List-MapValues $manifest.graph.permissionGrants)
$inheritablePermissions = @(List-MapValues $manifest.graph.inheritablePermissions)
$federatedCredentials = @(List-MapValues $manifest.graph.federatedIdentityCredentials)

$bpPath = "v1.0/applications/$blueprintObjectId"
$ficPath = "$bpPath/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials"
$inheritPath = "v1.0/applications/microsoft.graph.agentIdentityBlueprint/$blueprintAppId/inheritablePermissions"

Write-Output 'Cleaning W365 and Entra resources in reverse dependency order before azd down.'

$poolId = if ($poolManifest) { [string]$poolManifest.id } else { '' }
$agentUserId = if ($agentUserManifest) { [string]$agentUserManifest.id } else { '' }
$currentAssignments = if (![string]::IsNullOrWhiteSpace($poolId)) {
    @(List "beta/deviceManagement/virtualEndpoint/cloudPcPools/$poolId/assignments")
}
else {
    @()
}
$currentGrants = @(List "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$blueprintPrincipalId'")
$currentInheritances = @(List $inheritPath)
Assert-ReusedManifestDependenciesPresent -PermissionGrants $permissionGrants -CurrentGrants $currentGrants -InheritablePermissions $inheritablePermissions -CurrentInheritances $currentInheritances
if ($poolManifest -and [string]$poolManifest.disposition -eq 'created') {
    $recordedAssignmentId = if ($assignmentManifest) { [string](Get-OptionalObjectValue -Object $assignmentManifest -Name 'id') } else { '' }
    $recordedUserPrincipalId = if ($assignmentManifest) { [string](Get-OptionalObjectValue -Object $assignmentManifest -Name 'userPrincipalId') } else { '' }
    $unexpectedAssignments = @($currentAssignments | Where-Object {
        $currentAssignmentId = [string](Get-OptionalObjectValue -Object $_ -Name 'id')
        $currentUserPrincipalId = [string](Get-OptionalObjectValue -Object $_ -Name 'userPrincipalId')
        !((![string]::IsNullOrWhiteSpace($recordedAssignmentId) -and $currentAssignmentId -eq $recordedAssignmentId) -or
            (![string]::IsNullOrWhiteSpace($recordedUserPrincipalId) -and $currentUserPrincipalId -eq $recordedUserPrincipalId))
    })
    if ($unexpectedAssignments.Count -gt 0) {
        throw 'The sample-created W365 pool has assignments not recorded in the ownership manifest. Cleanup is blocked to avoid deleting another principal''s Cloud PCs.'
    }
}

if ($assignmentManifest -and [string]$assignmentManifest.disposition -eq 'created') {
    $currentAssignment = SingleOrNone @($currentAssignments | Where-Object { $_.userPrincipalId -eq $assignmentManifest.userPrincipalId }) 'pool assignment'
    if ($currentAssignment) {
        $assignmentId = [string](Get-OptionalObjectValue -Object $currentAssignment -Name 'id')
        if ([string]::IsNullOrWhiteSpace($assignmentId)) {
            throw 'The pool assignment exists but does not expose an ID for deletion.'
        }
        $recordedAssignmentId = [string](Get-OptionalObjectValue -Object $assignmentManifest -Name 'id')
        if (![string]::IsNullOrWhiteSpace($recordedAssignmentId) -and $assignmentId -ne $recordedAssignmentId) {
            throw 'The current pool assignment ID does not match the ownership manifest.'
        }

        Write-Output "Deleting W365 pool assignment '$assignmentId' from pool '$poolId' for principal '$([string]$assignmentManifest.userPrincipalId)'."
        Graph DELETE "beta/deviceManagement/virtualEndpoint/cloudPcPools/$poolId/assignments/$assignmentId" | Out-Null
        Write-Output "Removed pool assignment $assignmentId."
    }
    else {
        Write-Output 'Pool assignment was already absent.'
    }
}

if ($agentUserManifest -and [string]$agentUserManifest.disposition -eq 'created') {
    $currentAgentUser = SingleOrNone @(List "beta/users/microsoft.graph.agentUser?`$filter=userPrincipalName eq '$($agentUserManifest.userPrincipalName)'") 'agent user'
    if ($currentAgentUser) {
        if ([string]$currentAgentUser.id -ne $agentUserId -or [string]$currentAgentUser.identityParentId -ne [string]$agentUserManifest.parentAgentObjectId) {
            throw 'The current agent user does not match the recorded ownership manifest.'
        }

        Write-Output "Deleting W365 agent user '$agentUserId' owned by parent agent '$([string]$agentUserManifest.parentAgentObjectId)'."
        Graph DELETE "beta/users/$agentUserId" | Out-Null
        Write-Output "Removed agent user $agentUserId."
    }
    else {
        Write-Output 'Agent user was already absent.'
    }
}

$currentFics = @(List $ficPath)
foreach ($credential in $federatedCredentials | Where-Object { [string]$_.disposition -eq 'created' }) {
    $match = SingleOrNone @($currentFics | Where-Object { $_.name -eq $credential.name -and $_.subject -eq $credential.subject }) "federated credential $($credential.name)"
    if ($match) {
        $credentialId = [string](Get-OptionalObjectValue -Object $match -Name 'id')
        if ([string]::IsNullOrWhiteSpace($credentialId)) {
            throw "Federated credential '$($credential.name)' exists but does not expose an ID for deletion."
        }
        $recordedCredentialId = [string](Get-OptionalObjectValue -Object $credential -Name 'id')
        if (![string]::IsNullOrWhiteSpace($recordedCredentialId) -and $credentialId -ne $recordedCredentialId) {
            throw "Federated credential '$($credential.name)' does not match the ownership manifest ID."
        }

        Write-Output "Deleting federated credential '$($credential.name)' (ID '$credentialId') from blueprint '$blueprintObjectId'."
        Graph DELETE "$ficPath/$credentialId" | Out-Null
        Write-Output "Removed federated credential $($credential.name)."
    }
    else {
        Write-Output "Federated credential $($credential.name) was already absent."
    }
}

foreach ($grant in $permissionGrants) {
    $currentGrant = SingleOrNone @($currentGrants | Where-Object { $_.resourceId -eq $grant.resourceId }) "permission grant $($grant.resourceAppId)"
    if ($currentGrant) {
        $recordedGrantId = [string](Get-OptionalObjectValue -Object $grant -Name 'grantId')
        if (![string]::IsNullOrWhiteSpace($recordedGrantId) -and [string]$currentGrant.id -ne $recordedGrantId) {
            throw "Permission grant for $($grant.resourceAppId) does not match the ownership manifest ID."
        }
    }
    if ([string]$grant.disposition -eq 'created') {
        if ($currentGrant) {
            Write-Output "Deleting delegated permission grant '$([string]$currentGrant.id)' for resource application '$($grant.resourceAppId)'."
            Graph DELETE "v1.0/oauth2PermissionGrants/$([string]$currentGrant.id)" | Out-Null
            Write-Output "Removed permission grant for $($grant.resourceAppId)."
        }
        else {
            Write-Output "Permission grant for $($grant.resourceAppId) was already absent."
        }
    }
    else {
        if (!$currentGrant) {
            throw "A reused permission grant for $($grant.resourceAppId) is missing, so cleanup cannot safely restore its previous scope."
        }

        $previousScope = [string]$grant.previousScope
        if ([string]$currentGrant.scope -ne $previousScope) {
            Write-Output "Restoring delegated permission grant '$([string]$currentGrant.id)' for resource application '$($grant.resourceAppId)' to its recorded scope."
            Graph PATCH "v1.0/oauth2PermissionGrants/$([string]$currentGrant.id)" @{ scope = $previousScope } | Out-Null
            Write-Output "Restored permission grant scope for $($grant.resourceAppId)."
        }
    }
}

foreach ($inheritance in $inheritablePermissions | Where-Object { [string]$_.disposition -eq 'created' }) {
    $currentInheritance = SingleOrNone @($currentInheritances | Where-Object { $_.resourceAppId -eq $inheritance.resourceAppId }) "inheritance $($inheritance.resourceAppId)"
    if ($currentInheritance) {
        $inheritanceId = [string](Get-OptionalObjectValue -Object $currentInheritance -Name 'id')
        if ([string]::IsNullOrWhiteSpace($inheritanceId)) {
            throw "Inheritance entry for $($inheritance.resourceAppId) exists but does not expose an ID for deletion."
        }
        $recordedInheritanceId = [string](Get-OptionalObjectValue -Object $inheritance -Name 'entryId')
        if (![string]::IsNullOrWhiteSpace($recordedInheritanceId) -and $inheritanceId -ne $recordedInheritanceId) {
            throw "Inheritance entry for $($inheritance.resourceAppId) does not match the ownership manifest ID."
        }

        Write-Output "Deleting inheritable-permission entry '$inheritanceId' for resource application '$($inheritance.resourceAppId)'."
        Graph DELETE "$inheritPath/$inheritanceId" | Out-Null
        Write-Output "Removed inheritance entry for $($inheritance.resourceAppId)."
    }
    else {
        Write-Output "Inheritance entry for $($inheritance.resourceAppId) was already absent."
    }
}

if (!($blueprint -is [System.Collections.IDictionary]) -or !$blueprint.Contains('requiredResourceAccessAdded')) {
    throw 'The ownership manifest does not record the blueprint permissions added by setup. Cleanup cannot safely modify requiredResourceAccess.'
}
$requiredResourceAccessAdded = @(Get-OptionalObjectValue -Object $blueprint -Name 'requiredResourceAccessAdded')
$currentBlueprint = Graph GET "$bpPath`?`$select=id,appId,requiredResourceAccess"
$currentRequiredResourceAccess = @($currentBlueprint.requiredResourceAccess | Where-Object { $null -ne $_ })
$restoredRequiredResourceAccess = @()
$requiredResourceAccessChanged = $false
foreach ($currentEntry in $currentRequiredResourceAccess) {
    $addedEntry = @($requiredResourceAccessAdded | Where-Object { $_.resourceAppId -eq $currentEntry.resourceAppId })
    if ($addedEntry.Count -gt 1) {
        throw "The ownership manifest contains duplicate requiredResourceAccess additions for $($currentEntry.resourceAppId)."
    }
    $addedIds = if ($addedEntry.Count -eq 1) {
        @($addedEntry[0].resourceAccess | ForEach-Object { [string]$_.id })
    }
    else {
        @()
    }
    $remainingAccess = @($currentEntry.resourceAccess | Where-Object { [string]$_.id -notin $addedIds })
    if ($remainingAccess.Count -ne @($currentEntry.resourceAccess).Count) {
        $requiredResourceAccessChanged = $true
    }
    if ($remainingAccess.Count -gt 0) {
        $restoredRequiredResourceAccess += [ordered]@{
            resourceAppId = [string]$currentEntry.resourceAppId
            resourceAccess = Copy-W365ManifestValue -Value $remainingAccess
        }
    }
}
if ($requiredResourceAccessChanged) {
    Write-Output "Removing setup-added requiredResourceAccess entries from blueprint '$blueprintObjectId'."
    Graph PATCH $bpPath @{ requiredResourceAccess = $restoredRequiredResourceAccess } | Out-Null
    Write-Output 'Removed the blueprint requiredResourceAccess entries added by setup.'
}

if ($poolManifest -and [string]$poolManifest.disposition -eq 'created') {
    $currentPool = $null
    try {
        $currentPool = Graph GET "beta/deviceManagement/virtualEndpoint/cloudPcPools/$poolId"
    }
    catch {
        if (Test-GraphResourceNotFound -ErrorRecord $_) {
            $currentPool = $null
        }
        else {
            throw
        }
    }

    if ($currentPool) {
        Write-Output "Deleting sample-owned W365 pool '$poolId'."
        Graph DELETE "beta/deviceManagement/virtualEndpoint/cloudPcPools/$poolId" | Out-Null
        Write-Output "Removed sample-owned pool $poolId."
    }
    else {
        Write-Output 'Sample-owned pool was already absent.'
    }
}

if ($viewerManifest -and !$viewerCleanupCompleted) {
    Remove-ViewerArtifacts -Manifest $viewerManifest -EnvironmentValues $envValues -ManifestPath $viewerManifestPath
}
elseif ($viewerCleanupCompleted) {
    Write-Output 'Viewer ownership cleanup was already completed; no Graph or Azure RBAC cleanup is required.'
}

$manifest['cleanup'] = [ordered]@{
    status = 'completed'
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-W365OwnershipManifest -Path $context.OwnershipManifestPath -Manifest $manifest
Write-Output 'W365 cleanup completed. azd down can now continue with Azure resource deletion.'
Write-AzdDownRecoveryTip