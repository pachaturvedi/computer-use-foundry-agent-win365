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
            $packageReference.HasAttribute('VersionOverride') -or
            $null -ne $packageReference.SelectSingleNode('./Version') -or
            $null -ne $packageReference.SelectSingleNode('./VersionOverride')) {
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

$expectedProductionProjects = @(
    'src\Win365Agent\Win365Agent.csproj'
    'src\Win365Shared\Win365Shared.csproj'
    'src\Win365Viewer\Win365Viewer.csproj'
)
$actualProductionProjects = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.csproj' -Recurse |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('/', '\') }
)
$actualTestProjects = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.csproj' -Recurse |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('/', '\') }
)
if (@(Compare-Object $expectedProductionProjects $actualProductionProjects).Count -ne 0) {
    throw 'Production project set does not match the expected Agent, Shared, and Viewer projects.'
}
if (@(Compare-Object @($testProjects.Keys) $actualTestProjects).Count -ne 0) {
    throw 'Test project set must exactly match the Agent, Shared, and Viewer test projects.'
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

$dockerLines = [IO.File]::ReadAllLines((Join-Path $root 'Dockerfile'))
$centralPackagesCopy = [Array]::IndexOf($dockerLines, 'COPY Directory.Packages.props .')
$restore = [Array]::FindIndex(
    $dockerLines,
    [Predicate[string]] { param($line) $line.StartsWith('RUN dotnet restore ', [StringComparison]::Ordinal) })
if ($centralPackagesCopy -lt 0 -or $restore -lt 0 -or $centralPackagesCopy -ge $restore) {
    throw 'Docker restore must copy Directory.Packages.props before restoring projects.'
}

$dockerIgnoreLines = [IO.File]::ReadAllLines((Join-Path $root '.dockerignore'))
$requiredDockerInputs = @(
    '!Directory.Packages.props'
    '!src/Win365Shared/'
    '!src/Win365Shared/**'
    '!src/Win365Viewer/'
    '!src/Win365Viewer/**'
)
foreach ($requiredInput in $requiredDockerInputs) {
    if ($dockerIgnoreLines -notcontains $requiredInput) {
        throw "Docker build context must include '$requiredInput'."
    }
}

Write-Output 'Offline .NET structure: package versions are central and test projects map one-to-one to production projects.'
