#Requires -Version 7.4
# TestCategory: Offline

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Show-AzdUpContext.ps1'
$tracked = @(
    'AZURE_ENV_NAME',
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_RESOURCE_GROUP',
    'AZURE_AI_ACCOUNT_NAME',
    'AZURE_AI_PROJECT_NAME',
    'RESOURCE_PREFIX',
    'AZURE_AI_MODEL_DEPLOYMENT_NAME',
    'FOUNDRY_MODEL_NAME',
    'FOUNDRY_MODEL_VERSION',
    'FOUNDRY_MODEL_SKU_NAME',
    'FOUNDRY_MODEL_SKU_CAPACITY',
    'FOUNDRY_PROJECT_OWNERSHIP',
    'FOUNDRY_PROJECT_ENDPOINT',
    'AZURE_AI_PROJECT_ID',
    'AZD_FOUNDRY_RESOURCE_GROUP_ID',
    'AZURE_FOUNDRY_RESOURCE_GROUP',
    'DEPLOY_STATE',
    'DEPLOY_VIEWER',
    'W365_ENABLED'
)
$saved = @{}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "azd-up-defaults-$([guid]::NewGuid())"

try {
    foreach ($name in $tracked) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    $env:AZURE_ENV_NAME = 'sample-dev'
    $env:AZURE_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'

    $output = & $scriptPath 6>&1 | Out-String
    if ($output -notmatch 'sample-dev-rg' -or
        $output -notmatch 'sampledevai1111111122' -or
        $output -notmatch 'sample-dev-project' -or
        $output -notmatch 'gpt-6-astra \(2026-09-03\)' -or
        $output -notmatch 'GlobalStandard' -or
        $output -notmatch '200K TPM' -or
        $output -notmatch 'credential vault still created') {
        throw "Show-AzdUpContext.ps1 did not display the generated names and reviewed defaults: $output"
    }

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $defaultsPath = Join-Path $tempRoot 'deployment.defaults.json'
    Copy-Item -LiteralPath (Join-Path $root 'config\deployment.defaults.json') -Destination $defaultsPath
    Set-Content -LiteralPath (Join-Path $tempRoot 'deployment.local.json') -Value @'
{
  "foundry": {
    "modelSkuCapacity": 999
  }
}
'@
    $localOverrideOutput = & $scriptPath -ConfigPath $defaultsPath 6>&1 | Out-String
    if ($localOverrideOutput -notmatch '200K TPM' -or $localOverrideOutput -match '999K TPM') {
        throw 'Direct azd preup incorrectly applied deployment.local.json instead of the Bicep/azd defaults.'
    }

    $env:AZURE_ENV_NAME = 'abcdefghijklmnopqrstuvwx-dev'
    $longEnvironmentOutput = & $scriptPath 6>&1 | Out-String
    if ($longEnvironmentOutput -notmatch 'abcdefghijklai1111111122') {
        throw "Long environment names did not produce a bounded deterministic Foundry account name: $longEnvironmentOutput"
    }

    $env:AZURE_ENV_NAME = 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl'
    $longProjectOutput = & $scriptPath 6>&1 | Out-String
    if ($longProjectOutput -notmatch 'Foundry project\s+abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl') {
        throw "Long environment names did not use the same 64-character project-name bound as Bicep: $longProjectOutput"
    }

    $keyVaultTemplate = Get-Content -LiteralPath (Join-Path $root 'infra\state\keyvault.bicep') -Raw
    if ($keyVaultTemplate -notmatch "var compactResourcePrefix = toLower\(replace\(resourcePrefix, '-', ''\)\)" -or
        $keyVaultTemplate -notmatch "var keyVaultName = 'k\$\{take\(compactResourcePrefix, 13\)\}-kv-\$\{resourceSuffix\}'") {
        throw 'The Key Vault template does not normalize its prefix and reserve space for its deterministic suffix.'
    }
    $keyVaultPrefixes = @(
        ('a' * 20),
        ('a' * 24),
        'abcdefghijklm-prod',
        'abc--def--ghi-prod'
    )
    foreach ($prefix in $keyVaultPrefixes) {
        $compactPrefix = $prefix.Replace('-', '').ToLowerInvariant()
        $boundedPrefix = "k$($compactPrefix.Substring(0, [Math]::Min($compactPrefix.Length, 13)))"
        $keyVaultName = "$boundedPrefix-kv-abcdef"
        if ($keyVaultName.Length -lt 3 -or
            $keyVaultName.Length -gt 24 -or
            $keyVaultName -notmatch '^[a-z][a-z0-9-]*[a-z0-9]$' -or
            $keyVaultName.Contains('--') -or
            !$keyVaultName.EndsWith('-kv-abcdef', [StringComparison]::Ordinal)) {
            throw "Prefix '$prefix' did not produce a legal Key Vault name with a preserved uniqueness suffix."
        }
    }

    $existingValues = [ordered]@{
        AZURE_AI_ACCOUNT_NAME = 'existing-account'
        AZURE_AI_PROJECT_NAME = 'existing-project'
        FOUNDRY_PROJECT_ENDPOINT = 'https://existing.services.ai.azure.com/api/projects/existing-project'
        AZURE_AI_PROJECT_ID = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/existing-rg/providers/Microsoft.CognitiveServices/accounts/existing-account/projects/existing-project'
        AZD_FOUNDRY_RESOURCE_GROUP_ID = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/existing-rg'
        AZURE_FOUNDRY_RESOURCE_GROUP = 'existing-rg'
    }
    $env:FOUNDRY_PROJECT_OWNERSHIP = 'existing'
    foreach ($entry in $existingValues.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }

    $existingOutput = & $scriptPath 6>&1 | Out-String
    if ($existingOutput -notmatch 'existing-account' -or
        $existingOutput -notmatch 'existing-project' -or
        $existingOutput -notmatch 'Project ownership\s+existing') {
        throw "Existing-project values were not preserved in the resolved summary: $existingOutput"
    }

    foreach ($missingName in $existingValues.Keys) {
        $savedValue = [Environment]::GetEnvironmentVariable($missingName, 'Process')
        [Environment]::SetEnvironmentVariable($missingName, $null, 'Process')
        $missingValueRejected = $false
        try {
            & $scriptPath 6>&1 | Out-Null
        }
        catch {
            if ($_.Exception.Message -notmatch [regex]::Escape($missingName)) {
                throw
            }
            $missingValueRejected = $true
        }
        finally {
            [Environment]::SetEnvironmentVariable($missingName, $savedValue, 'Process')
        }
        if (!$missingValueRejected) {
            throw "Existing-project mode accepted missing $missingName."
        }
    }
}
finally {
    foreach ($name in $tracked) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'azd up generated-defaults offline test passed.'
