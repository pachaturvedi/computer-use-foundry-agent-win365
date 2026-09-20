#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exercises Assert-W365AgentCertificateKeyVaultAccessConfigured in isolation (without executing the
# rest of Invoke-AzdDeployment.ps1, which requires a real azd install) by extracting only the
# functions it depends on via the script's parsed AST and invoking them with a mocked 'az' and a
# fake azd value table. This asserts the actual runtime behavior of the new key_vault_certificate
# preflight, not just that its source text is present.
$root = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $root 'scripts\Invoke-AzdDeployment.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Invoke-AzdDeployment.ps1 failed to parse: $($parseErrors[0].Message)"
}

$requiredFunctionNames = @(
    'Write-DeploymentEvent',
    'Get-AzdOptionalValue',
    'Get-AzdValue',
    'Get-W365KeyVaultName',
    'Assert-W365AgentCertificateKeyVaultAccessConfigured'
)
$functionAsts = @{}
foreach ($name in $requiredFunctionNames) {
    $match = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (!$match) {
        throw "Unable to locate function '$name' in Invoke-AzdDeployment.ps1 for isolated testing."
    }
    $functionAsts[$name] = $match.Extent.Text
}

# Assert the two RBAC-check call sites use --assignee-object-id (bypassing Graph lookup) rather
# than --assignee, matching the fix applied to both the client_secret and key_vault_certificate
# preflight functions.
foreach ($name in @('Assert-W365AgentKeyVaultAccessConfigured', 'Assert-W365AgentCertificateKeyVaultAccessConfigured')) {
    $functionMatch = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    $functionText = $functionMatch.Extent.Text
    if ($functionText -notmatch '--assignee-object-id' -or $functionText -notmatch '--fill-principal-name\s+false') {
        throw "'$name' must query role assignments with --assignee-object-id and --fill-principal-name false instead of --assignee."
    }
    if ($functionText -match '--assignee\s+\$') {
        throw "'$name' must not use the Graph-dependent --assignee argument."
    }
    if ($functionText -match '-Mode\s+DeployAll\s+or\s+manually') {
        throw "'$name' must not claim -Mode DeployAll can remediate missing Key Vault RBAC (DeployAll only previews state, it does not provision it)."
    }
}

function Invoke-IsolatedCertificatePreflight {
    param(
        [Parameter(Mandatory)][hashtable]$AzdValues,
        [Parameter(Mandatory)][scriptblock]$AzMock
    )

    # Get-AzdOptionalValue/Get-AzdValue in the real script call azd; substitute a lookup table here
    # instead of the real functions so this test never touches a live azd environment.
    $scope = [scriptblock]::Create(
        'function Get-AzdOptionalValue { param($Name) if ($script:azdValues.ContainsKey($Name)) { return $script:azdValues[$Name] } else { return "" } }' + "`n" +
        'function Get-AzdValue { param($Name) $v = Get-AzdOptionalValue $Name; if ([string]::IsNullOrWhiteSpace($v)) { throw "Missing required azd value $Name" }; return $v }' + "`n" +
        $functionAsts['Get-W365KeyVaultName'] + "`n" +
        $functionAsts['Write-DeploymentEvent'] + "`n" +
        $functionAsts['Assert-W365AgentCertificateKeyVaultAccessConfigured'] + "`n" +
        'Assert-W365AgentCertificateKeyVaultAccessConfigured'
    )

    $script:azdValues = $AzdValues
    function az { & $AzMock @args }
    try {
        & $scope
    }
    finally {
        Remove-Item function:az -ErrorAction SilentlyContinue
    }
}

$vaultId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/sample-rg/providers/Microsoft.KeyVault/vaults/single-w365-vault'
$certificateName = 'w365-blueprint-certificate'
$agentPrincipalId = '22222222-2222-2222-2222-222222222222'

$baseAzdValues = @{
    'W365_ENABLED' = 'true'
    'W365_BLUEPRINT_CREDENTIAL_MODE' = 'key_vault_certificate'
    'W365_KEY_VAULT_NAME' = 'single-w365-vault'
    'AZURE_SUBSCRIPTION_ID' = '11111111-1111-1111-1111-111111111111'
    'STATE_AGENT_PRINCIPAL_ID' = $agentPrincipalId
}

