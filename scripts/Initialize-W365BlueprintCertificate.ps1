#Requires -Version 7.4
<#
.SYNOPSIS
Creates or reconciles the self-signed, non-exportable Key Vault certificate used for
key_vault_certificate blueprint authentication.

.DESCRIPTION
Provisions a self-signed RSA 2048 certificate named w365-blueprint-certificate inside the
azd environment's Key Vault. The certificate policy sets exportable=false so Key Vault never
releases the private key; all signing happens remotely inside Key Vault via the sign REST API
(see src/Win365Shared/Identity/KeyVaultBlueprintCertificateAssertionProvider.cs). This script
never reads, exports, or handles private key material, and it only ever emits the certificate's
public bytes to the caller for the follow-up Register-W365BlueprintCertificate.ps1 step.

Idempotent by default: if a certificate with this name already exists and -Rotate is not
specified, the existing certificate is reused and its public bytes are returned unchanged.


Key inputs: Environment selects the azd environment. Rotate requests a new certificate, ValidityInMonths sets its lifetime, and ConfirmResourceChanges authorizes role assignment or certificate mutation.

.OUTPUTS
An object containing the certificate name, thumbprint, public certificate
bytes, and Key Vault identifiers. No private key material is returned.

.NOTES
Mutates Key Vault and may grant the current operator Key Vault Certificates
Officer. SupportsShouldProcess and fails unless resource changes are confirmed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Environment,
    [switch]$Rotate,
    [ValidateRange(1, 60)][int]$ValidityInMonths = 12,
    [switch]$ConfirmResourceChanges
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Logging.ps1')
Initialize-SampleScriptLogging -ScriptName $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

$certificateName = 'w365-blueprint-certificate'

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
$vaultName = Get-AzdRequiredValue 'W365_KEY_VAULT_NAME'

$vaultId = (& az keyvault show `
    --subscription $subscriptionId `
    --name $vaultName `
    --query id `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
    throw "Unable to resolve Key Vault '$vaultName'."
}

function Test-CertificatesOfficerRole {
    param([Parameter(Mandatory)][string]$PrincipalId)

    $roleDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/a4417e6f-fecd-4de8-b567-7b0420556985"
    $existing = & az role assignment list `
        --subscription $subscriptionId `
        --scope $vaultId `
        --assignee-object-id $PrincipalId `
        --query "[?roleDefinitionId=='$roleDefinitionId'].id" `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Key Vault Certificates Officer role on '$vaultName'."
    }
    return ![string]::IsNullOrWhiteSpace(($existing | Out-String))
}

$operatorObjectId = (& az ad signed-in-user show --query id --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($operatorObjectId)) {
    throw 'Unable to resolve the signed-in Azure user.'
}
if (!(Test-CertificatesOfficerRole -PrincipalId $operatorObjectId)) {
    if (!$ConfirmResourceChanges) {
        throw "The current operator lacks Key Vault Certificates Officer on '$vaultName'. Re-run with -ConfirmResourceChanges to grant it, or have an administrator grant it."
    }
    if (!$PSCmdlet.ShouldProcess("$operatorObjectId on $vaultName", 'Grant Key Vault Certificates Officer')) { return }
    Write-SampleVerbose -Component 'blueprint-certificate' -Message "Granting Key Vault Certificates Officer to the current operator on '$vaultName'."
    & az role assignment create `
        --subscription $subscriptionId `
        --scope $vaultId `
        --assignee-object-id $operatorObjectId `
        --assignee-principal-type 'User' `
        --role 'a4417e6f-fecd-4de8-b567-7b0420556985' `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to grant Key Vault Certificates Officer on '$vaultName'."
    }
}

$existingCertificateId = & az keyvault certificate show `
    --subscription $subscriptionId `
    --vault-name $vaultName `
    --name $certificateName `
    --query id `
    --output tsv 2>$null
$certificateExists = $LASTEXITCODE -eq 0 -and ![string]::IsNullOrWhiteSpace(($existingCertificateId | Out-String))

if ($certificateExists -and !$Rotate) {
    Write-Host "Certificate '$certificateName' already exists in Key Vault '$vaultName'; reusing it. Pass -Rotate to issue a new one."
}
else {
    if (!$ConfirmResourceChanges) {
        throw 'Creating or rotating the blueprint certificate mutates Key Vault resources. Re-run with -ConfirmResourceChanges.'
    }
    if (!$PSCmdlet.ShouldProcess("$certificateName on $vaultName", 'Create or rotate self-signed certificate')) { return }

    $policy = @{
        issuerParameters = @{ name = 'Self' }
        keyProperties = @{
            exportable = $false
            keySize = 2048
            keyType = 'RSA'
            reuseKey = $false
        }
        secretProperties = @{ contentType = 'application/x-pkcs12' }
        x509CertificateProperties = @{
            subject = "CN=$certificateName"
            validityInMonths = $ValidityInMonths
            keyUsage = @('digitalSignature')
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $policyFile = New-TemporaryFile
    try {
        Set-Content -Path $policyFile -Value $policy -NoNewline
        Write-SampleVerbose -Component 'blueprint-certificate' -Message "Creating self-signed, non-exportable certificate '$certificateName' in '$vaultName'."
        & az keyvault certificate create `
            --subscription $subscriptionId `
            --vault-name $vaultName `
            --name $certificateName `
            --policy "@$policyFile" `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create certificate '$certificateName' in Key Vault '$vaultName'."
        }
    }
    finally {
        Remove-Item -Path $policyFile -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 3
        $pending = & az keyvault certificate pending show `
            --subscription $subscriptionId `
            --vault-name $vaultName `
            --name $certificateName `
            --query status `
            --output tsv 2>$null
    } while ($LASTEXITCODE -eq 0 -and $pending -ne 'completed' -and (Get-Date) -lt $deadline)
}

$vaultUri = (& az keyvault show `
    --subscription $subscriptionId `
    --name $vaultName `
    --query properties.vaultUri `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultUri)) {
    throw "Unable to resolve the vault URI for '$vaultName'."
}
$vaultAccessToken = (& az account get-access-token `
    --resource https://vault.azure.net `
    --query accessToken `
    --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultAccessToken)) {
    throw 'Unable to acquire a Key Vault access token.'
}
$certificateBundle = Invoke-RestMethod `
    -Method Get `
    -Uri "$($vaultUri.TrimEnd('/'))/certificates/$certificateName`?api-version=7.4" `
    -Headers @{ Authorization = "Bearer $vaultAccessToken" }
if ([string]::IsNullOrWhiteSpace($certificateBundle.cer)) {
    throw "Unable to read the public certificate bytes for '$certificateName' from Key Vault '$vaultName'."
}
# Key Vault encodes 'cer' as base64url (RFC 7515 JOSE convention); convert to standard base64 for portability.
$base64UrlCer = $certificateBundle.cer.Replace('-', '+').Replace('_', '/')
switch ($base64UrlCer.Length % 4) {
    2 { $base64UrlCer += '==' }
    3 { $base64UrlCer += '=' }
}
$certificatePublicBase64 = [Convert]::ToBase64String([Convert]::FromBase64String($base64UrlCer))

Write-Host "Certificate '$certificateName' is ready in Key Vault '$vaultName'. Only its public bytes were read; the private key was never exported."
[pscustomobject]@{
    CertificateName = $certificateName
    VaultName = $vaultName
    PublicCertificateBase64 = $certificatePublicBase64
}
