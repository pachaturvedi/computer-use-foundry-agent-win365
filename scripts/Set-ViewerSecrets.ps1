#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Environment,
    [securestring]$BlueprintClientSecret,
    [securestring]$ViewerOidcClientSecret,
    [switch]$BlueprintOnly,
    [switch]$OidcOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

$vaultName = (& azd env get-value VIEWER_KEY_VAULT_NAME 2>$null | Out-String).Trim().Trim('"')
$tenantId = (& azd env get-value AZURE_TENANT_ID 2>$null | Out-String).Trim().Trim('"')
if ([string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($tenantId)) {
    throw 'VIEWER_KEY_VAULT_NAME and AZURE_TENANT_ID must exist in the selected azd environment.'
}

if ($BlueprintOnly -and $OidcOnly) {
    throw 'Use either -BlueprintOnly or -OidcOnly, not both.'
}
$setBlueprint = !$OidcOnly
$setOidc = !$BlueprintOnly

if ($setBlueprint -and $null -eq $BlueprintClientSecret) {
    $BlueprintClientSecret = Read-Host 'Blueprint client secret' -AsSecureString
}
if ($setOidc -and $null -eq $ViewerOidcClientSecret) {
    $ViewerOidcClientSecret = Read-Host 'Viewer OIDC client secret' -AsSecureString
}

$vaultUri = (& az keyvault show `
    --name $vaultName `
    --query properties.vaultUri `
    --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultUri)) {
    throw "Unable to resolve Key Vault '$vaultName'."
}
$accessToken = (& az account get-access-token `
    --tenant $tenantId `
    --resource https://vault.azure.net `
    --query accessToken `
    --output tsv).Trim()
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
        Invoke-RestMethod `
            -Method Put `
            -Uri "$($vaultUri.TrimEnd('/'))/secrets/$Name`?api-version=7.4" `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $body | Out-Null
    }
    finally {
        $plainText = $null
        $body = $null
    }
}

if ($setBlueprint) {
    Set-KeyVaultSecureString -Name 'w365-blueprint-client-secret' -Value $BlueprintClientSecret
}
if ($setOidc) {
    Set-KeyVaultSecureString -Name 'w365-viewer-client-secret' -Value $ViewerOidcClientSecret
}

Write-Host "Viewer secrets were stored in Key Vault '$vaultName'. Secret values were not persisted to azd."