function New-AzMock {
    param([bool]$GrantCertificateRole, [bool]$GrantCryptoRole)

    return {
        $global:LASTEXITCODE = 0
        $callArguments = @($args)
        if ($callArguments[0] -eq 'keyvault' -and $callArguments[1] -eq 'certificate' -and $callArguments[2] -eq 'show') {
            return "$vaultId/certificates/$certificateName"
        }
        if ($callArguments[0] -eq 'keyvault' -and $callArguments[1] -eq 'show') {
            return $vaultId
        }
        if ($callArguments[0] -eq 'role' -and $callArguments[1] -eq 'assignment' -and $callArguments[2] -eq 'list') {
            $assigneeIndex = [Array]::IndexOf($callArguments, '--assignee-object-id')
            if ($assigneeIndex -lt 0) {
                throw "Test az mock: expected --assignee-object-id, received: $($callArguments -join ' ')"
            }
            if ('--fill-principal-name' -notin $callArguments) {
                throw "Test az mock: expected --fill-principal-name to be present."
            }
            $scopeIndex = [Array]::IndexOf($callArguments, '--scope')
            $scopeValue = $callArguments[$scopeIndex + 1]
            if ($scopeValue -like '*/certificates/*') {
                if ($GrantCertificateRole) { return '1' } else { return '0' }
            }
            if ($scopeValue -like '*/keys/*') {
                if ($GrantCryptoRole) { return '1' } else { return '0' }
            }
            throw "Test az mock: unexpected role assignment scope '$scopeValue'."
        }
        throw "Test az mock: unexpected az call: $($callArguments -join ' ')"
    }.GetNewClosure()
}

# Case 1: both roles present -> preflight succeeds without throwing.
Invoke-IsolatedCertificatePreflight -AzdValues $baseAzdValues -AzMock (New-AzMock -GrantCertificateRole $true -GrantCryptoRole $true)

# Case 2: certificate role missing -> preflight must fail closed with actionable remediation.
$threw = $false
try {
    Invoke-IsolatedCertificatePreflight -AzdValues $baseAzdValues -AzMock (New-AzMock -GrantCertificateRole $false -GrantCryptoRole $true)
}
catch {
    $threw = $true
    if ($_.Exception.Message -notmatch 'Key Vault Certificate User' -or $_.Exception.Message -notmatch 'azd provision state') {
        throw "Missing certificate-role failure did not surface actionable remediation: $($_.Exception.Message)"
    }
}
if (!$threw) { throw 'Expected the preflight to fail closed when the agent lacks Key Vault Certificate User.' }

# Case 3: crypto (key) role missing -> preflight must fail closed with actionable remediation.
$threw = $false
try {
    Invoke-IsolatedCertificatePreflight -AzdValues $baseAzdValues -AzMock (New-AzMock -GrantCertificateRole $true -GrantCryptoRole $false)
}
catch {
    $threw = $true
    if ($_.Exception.Message -notmatch 'Key Vault Crypto User' -or $_.Exception.Message -notmatch 'azd provision state') {
        throw "Missing crypto-role failure did not surface actionable remediation: $($_.Exception.Message)"
    }
}
if (!$threw) { throw 'Expected the preflight to fail closed when the agent lacks Key Vault Crypto User.' }

# Case 4: mode is client_secret -> preflight is a no-op regardless of az responses.
$clientSecretValues = $baseAzdValues.Clone()
$clientSecretValues['W365_BLUEPRINT_CREDENTIAL_MODE'] = 'client_secret'
Invoke-IsolatedCertificatePreflight -AzdValues $clientSecretValues -AzMock {
    throw "Test az mock: az should not be called when mode is not key_vault_certificate."
}

Write-Output 'Offline certificate Key Vault preflight: fail-closed RBAC verification, --assignee-object-id usage, and mode gating passed.'
