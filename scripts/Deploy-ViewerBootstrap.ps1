#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ViewerConfiguration.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

if ($env:DEPLOY_VIEWER -ne 'true') {
    Write-Host 'Viewer deployment skipped because DEPLOY_VIEWER is not true.'
    return
}

$required = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_RESOURCE_GROUP',
    'VIEWER_APP_NAME',
    'VIEWER_IDENTITY_PRINCIPAL_ID',
    'VIEWER_IDENTITY_RESOURCE_ID',
    'VIEWER_REGISTRY_NAME',
    'VIEWER_REGISTRY_ENDPOINT',
    'VIEWER_IMAGE_NAME',
    'STATE_STORAGE_ACCOUNT_NAME',
    'STATE_CONTAINER_NAME',
    'SESSION_BLOB_URI'
)
foreach ($name in $required) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing required viewer deployment value $name."
    }
}

Assert-ViewerSharedStateConfiguration `
    -DeployState $env:DEPLOY_STATE `
    -StateResourceGroupName $env:AZURE_RESOURCE_GROUP `
    -StateStorageAccountName $env:STATE_STORAGE_ACCOUNT_NAME `
    -StateContainerName $env:STATE_CONTAINER_NAME `
    -SessionBlobUri $env:SESSION_BLOB_URI
Assert-ViewerManagedEnvironmentResourceId `
    -ResourceId $env:VIEWER_MANAGED_ENVIRONMENT_RESOURCE_ID

Assert-ViewerAzureCliPrerequisites
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Get-ViewerImageBuildHash {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $projectRoot = Join-Path $RepositoryRoot 'src\Win365Agent'
    $inputFiles = @(
        Get-Item -LiteralPath (Join-Path $RepositoryRoot '.dockerignore')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'Dockerfile')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'NuGet.Config')
        Get-ChildItem -LiteralPath $projectRoot -File -Recurse |
            Where-Object {
                $_.FullName -notmatch '[\\/](bin|obj)[\\/]' -and
                $_.Name -notmatch '^\.env' -and
                $_.Extension -notin @('.pfx', '.pem', '.key') -and
                $_.Name -ne 'appsettings.Development.json'
            }
    ) | Sort-Object FullName

    $fingerprints = foreach ($file in $inputFiles) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relativePath`n$fileHash"
    }
    $baseImageRefresh = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM',
        [Globalization.CultureInfo]::InvariantCulture)
    $buildInputs = @($fingerprints) + "base-image-refresh`n$baseImageRefresh"
    $bytes = [Text.Encoding]::UTF8.GetBytes($buildInputs -join "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$subscription = $env:AZURE_SUBSCRIPTION_ID
$resourceGroup = $env:AZURE_RESOURCE_GROUP
$appName = $env:VIEWER_APP_NAME
$registryName = $env:VIEWER_REGISTRY_NAME
$registryEndpoint = $env:VIEWER_REGISTRY_ENDPOINT
$identityPrincipalId = $env:VIEWER_IDENTITY_PRINCIPAL_ID
$identityResourceId = $env:VIEWER_IDENTITY_RESOURCE_ID
$imageName = $env:VIEWER_IMAGE_NAME
$repositoryRoot = Split-Path $PSScriptRoot
$imageRepository = ($imageName -split ':', 2)[0]
if ([string]::IsNullOrWhiteSpace($imageRepository)) {
    throw "VIEWER_IMAGE_NAME '$imageName' must contain an ACR repository name."
}
$buildHash = Get-ViewerImageBuildHash -RepositoryRoot $repositoryRoot
$buildTag = "build-$($buildHash.Substring(0, 12))"
$resolvedImageName = "${imageRepository}:$buildTag"

if ($env:VIEWER_LIVE_ENABLED -eq 'true') {
    $liveRequired = @(
        'VIEWER_PUBLIC_URL',
        'VIEWER_CLIENT_ID',
        'OPERATOR_TENANT_ID',
        'OPERATOR_OBJECT_ID',
        'W365_TENANT_ID',
        'W365_BLUEPRINT_ID',
        'W365_AGENT_ID',
        'W365_AGENT_OBJECT_ID',
        'W365_AGENT_USER_ID',
        'SCREENSHARE_SDK_URL',
        'SCREENSHARE_FRAME_ORIGINS',
        'SCREENSHARE_APP_URL',
        'W365_KEY_VAULT_NAME',
        'W365_BLUEPRINT_CREDENTIAL_MODE'
    )
    foreach ($name in $liveRequired) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "VIEWER_LIVE_ENABLED=true requires $name."
        }
    }
    if ($env:W365_ENABLED -ne 'true') {
        throw 'VIEWER_LIVE_ENABLED=true requires W365_ENABLED=true.'
    }
    Assert-ViewerCredentialMode -CredentialMode $env:W365_BLUEPRINT_CREDENTIAL_MODE
    Assert-ViewerIdentityModeConfiguration `
        -CredentialMode $env:W365_BLUEPRINT_CREDENTIAL_MODE `
        -ViewerPrincipalId $env:VIEWER_IDENTITY_PRINCIPAL_ID `
        -OwnershipManifestPath (Join-Path (Split-Path $PSScriptRoot) ".azure\$($env:AZURE_ENV_NAME)\w365-ownership.json")

    $requiredSecrets = @('w365-viewer-client-secret')
    if ($env:W365_BLUEPRINT_CREDENTIAL_MODE -eq 'client_secret') {
        $requiredSecrets += 'w365-blueprint-client-secret'
    }
    foreach ($secretName in $requiredSecrets) {
        & az keyvault secret show `
            --subscription $subscription `
            --vault-name $env:W365_KEY_VAULT_NAME `
            --name $secretName `
            --query id `
            --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Key Vault '$($env:W365_KEY_VAULT_NAME)' must contain secret '$secretName'."
        }
    }
}

