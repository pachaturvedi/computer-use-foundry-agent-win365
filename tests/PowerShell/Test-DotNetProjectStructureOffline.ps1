#Requires -Version 7.4
# TestCategory: Offline
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $PSScriptRoot)
$centralPackagesPath = Join-Path $root 'Directory.Packages.props'
if (!(Test-Path -LiteralPath $centralPackagesPath)) {
    throw 'Directory.Packages.props is required for central package management.'
}

[xml]$centralPackages = Get-Content -LiteralPath $centralPackagesPath -Raw
if ($centralPackages.Project.PropertyGroup.ManagePackageVersionsCentrally -ne 'true') {
    throw 'ManagePackageVersionsCentrally must be enabled.'
}

$versions = @{}
foreach ($packageVersion in @($centralPackages.SelectNodes('//PackageVersion'))) {
    $versions[$packageVersion.Include] = $packageVersion.Version
}

$projectFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'src'), (Join-Path $root 'tests') `
        -Filter '*.csproj' -Recurse
)
foreach ($projectFile in $projectFiles) {
    [xml]$project = Get-Content -LiteralPath $projectFile.FullName -Raw
    foreach ($packageReference in @($project.SelectNodes('//PackageReference'))) {
        $packageName = $packageReference.Include
        if ($packageReference.HasAttribute('Version') -or
            $packageReference.HasAttribute('VersionOverride')) {
            throw "Package '$packageName' in '$($projectFile.FullName)' declares a project-local version."
        }
        if (!$versions.ContainsKey($packageName)) {
            throw "Package '$packageName' in '$($projectFile.FullName)' has no central version."
        }
    }
}

$solution = Get-Content -LiteralPath (Join-Path $root 'Win365FoundrySample.slnx') -Raw
$testProjects = [ordered]@{
    'tests\Win365Agent.Tests\Win365Agent.Tests.csproj' = '..\..\src\Win365Agent\Win365Agent.csproj'
    'tests\Win365Shared.Tests\Win365Shared.Tests.csproj' = '..\..\src\Win365Shared\Win365Shared.csproj'
    'tests\Win365Viewer.Tests\Win365Viewer.Tests.csproj' = '..\..\src\Win365Viewer\Win365Viewer.csproj'
}

foreach ($entry in $testProjects.GetEnumerator()) {
    if ($solution -notmatch [regex]::Escape($entry.Key.Replace('\', '/'))) {
        throw "Solution does not include '$($entry.Key)'."
    }

    $testProjectPath = Join-Path $root $entry.Key
    [xml]$testProject = Get-Content -LiteralPath $testProjectPath -Raw
    $projectReferences = @($testProject.SelectNodes('//ProjectReference'))
    if ($projectReferences.Count -ne 1 -or $projectReferences[0].Include -ne $entry.Value) {
        throw "'$($entry.Key)' must reference only its corresponding production project."
    }
}

$dockerfile = Get-Content -LiteralPath (Join-Path $root 'Dockerfile') -Raw
if ($dockerfile -notmatch '(?m)^COPY Directory\.Packages\.props \.\r?$') {
    throw 'Docker restore must copy Directory.Packages.props before restoring projects.'
}

Write-Output 'Offline .NET structure: package versions are central and test projects map one-to-one to production projects.'
