[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedRecipeCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function Assert-PropertySet {
    param([object]$Object, [string[]]$Expected, [string]$Name)
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected_sorted = @($Expected | Sort-Object)
    Assert-Contract (($actual -join "`n") -ceq ($expected_sorted -join "`n")) `
        "$Name has an unexpected property set: $($actual -join ', ')."
}

$artifact_root = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$manifest_path = Join-Path $artifact_root 'manifest.json'
Assert-Contract (Test-Path -LiteralPath $manifest_path -PathType Leaf) `
    'The GTK staging artifact does not contain manifest.json.'

$manifest = Get-Content -LiteralPath $manifest_path -Raw | ConvertFrom-Json
Assert-PropertySet $manifest @(
    'schemaVersion', 'artifactName', 'stagingRecipeCommit', 'pkgbuildSha256',
    'packageVersion', 'architecture', 'recipe', 'source', 'patches', 'packages'
) 'manifest'
Assert-Contract ($manifest.schemaVersion -eq 1) 'Unsupported GTK staging manifest schema.'
Assert-Contract ($manifest.artifactName -ceq 'ucrt64-gtk4-4.24.0-1.1-column-focus') `
    'Unexpected GTK staging artifact name.'
Assert-Contract ($manifest.stagingRecipeCommit -ceq $ExpectedRecipeCommit.ToLowerInvariant()) `
    'The manifest staging recipe commit does not match the requested commit.'
Assert-Contract ($manifest.pkgbuildSha256 -cmatch '^[0-9a-f]{64}$') `
    'The manifest PKGBUILD SHA-256 is not a lowercase SHA-256 value.'
Assert-Contract ($manifest.packageVersion -ceq '4.24.0-1.1') `
    'Unexpected GTK staging package version.'
Assert-Contract ($manifest.architecture -ceq 'ucrt64') 'Unexpected GTK staging architecture.'

Assert-PropertySet $manifest.recipe @('repository', 'commit', 'referenceCommit') 'recipe'
Assert-Contract ($manifest.recipe.repository -ceq 'https://github.com/msys2/MINGW-packages') `
    'Unexpected GTK recipe repository.'
Assert-Contract ($manifest.recipe.commit -ceq 'de381e6b410070c15e84a3fa40fa53962057d7c7') `
    'Unexpected MSYS2 GTK recipe commit.'
Assert-Contract ($manifest.recipe.referenceCommit -ceq '62ef6f178fb03342b647f8172efb324bfe48a520') `
    'Unexpected GTK reference recipe commit.'

Assert-PropertySet $manifest.source @('url', 'sha256', 'tagCommit') 'source'
Assert-Contract ($manifest.source.url -ceq 'https://download.gnome.org/sources/gtk/4.24/gtk-4.24.0.tar.xz') `
    'Unexpected GTK source URL.'
Assert-Contract ($manifest.source.sha256 -ceq '28ba4ac1c04f86eac09b79a163cb163a4c2b54442d9f7eccc04679062a581044') `
    'Unexpected GTK source SHA-256.'
Assert-Contract ($manifest.source.tagCommit -ceq '1f47f368b17701e693918fcd078436b39d4354d1') `
    'Unexpected GTK source tag commit.'

$expected_patches = @{
    '001-fix-font-rendering.patch' = @{
        sha256 = 'ebac78616a7668edbfdd77b9959ad63239aa59ed12b995a9663bf2df7158be26'
        origin = 'msys2'
    }
    'gtkcolumnview-focus-column-ref.patch' = @{
        sha256 = '23046af144974f7a91d6a2cdad14f9de6764a667077bbb9dc6fd1a0611b3d5f9'
        origin = 'temporary-gnucash-staging'
    }
}
Assert-Contract (@($manifest.patches).Count -eq $expected_patches.Count) `
    'The GTK staging manifest must contain exactly the two reviewed patches.'
$seen_patches = @{}
foreach ($patch in @($manifest.patches)) {
    Assert-PropertySet $patch @('name', 'sha256', 'origin') "patch '$($patch.name)'"
    Assert-Contract $expected_patches.ContainsKey([string]$patch.name) `
        "Unexpected GTK staging patch '$($patch.name)'."
    Assert-Contract (!$seen_patches.ContainsKey([string]$patch.name)) `
        "Duplicate GTK staging patch '$($patch.name)'."
    $seen_patches[[string]$patch.name] = $true
    $expected_patch = $expected_patches[[string]$patch.name]
    Assert-Contract ($patch.sha256 -ceq $expected_patch.sha256) `
        "Unexpected SHA-256 for GTK staging patch '$($patch.name)'."
    Assert-Contract ($patch.origin -ceq $expected_patch.origin) `
        "Unexpected origin for GTK staging patch '$($patch.name)'."
}

$expected_packages = @{
    'mingw-w64-ucrt-x86_64-gtk4-4.24.0-1.1-any.pkg.tar.zst' = 'runtime'
    'mingw-w64-ucrt-x86_64-gtk4-debug-4.24.0-1.1-any.pkg.tar.zst' = 'debug'
}
Assert-Contract (@($manifest.packages).Count -eq $expected_packages.Count) `
    'The GTK staging manifest must contain exactly one runtime and one debug package.'
$manifest_hashes = @{}
foreach ($package in @($manifest.packages)) {
    Assert-PropertySet $package @('name', 'sha256', 'kind') "package '$($package.name)'"
    Assert-Contract $expected_packages.ContainsKey([string]$package.name) `
        "Unexpected GTK staging package '$($package.name)'."
    Assert-Contract ($package.kind -ceq $expected_packages[[string]$package.name]) `
        "Unexpected kind for GTK staging package '$($package.name)'."
    Assert-Contract ($package.sha256 -cmatch '^[0-9a-f]{64}$') `
        "Invalid SHA-256 for GTK staging package '$($package.name)'."
    Assert-Contract (!$manifest_hashes.ContainsKey([string]$package.name)) `
        "Duplicate GTK staging package '$($package.name)'."
    $package_path = Join-Path $artifact_root ([string]$package.name)
    Assert-Contract (Test-Path -LiteralPath $package_path -PathType Leaf) `
        "GTK staging package '$($package.name)' is missing."
    $actual_hash = (Get-FileHash -LiteralPath $package_path -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Contract ($actual_hash -ceq $package.sha256) `
        "SHA-256 mismatch for GTK staging package '$($package.name)'."
    $manifest_hashes[[string]$package.name] = [string]$package.sha256
}

$artifact_packages = @(Get-ChildItem -LiteralPath $artifact_root -Filter '*.pkg.tar.zst' -File)
Assert-Contract ($artifact_packages.Count -eq $expected_packages.Count) `
    'The artifact contains an unexpected number of package archives.'
foreach ($package in $artifact_packages) {
    Assert-Contract $expected_packages.ContainsKey($package.Name) `
        "The artifact contains unexpected package archive '$($package.Name)'."
}

$sums_path = Join-Path $artifact_root 'SHA256SUMS'
Assert-Contract (Test-Path -LiteralPath $sums_path -PathType Leaf) `
    'The GTK staging artifact does not contain SHA256SUMS.'
$sum_lines = @(Get-Content -LiteralPath $sums_path | Where-Object { $_ -ne '' })
Assert-Contract ($sum_lines.Count -eq $expected_packages.Count) `
    'SHA256SUMS must contain exactly the runtime and debug package entries.'
$sum_hashes = @{}
foreach ($line in $sum_lines) {
    Assert-Contract ($line -cmatch '^([0-9a-f]{64})  ([^/\\]+)$') `
        "Invalid SHA256SUMS entry '$line'."
    $sum_hash = $Matches[1]
    $sum_name = $Matches[2]
    Assert-Contract $manifest_hashes.ContainsKey($sum_name) `
        "SHA256SUMS contains unexpected package '$sum_name'."
    Assert-Contract (!$sum_hashes.ContainsKey($sum_name)) `
        "SHA256SUMS contains duplicate package '$sum_name'."
    Assert-Contract ($sum_hash -ceq $manifest_hashes[$sum_name]) `
        "SHA256SUMS does not match the manifest for '$sum_name'."
    $sum_hashes[$sum_name] = $sum_hash
}

$runtime_name = ($expected_packages.GetEnumerator() | Where-Object Value -ceq 'runtime').Key
(Resolve-Path -LiteralPath (Join-Path $artifact_root $runtime_name)).Path