$repositoryListOutput = & az acr repository list `
    --subscription $subscription `
    --name $registryName `
    --query "[?@=='$imageRepository'] | [0]" `
    --output tsv
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect repositories in Azure Container Registry '$registryName'."
}
$repositoryExists = if ($null -eq $repositoryListOutput) { '' } else { ([string]$repositoryListOutput).Trim() }

$imageExists = $false
if ($repositoryExists -eq $imageRepository) {
    $existingTagOutput = & az acr repository show-tags `
        --subscription $subscription `
        --name $registryName `
        --repository $imageRepository `
        --query "[?@=='$buildTag'] | [0]" `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect tags for '$imageRepository' in Azure Container Registry '$registryName'."
    }
    $existingTag = if ($null -eq $existingTagOutput) { '' } else { ([string]$existingTagOutput).Trim() }
    $imageExists = $existingTag -eq $buildTag
}

if ($imageExists) {
    Write-Host "Reusing unchanged viewer image: $registryEndpoint/$resolvedImageName"
}
else {
    Write-Host "Viewer source changed; building image: $registryEndpoint/$resolvedImageName"
    Invoke-Az @(
        'acr', 'build',
        '--subscription', $subscription,
        '--registry', $registryName,
        '--image', $resolvedImageName,
        '--file', (Join-Path $repositoryRoot 'Dockerfile'),
        $repositoryRoot,
        '--output', 'none'
    )
}

$registryIdOutput = & az acr show `
    --subscription $subscription `
    --name $registryName `
    --query 'id' `
    --output tsv
$registryId = if ($null -eq $registryIdOutput) { '' } else { ([string]$registryIdOutput).Trim() }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($registryId)) {
    throw 'Unable to resolve the viewer registry resource ID.'
}

for ($attempt = 1; $attempt -le 5; $attempt++) {
    $role = & az role assignment list `
        --subscription $subscription `
        --scope $registryId `
        --assignee-object-id $identityPrincipalId `
        --query "[?roleDefinitionName=='AcrPull'].roleDefinitionName" `
        --output tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and $role -eq 'AcrPull') {
        break
    }
    if ($attempt -eq 5) {
        throw 'AcrPull did not propagate within five minutes.'
    }
    Write-Host "Waiting for AcrPull propagation ($attempt/5)..."
    Start-Sleep -Seconds 60
}

Invoke-Az @(
    'containerapp', 'registry', 'set',
    '--subscription', $subscription,
    '--resource-group', $resourceGroup,
    '--name', $appName,
    '--server', $registryEndpoint,
    '--identity', $identityResourceId
)
Invoke-Az @(
    'containerapp', 'update',
    '--subscription', $subscription,
    '--resource-group', $resourceGroup,
    '--name', $appName,
    '--image', "$registryEndpoint/$resolvedImageName",
    '--output', 'none'
)

$hostnameOutput = & az containerapp show `
    --subscription $subscription `
    --resource-group $resourceGroup `
    --name $appName `
    --query 'properties.configuration.ingress.fqdn' `
    --output tsv
$hostname = if ($null -eq $hostnameOutput) { '' } else { ([string]$hostnameOutput).Trim() }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostname)) {
    throw 'Unable to resolve the viewer hostname.'
}

$healthUri = "https://$hostname/health"
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
$healthAttempt = 0
$lastHealthObservation = 'No response received.'
Write-Host "Waiting up to five minutes for the ACA viewer to become healthy: $healthUri"
do {
    $healthAttempt++
    try {
        $health = Invoke-RestMethod -Uri $healthUri -TimeoutSec 10 -Verbose:$false
        if ($health.status -eq 'healthy') {
            & azd env set VIEWER_PUBLIC_URL "https://$hostname"
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to save VIEWER_PUBLIC_URL to the azd environment.'
            }
            Write-Host "ACA viewer is healthy after $healthAttempt health-check attempt(s): $healthUri"
            return
        }
        $reportedStatus = if ([string]::IsNullOrWhiteSpace([string]$health.status)) {
            '<missing>'
        }
        else {
            [string]$health.status
        }
        $lastHealthObservation = "The endpoint responded with status '$reportedStatus'."
    }
    catch {
        $lastHealthObservation = $_.Exception.Message
    }

    Write-SampleVerbose `
        -Component 'viewer-health' `
        -Message "Attempt $healthAttempt is not healthy yet. $lastHealthObservation Retrying in 10 seconds."
    if ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 10
    }
} while ([DateTimeOffset]::UtcNow -lt $deadline)

throw "ACA viewer '$appName' did not return status=healthy from '$healthUri' within five minutes after $healthAttempt attempt(s). Last observation: $lastHealthObservation Check the latest Container Apps revision and console logs."
