[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDir,
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ReleaseTag,
    [string]$GhCommand = 'gh',
    [string[]]$GhPrefixArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhCapture {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & $GhCommand @GhPrefixArguments @Arguments 2>&1
    $result = [pscustomobject]@{
        Output = @($output)
        ExitCode = $LASTEXITCODE
    }
    return ,$result
}

function Get-GhOutputText {
    param([Parameter(Mandatory)]$Result)

    return ($Result.Output -join ([Environment]::NewLine))
}

function Set-ReleaseCreationFlag {
    param([Parameter(Mandatory)][bool]$NeedsCreate)

    if (![string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        "UCRT64_RELEASE_NEEDS_CREATE=$($NeedsCreate.ToString().ToLowerInvariant())" |
            Add-Content -LiteralPath $env:GITHUB_ENV
    }
}

$repositoryRef = "$Owner/$Repository"
$repositoryResult = Invoke-GhCapture -Arguments @('api', "repos/$repositoryRef")
if ($repositoryResult.ExitCode -ne 0) {
    throw "Unable to access dependency repository $repositoryRef (exit $($repositoryResult.ExitCode)): $(Get-GhOutputText -Result $repositoryResult)"
}
try {
    $null = Get-GhOutputText -Result $repositoryResult | ConvertFrom-Json
} catch {
    throw "Dependency repository API returned invalid metadata for ${repositoryRef}: $($_.Exception.Message)"
}

$releaseList = Invoke-GhCapture -Arguments @(
    'api', '--paginate', '--slurp', "repos/$repositoryRef/releases?per_page=100")
if ($releaseList.ExitCode -ne 0) {
    throw "Unable to list releases for $repositoryRef (exit $($releaseList.ExitCode)): $(Get-GhOutputText -Result $releaseList)"
}
try {
    $releasePages = Get-GhOutputText -Result $releaseList | ConvertFrom-Json
} catch {
    throw "Release list API returned invalid metadata for ${repositoryRef}: $($_.Exception.Message)"
}
$matchingReleases = @(
    foreach ($page in @($releasePages)) {
        foreach ($release in @($page)) {
            if ([string]$release.tag_name -ceq $ReleaseTag) { $release }
        }
    }
)
if ($matchingReleases.Count -eq 0) {
    Set-ReleaseCreationFlag -NeedsCreate $true
    Write-Host "No existing $ReleaseTag release found; continuing with a first publish."
    exit 0
}
if ($matchingReleases.Count -ne 1) {
    throw "Release list returned multiple entries for $repositoryRef/$ReleaseTag."
}

$release = Invoke-GhCapture -Arguments @('api', "repos/$repositoryRef/releases/tags/$ReleaseTag")
if ($release.ExitCode -ne 0) {
    throw "Unable to inspect release metadata for $repositoryRef/$ReleaseTag (exit $($release.ExitCode)): $(Get-GhOutputText -Result $release)"
}
try {
    $releaseMetadata = Get-GhOutputText -Result $release | ConvertFrom-Json
} catch {
    throw "Release API returned invalid metadata for ${repositoryRef}/${ReleaseTag}: $($_.Exception.Message)"
}

$requiredAssets = @('gnc-ucrt64.db.tar.zst', 'gnc-ucrt64.files.tar.zst')
$assets = @($releaseMetadata.assets)
$assetNames = @($assets | ForEach-Object { [string]$_.name })
$missingAssets = @($requiredAssets | Where-Object { $_ -notin $assetNames })
if ($missingAssets.Count -eq $requiredAssets.Count) {
    if ($assets.Count -eq 0) {
        Set-ReleaseCreationFlag -NeedsCreate $false
        Write-Host "Release $repositoryRef/$ReleaseTag exists without assets; continuing with a first publish."
        exit 0
    }
    throw "Release $repositoryRef/$ReleaseTag contains package assets but no repository database assets: $($requiredAssets -join ', ')"
}
if ($missingAssets.Count -ne 0) {
    throw "Release $repositoryRef/$ReleaseTag is missing repository database asset(s): $($missingAssets -join ', ')"
}
Set-ReleaseCreationFlag -NeedsCreate $false

$download = Invoke-GhCapture -Arguments @(
    'release', 'download', $ReleaseTag,
    '-R', $repositoryRef,
    '--pattern', 'gnc-ucrt64.db.tar.zst',
    '--pattern', 'gnc-ucrt64.files.tar.zst',
    '--dir', $PackageDir,
    '--clobber')
if ($download.ExitCode -ne 0) {
    throw "Unable to download the existing repository database from $repositoryRef/$ReleaseTag (exit $($download.ExitCode)): $(Get-GhOutputText -Result $download)"
}

foreach ($required in $requiredAssets) {
    $path = Join-Path $PackageDir $required
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Existing release $repositoryRef/$ReleaseTag did not provide required repository asset: $path"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
        throw "Existing release $repositoryRef/$ReleaseTag provided an empty repository asset: $path"
    }
}
