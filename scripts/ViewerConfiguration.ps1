Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'ViewerConfiguration' -Message 'Loaded viewer validation helpers.'
Write-SampleDebug -Component 'ViewerConfiguration' -Message 'Validation is fail-closed for state, URLs, credential mode, and identity binding.'

function Assert-ViewerAzureCliPrerequisites {
    if (!(Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required when DEPLOY_VIEWER=true.'
    }

    foreach ($arguments in @(
        @('containerapp', 'show', '--help'),
        @('containerapp', 'update', '--help'),
        @('containerapp', 'registry', 'set', '--help')
    )) {
        & az @arguments *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Required Azure CLI Container Apps commands are unavailable. Upgrade Azure CLI, then install or upgrade the extension if needed: az extension add --name containerapp --upgrade"
        }
    }
}

function Assert-ViewerSharedStateConfiguration {
    param(
        [Parameter(Mandatory)][string]$DeployState,
        [Parameter(Mandatory)][string]$StateResourceGroupName,
        [Parameter(Mandatory)][string]$StateStorageAccountName,
        [Parameter(Mandatory)][string]$StateContainerName,
        [Parameter(Mandatory)][string]$SessionBlobUri
    )

    if ($DeployState -ne 'true') {
        throw 'DEPLOY_VIEWER=true requires DEPLOY_STATE=true so the agent and viewer share one session store.'
    }

    $requiredValues = [ordered]@{
        STATE_RESOURCE_GROUP_NAME = $StateResourceGroupName
        STATE_STORAGE_ACCOUNT_NAME = $StateStorageAccountName
        STATE_CONTAINER_NAME = $StateContainerName
        SESSION_BLOB_URI = $SessionBlobUri
    }
    foreach ($entry in $requiredValues.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            throw "DEPLOY_VIEWER=true requires $($entry.Key)."
        }
    }

    $uri = [uri]$SessionBlobUri
    $expectedHost = "$StateStorageAccountName.blob.core.windows.net"
    $expectedPath = "/$StateContainerName/slot.json"
    if ($uri.Scheme -ne 'https' -or
        $uri.Host -ne $expectedHost -or
        $uri.AbsolutePath -ne $expectedPath -or
        ![string]::IsNullOrEmpty($uri.UserInfo) -or
        ![string]::IsNullOrEmpty($uri.Query) -or
        ![string]::IsNullOrEmpty($uri.Fragment)) {
        throw "SESSION_BLOB_URI must be exactly https://$expectedHost$expectedPath."
    }
}

function Assert-ViewerManagedEnvironmentResourceId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return
    }

    if ($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.App/managedEnvironments/[^/]+$') {
        throw 'VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID must be a full Microsoft.App/managedEnvironments Azure resource ID.'
    }
}

function Assert-ViewerCredentialMode {
    param([Parameter(Mandatory)][string]$CredentialMode)

    if ($CredentialMode -notin @('client_secret', 'managed_identity_federation')) {
        throw 'W365_BLUEPRINT_CREDENTIAL_MODE must be client_secret or managed_identity_federation.'
    }
}

function Get-ViewerOidcRedirectUri {
    param([Parameter(Mandatory)][string]$ViewerPublicUrl)

    $origin = [uri]($ViewerPublicUrl.TrimEnd('/') + '/')
    if ($origin.Scheme -ne 'https' -or
        !$origin.IsDefaultPort -or
        $origin.AbsolutePath -ne '/' -or
        ![string]::IsNullOrEmpty($origin.UserInfo) -or
        ![string]::IsNullOrEmpty($origin.Query) -or
        ![string]::IsNullOrEmpty($origin.Fragment)) {
        throw 'VIEWER_PUBLIC_URL must be an HTTPS origin without credentials, path, query, fragment, or custom port.'
    }

    return [uri]::new($origin, 'signin-oidc').ToString()
}

function Assert-ViewerIdentityModeConfiguration {
    param(
        [Parameter(Mandatory)][string]$CredentialMode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ViewerPrincipalId,
        [Parameter(Mandatory)][string]$OwnershipManifestPath
    )

    Assert-ViewerCredentialMode -CredentialMode $CredentialMode
    if ($CredentialMode -eq 'client_secret') {
        return
    }

    if (!(Test-Path -LiteralPath $OwnershipManifestPath)) {
        throw 'Managed-identity viewer authentication requires the W365 ownership manifest.'
    }
    $principalId = [guid]::Empty
    if (![guid]::TryParse($ViewerPrincipalId, [ref]$principalId) -or
        $principalId -eq [guid]::Empty) {
        throw 'Managed-identity viewer authentication requires VIEWER_IDENTITY_PRINCIPAL_ID.'
    }

    $manifest = Get-Content -LiteralPath $OwnershipManifestPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 30
    $federations = $manifest.graph.federatedIdentityCredentials
    $expectedName = "w365-viewer-$principalId"
    if (!($federations -is [System.Collections.IDictionary]) -or
        !$federations.Contains($expectedName) -or
        [string]$federations[$expectedName].subject -ne $principalId.ToString()) {
        throw "Managed-identity viewer authentication requires recorded federation '$expectedName'."
    }
}
