#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [securestring]$BlueprintClientSecret,
    [securestring]$ViewerOidcClientSecret,
    [switch]$BlueprintOnly,
    [switch]$OidcOnly,
    [switch]$Overwrite,
    [string]$RoleSetupScriptPath = (Join-Path $PSScriptRoot 'Set-W365KeyVaultRoles.ps1')
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

$vaultName = (& azd env get-value W365_KEY_VAULT_NAME 2>$null | Out-String).Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    $vaultName = (& azd env get-value VIEWER_KEY_VAULT_NAME 2>$null | Out-String).Trim().Trim('"')
}
$tenantId = (& azd env get-value AZURE_TENANT_ID 2>$null | Out-String).Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($tenantId)) {
    throw 'W365_KEY_VAULT_NAME and AZURE_TENANT_ID must exist in the selected azd environment.'
}

if ($BlueprintOnly -and $OidcOnly) {
    throw 'Use either -BlueprintOnly or -OidcOnly, not both.'
}
$setBlueprint = !$OidcOnly
$setOidc = !$BlueprintOnly

& $RoleSetupScriptPath -Environment $Environment -IncludeViewer:$setOidc
if (!$?) {
    throw 'Viewer Key Vault RBAC setup failed.'
}

function Test-KeyVaultSecret {
    param([Parameter(Mandatory)][string]$Name)

    & az keyvault secret show `
        --vault-name $vaultName `
        --name $Name `
        --query id `
        --output none 2>$null
    return $LASTEXITCODE -eq 0
}

if ($setBlueprint -and !$Overwrite -and (Test-KeyVaultSecret 'w365-blueprint-client-secret')) {
    $setBlueprint = $false
    Write-Host "Blueprint secret already exists in Key Vault '$vaultName'; secure prompt skipped."
}
if ($setOidc -and !$Overwrite -and (Test-KeyVaultSecret 'w365-viewer-client-secret')) {
    $setOidc = $false
    Write-Host "Viewer OIDC secret already exists in Key Vault '$vaultName'; secure prompt skipped."
}

if ($setBlueprint -and $null -eq $BlueprintClientSecret) {
    Write-SampleVerbose -Component 'viewer-secrets' -Message 'Prompting securely for the existing blueprint client secret.'
    $BlueprintClientSecret = Read-Host 'Blueprint client secret' -AsSecureString
}
if ($setOidc -and $null -eq $ViewerOidcClientSecret) {
    Write-SampleVerbose -Component 'viewer-secrets' -Message 'Prompting securely for the viewer OIDC client secret.'
    $ViewerOidcClientSecret = Read-Host 'Viewer OIDC client secret' -AsSecureString
}
if (!$setBlueprint -and !$setOidc) {
    Write-Host "Requested secrets already exist in Key Vault '$vaultName'."
    return
}

$vaultUri = (& az keyvault show `
    --name $vaultName `
    --query properties.vaultUri `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultUri)) {
    throw "Unable to resolve Key Vault '$vaultName'."
}
$accessToken = (& az account get-access-token `
    --tenant $tenantId `
    --resource https://vault.azure.net `
    --query accessToken `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
    throw 'Unable to acquire a Key Vault access token.'
}

function Set-KeyVaultSecureString {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][securestring]$Value
    )

    $plainText = [System.Net.NetworkCredential]::new('', $Value).Password
    try {
        $body = @{ value = $plainText; attributes = @{ enabled = $true } } | ConvertTo-Json -Compress
        $headers = @{ Authorization = "Bearer $accessToken" }
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try {
                Invoke-RestMethod `
                    -Method Put `
                    -Uri "$($vaultUri.TrimEnd('/'))/secrets/$Name`?api-version=7.4" `
                    -Headers $headers `
                    -ContentType 'application/json' `
                    -Body $body | Out-Null
                return
            }
            catch {
                if ($attempt -eq 6) {
                    throw
                }
                Start-Sleep -Seconds 10
            }
        }
    }
    finally {
        $plainText = $null
        $body = $null
    }
}

if ($setBlueprint) {
    Write-SampleDebug -Component 'viewer-secrets' -Message "Writing secret name w365-blueprint-client-secret to vault $vaultName."
    Set-KeyVaultSecureString -Name 'w365-blueprint-client-secret' -Value $BlueprintClientSecret
}
if ($setOidc) {
    Write-SampleDebug -Component 'viewer-secrets' -Message "Writing secret name w365-viewer-client-secret to vault $vaultName."
    Set-KeyVaultSecureString -Name 'w365-viewer-client-secret' -Value $ViewerOidcClientSecret
}

Write-Host "Viewer secrets were stored in Key Vault '$vaultName'. Secret values were not persisted to azd."
