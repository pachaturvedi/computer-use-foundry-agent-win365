#Requires -Version 7.4
<#
.SYNOPSIS
Stores the W365 blueprint credential in the shared Key Vault.

.DESCRIPTION
resolves the environment vault, optionally bootstraps operator RBAC, and securely
prompts for blueprint material or the explicitly selected legacy viewer OIDC
client secret. Secretless managed-identity mode never calls the OIDC path.


Key inputs: Environment, secure strings, BlueprintOnly, OidcOnly, Overwrite,
BootstrapOperatorAccess, and role-setup script override.

.OUTPUTS
Key Vault secret versions and redacted completion messages.

.NOTES
Credential-mutating. Secret values are never printed, returned, written to source, or stored in azd environment state.
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [securestring]$BlueprintClientSecret,
    [securestring]$ViewerOidcClientSecret,
    [switch]$BlueprintOnly,
    [switch]$OidcOnly,
    [switch]$Overwrite,
    [switch]$BootstrapOperatorAccess,
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

if ($BlueprintOnly -and $OidcOnly) { throw 'Use either -BlueprintOnly or -OidcOnly, not both.' }
$setBlueprint = !$OidcOnly
$setOidc = $OidcOnly

if ($BootstrapOperatorAccess) {
    & $RoleSetupScriptPath -Environment $Environment
    if (!$?) {
        throw 'Key Vault operator-access bootstrap failed.'
    }
}

function Test-KeyVaultSecret {
    param([Parameter(Mandatory)][string]$Name)

    $result = & az keyvault secret show `
        --vault-name $vaultName `
        --name $Name `
        --query id `
        --output none 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if (($result | Out-String) -match '(?im)^\s*(?:ERROR:\s*)?\(?SecretNotFound\)?(?:\s|:)') {
        return $false
    }

    throw "Unable to determine whether secret '$Name' exists in Key Vault '$vaultName'. Verify Azure authentication, Key Vault access, and service availability before retrying."
}

if (!$Overwrite -and (Test-KeyVaultSecret 'w365-blueprint-client-secret')) {
    $setBlueprint = $false
    Write-Host "Blueprint secret already exists in Key Vault '$vaultName'; secure prompt skipped."
}
if ($setOidc -and !$Overwrite -and (Test-KeyVaultSecret 'w365-viewer-client-secret')) {
    $setOidc = $false
    Write-Host "Viewer OIDC fallback secret already exists in Key Vault '$vaultName'; secure prompt skipped."
}

if ($null -eq $BlueprintClientSecret) {
    if (!$setBlueprint) { $BlueprintClientSecret = ConvertTo-SecureString 'unused' -AsPlainText -Force }
    elseif ($env:AZD_NON_INTERACTIVE -ceq 'true') {
        throw "Blueprint client secret is missing from Key Vault '$vaultName'. Run .\scripts\Set-ViewerSecrets.ps1 -Environment '$Environment' -BlueprintOnly interactively, then rerun the attempt-scoped protected Invoke-AzdUp.ps1 block in docs\W365-SETUP.md for environment '$Environment'."
    }
    else {
        Write-SampleVerbose -Component 'viewer-secrets' -Message 'Prompting securely for the existing blueprint client secret.'
        $BlueprintClientSecret = Read-Host 'Blueprint client secret' -AsSecureString
    }
}
if ($setOidc -and $null -eq $ViewerOidcClientSecret) {
    if ($env:AZD_NON_INTERACTIVE -ceq 'true') {
        throw "Viewer OIDC client secret is missing from Key Vault '$vaultName'. Run .\scripts\Set-ViewerSecrets.ps1 -Environment '$Environment' -OidcOnly interactively."
    }
    $ViewerOidcClientSecret = Read-Host 'Viewer OIDC client secret' -AsSecureString
}
if (!$setBlueprint) {
    if (!$setOidc) { Write-Host "Requested secrets already exist in Key Vault '$vaultName'."; return }
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
    Write-SampleDebug -Component 'viewer-secrets' -Message "Writing explicit fallback secret name w365-viewer-client-secret to vault $vaultName."
    Set-KeyVaultSecureString -Name 'w365-viewer-client-secret' -Value $ViewerOidcClientSecret
}

Write-Host "Selected viewer/W365 secret handling completed for Key Vault '$vaultName'. Secret values were not persisted to azd."
