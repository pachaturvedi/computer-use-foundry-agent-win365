#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'scripts\Deploy-FoundryBootstrap.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Deploy-FoundryBootstrap.ps1 failed to parse: $($parseErrors[0].Message)"
}

$assignmentAst = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$setupRequested'
}, $true) | Select-Object -First 1
if (!$assignmentAst) {
    throw "Unable to locate the '`$setupRequested' assignment in Deploy-FoundryBootstrap.ps1 for isolated testing."
}

# Regression: when no W365 argument is bound, ($w365ArgumentNames | Where-Object {...}).Count
# used to be evaluated without wrapping the Where-Object result in @() at the call site. A
# PowerShell pipeline expression that outputs zero objects collapses to $null for the enclosing
# parenthesized expression, so '.Count' throws under strict mode instead of evaluating to 0.
$w365ArgumentNames = @(
    'AgentUserPrincipalName', 'PoolId', 'PoolIdOrUrl', 'PoolDisplayName', 'PoolDescription', 'PoolBillingPlanId',
    'PoolBillingType', 'PoolGeographicLocationType', 'PoolRegionGroup', 'PoolRegions', 'PoolImageId',
    'PoolImageType', 'PoolOsLocale', 'PoolMinimumCount', 'PoolMaximumCount', 'PoolEnableSingleSignOn',
    'HostedRuntimeIdentityObjectId', 'AuthorizeHostedRuntimeFederation', 'ViewerManagedIdentityObjectId',
    'AuthorizeViewerFederation', 'BillingConfirmed', 'UseDeviceCode', 'GraphClientTimeoutSeconds'
)

$expressionText = $assignmentAst.Right.Extent.Text
$noneBoundScript = [scriptblock]::Create(@"
Set-StrictMode -Version Latest
`$w365ArgumentNames = `$args[0]
`$scriptBoundParameters = @{}
$expressionText
"@)
$noneBound = & $noneBoundScript $w365ArgumentNames
if ($noneBound) {
    throw "'`$setupRequested' should evaluate to `$false when no W365 argument is bound, but was '$noneBound'."
}

$oneBoundScript = [scriptblock]::Create(@"
Set-StrictMode -Version Latest
`$w365ArgumentNames = `$args[0]
`$scriptBoundParameters = @{ PoolId = '11111111-1111-1111-1111-111111111111' }
$expressionText
"@)
$oneBound = & $oneBoundScript $w365ArgumentNames
if (!$oneBound) {
    throw "'`$setupRequested' should evaluate to `$true when a W365 argument is bound, but was '$oneBound'."
}

Write-Output 'Offline Foundry bootstrap: optional W365 setup detection handles zero and non-zero bound arguments passed.'
