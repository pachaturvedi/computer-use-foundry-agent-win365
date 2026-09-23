#Requires -Version 7.4
<#
.SYNOPSIS
Provides shared Azure Developer CLI command helpers.

.DESCRIPTION
Discovers a supported azd executable without trusting profile functions, invokes
azd with consistent exit-code handling, and reads required environment values.

Key inputs: azd arguments or an azd environment value name.

.OUTPUTS
The selected azd command, command output, or a required environment value.

.NOTES
Dot-source library. It does not select environments or mutate resources by itself.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Logging.ps1')
Write-SampleVerbose -Component 'AzdCommand' -Message 'Loaded shared Azure Developer CLI command helpers.'
Write-SampleDebug -Component 'AzdCommand' -Message 'Command discovery accepts only supported executable files.'

function Get-AzdCommand {
    $azdPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command azd -All -CommandType Application -ErrorAction SilentlyContinue)) {
        if ($null -eq $command) {
            continue
        }

        $source = $command.Source
        if ([string]::IsNullOrWhiteSpace($source) -or !(Test-Path -LiteralPath $source -PathType Leaf)) {
            continue
        }

        if (!$azdPaths.Contains($source)) {
            $azdPaths.Add($source)
        }
    }

    $knownAzdPaths = @()
    if (![string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $knownAzdPaths += Join-Path $env:LOCALAPPDATA 'Programs\Azure Dev CLI\azd.exe'
    }
    if (![string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $knownAzdPaths += Join-Path $env:ProgramFiles 'Azure Dev CLI\azd.exe'
    }

    foreach ($path in $knownAzdPaths) {
        if (![string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            !$azdPaths.Contains($path)) {
            $azdPaths.Add($path)
        }
    }

    $azdCandidates = $azdPaths |
        ForEach-Object {
            $candidatePath = $_
            try {
                $versionOutput = & $candidatePath version 2>$null
                if ($LASTEXITCODE -eq 0 -and ($versionOutput | Out-String) -match 'azd version\s+(\d+\.\d+\.\d+)') {
                    [pscustomobject]@{ Path = $candidatePath; Version = [version]$Matches[1] }
                }
            }
            catch {
                return
            }
        } |
        Sort-Object Version -Descending

    return $azdCandidates | Where-Object Version -ge ([version]'1.32.0') | Select-Object -First 1
}

function Invoke-Azd {
    param(
        [Parameter(Mandatory)]$Azd,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $output = & $Azd.Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    if ($CaptureOutput) {
        return ($output | Out-String).Trim()
    }

    return $output
}

function Get-AzdRequiredValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = (& azd env get-value $Name 2>$null | Out-String).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "The selected azd environment does not contain $Name."
    }

    return $value
}
