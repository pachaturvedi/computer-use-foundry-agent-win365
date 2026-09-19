#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host ''
Write-Host 'Starting azd up for this sample.'
Write-Host 'azd may print unlabeled "Skipped: Didn''t find new changes" rows while it checks'
Write-Host 'cached package and provisioning inputs. These rows are informational, not failures.'
Write-Host 'The labeled deployment plan below explains which sample resources will be created,'
Write-Host 'reused, or skipped and why.'
Write-Host ''
