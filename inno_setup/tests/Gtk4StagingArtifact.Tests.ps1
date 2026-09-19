[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$validator = (Resolve-Path (Join-Path $PSScriptRoot '..\validate-gtk4-staging-artifact.ps1')).Path
$recipe_commit = '1234567890abcdef1234567890abcdef12345678'
$test_root = Join-Path ([IO.Path]::GetTempPath()) ('gtk4-staging-artifact-' + [guid]::NewGuid())

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-Fixture {
    param([string]$Path)

    New-Item -ItemType Directory -Path $Path | Out-Null
    $runtime_name = 'mingw-w64-ucrt-x86_64-gtk4-4.24.0-1.2-any.pkg.tar.zst'
    $debug_name = 'mingw-w64-gtk4-debug-4.24.0-1.2-any.pkg.tar.zst'
    [IO.File]::WriteAllBytes((Join-Path $Path $runtime_name), [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $Path $debug_name), [byte[]](5, 6, 7, 8))
    $runtime_hash = (Get-FileHash -LiteralPath (Join-Path $Path $runtime_name) -Algorithm SHA256).Hash.ToLowerInvariant()
    $debug_hash = (Get-FileHash -LiteralPath (Join-Path $Path $debug_name) -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schemaVersion = 1
        artifactName = 'ucrt64-gtk4-4.24.0-1.2-column-focus-ime'
        stagingRecipeCommit = $recipe_commit
        pkgbuildSha256 = ('a' * 64)
        packageVersion = '4.24.0-1.2'
        architecture = 'ucrt64'
        recipe = [ordered]@{
            repository = 'https://github.com/msys2/MINGW-packages'
            commit = 'de381e6b410070c15e84a3fa40fa53962057d7c7'
            referenceCommit = '62ef6f178fb03342b647f8172efb324bfe48a520'
        }
        source = [ordered]@{
            url = 'https://download.gnome.org/sources/gtk/4.24/gtk-4.24.0.tar.xz'
            sha256 = '28ba4ac1c04f86eac09b79a163cb163a4c2b54442d9f7eccc04679062a581044'
            tagCommit = '1f47f368b17701e693918fcd078436b39d4354d1'
        }
        patches = @(
            [ordered]@{
                name = '001-fix-font-rendering.patch'
                sha256 = 'ebac78616a7668edbfdd77b9959ad63239aa59ed12b995a9663bf2df7158be26'
                origin = 'msys2'
            },
            [ordered]@{
                name = 'gtkcolumnview-focus-column-ref.patch'
                sha256 = '23046af144974f7a91d6a2cdad14f9de6764a667077bbb9dc6fd1a0611b3d5f9'
                origin = 'temporary-gnucash-staging'
            },
            [ordered]@{
                name = 'gtkimcontextime-filter-lifetime.patch'
                sha256 = '402e6b1e4fc23f4cdfaebb82e2429c20fa78bbb85ac70054cd83c31fd8db566a'
                origin = 'temporary-gnucash-staging'
            }
        )
        regressionFixture = [ordered]@{
            name = 'test-ime-filter-lifetime.c'
            sha256 = ('c' * 64)
        }
        packages = @(
            [ordered]@{ name = $debug_name; sha256 = $debug_hash; kind = 'debug' },
            [ordered]@{ name = $runtime_name; sha256 = $runtime_hash; kind = 'runtime' }
        )
    }
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $Path 'manifest.json') -Encoding utf8NoBOM
    @(
        "$debug_hash *$debug_name"
        "$runtime_hash  $runtime_name"
    ) | Set-Content -LiteralPath (Join-Path $Path 'SHA256SUMS') -Encoding utf8NoBOM
    return [pscustomobject]@{
        RuntimeName = $runtime_name
        RuntimePath = Join-Path $Path $runtime_name
        ManifestPath = Join-Path $Path 'manifest.json'
    }
}

New-Item -ItemType Directory -Path $test_root | Out-Null
try {
    $valid = New-Fixture (Join-Path $test_root 'valid')
    $validated_runtime = & $validator -ArtifactDirectory (Split-Path $valid.RuntimePath) `
        -ExpectedRecipeCommit $recipe_commit
    Assert-True ($validated_runtime -ceq (Resolve-Path $valid.RuntimePath).Path) `
        'The validator did not return the verified runtime package path.'

    # actions/upload-artifact preserves repo-out because the producer also
    # uploads diagnostics from packages/gtk4 below their common workspace root.
    $archive_source = Join-Path $test_root 'archive-source'
    $archive_payload = New-Fixture (Join-Path $archive_source 'repo-out')
    $archive_diagnostics = Join-Path $archive_source 'packages\gtk4'
    New-Item -ItemType Directory -Path $archive_diagnostics -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $archive_diagnostics 'build.log') `
        -Value 'diagnostic' -Encoding utf8NoBOM
    $archive_path = Join-Path $test_root 'artifact.zip'
    Compress-Archive -Path (Join-Path $archive_source '*') -DestinationPath $archive_path
    $download_root = Join-Path $test_root 'download'
    Expand-Archive -LiteralPath $archive_path -DestinationPath $download_root

    $download_root_rejected = $false
    try {
        & $validator -ArtifactDirectory $download_root `
            -ExpectedRecipeCommit $recipe_commit | Out-Null
    }
    catch {
        $download_root_rejected = $_.Exception.Message -eq `
            'The GTK staging artifact does not contain manifest.json.'
    }
    Assert-True $download_root_rejected `
        'The artifact download root unexpectedly behaved like the payload root.'

    $download_payload = Join-Path $download_root 'repo-out'
    $validated_archive_runtime = & $validator -ArtifactDirectory $download_payload `
        -ExpectedRecipeCommit $recipe_commit
    Assert-True ($validated_archive_runtime -ceq `
        (Resolve-Path (Join-Path $download_payload $archive_payload.RuntimeName)).Path) `
        'The validator did not accept the explicit repo-out payload from the extracted artifact ZIP.'

    $consumer_workflow_path = (Resolve-Path `
        (Join-Path $PSScriptRoot '..\..\.github\workflows\gnucash-ucrt64-nightly.yml')).Path
    $consumer_workflow = Get-Content -LiteralPath $consumer_workflow_path -Raw
    Assert-True ($consumer_workflow -match '(?m)^\s+\.github/workflows\s*$') `
        'The sparse checkout does not include the workflow contracts used by these tests.'
    Assert-True ($consumer_workflow.Contains(
        '$artifact_payload_directory = Join-Path $artifact_directory ''repo-out''')) `
        'The consumer workflow does not select the producer repo-out payload root.'
    Assert-True ($consumer_workflow.Contains(
        '-ArtifactDirectory $artifact_payload_directory -ExpectedRecipeCommit $expected_sha')) `
        'The consumer workflow does not validate the explicit repo-out payload root.'
    Assert-True ($consumer_workflow.Contains(
        '$debug_package = Join-Path $artifact_payload_directory')) `
        'The consumer workflow does not select the debug package from the validated payload root.'

    $wrong_commit_rejected = $false
    try {
        & $validator -ArtifactDirectory (Split-Path $valid.RuntimePath) `
            -ExpectedRecipeCommit ('f' * 40) | Out-Null
    }
    catch {
        $wrong_commit_rejected = $_.Exception.Message -eq `
            'The manifest staging recipe commit does not match the requested commit.'
    }
    Assert-True $wrong_commit_rejected 'A mismatched staging recipe commit was accepted.'

    $tampered = New-Fixture (Join-Path $test_root 'tampered')
    [IO.File]::WriteAllBytes($tampered.RuntimePath, [byte[]](9, 9, 9))
    $tamper_rejected = $false
    try {
        & $validator -ArtifactDirectory (Split-Path $tampered.RuntimePath) `
            -ExpectedRecipeCommit $recipe_commit | Out-Null
    }
    catch {
        $tamper_rejected = $_.Exception.Message -like 'SHA-256 mismatch for GTK staging package*'
    }
    Assert-True $tamper_rejected 'A package whose content did not match the manifest was accepted.'

    $invalid_marker = New-Fixture (Join-Path $test_root 'invalid-checksum-marker')
    $invalid_marker_sums = Join-Path (Split-Path $invalid_marker.RuntimePath) 'SHA256SUMS'
    $invalid_marker_lines = @(Get-Content -LiteralPath $invalid_marker_sums)
    $invalid_marker_lines[0] = $invalid_marker_lines[0] -replace ' \*', ' ?'
    $invalid_marker_lines | Set-Content -LiteralPath $invalid_marker_sums -Encoding utf8NoBOM
    $invalid_marker_rejected = $false
    try {
        & $validator -ArtifactDirectory (Split-Path $invalid_marker.RuntimePath) `
            -ExpectedRecipeCommit $recipe_commit | Out-Null
    }
    catch {
        $invalid_marker_rejected = $_.Exception.Message -like `
            'Invalid SHA256SUMS entry*'
    }
    Assert-True $invalid_marker_rejected `
        'A SHA256SUMS entry with an unsupported mode marker was accepted.'

    $wrong_arch = New-Fixture (Join-Path $test_root 'wrong-architecture')
    $wrong_arch_manifest = Get-Content -LiteralPath $wrong_arch.ManifestPath -Raw | ConvertFrom-Json
    $wrong_arch_manifest.architecture = 'mingw64'
    $wrong_arch_manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $wrong_arch.ManifestPath -Encoding utf8NoBOM
    $wrong_arch_rejected = $false
    try {
        & $validator -ArtifactDirectory (Split-Path $wrong_arch.RuntimePath) `
            -ExpectedRecipeCommit $recipe_commit | Out-Null
    }
    catch {
        $wrong_arch_rejected = $_.Exception.Message -eq 'Unexpected GTK staging architecture.'
    }
    Assert-True $wrong_arch_rejected 'A non-UCRT64 staging artifact was accepted.'

    $duplicate_patch = New-Fixture (Join-Path $test_root 'duplicate-patch')
    $duplicate_patch_manifest = Get-Content -LiteralPath $duplicate_patch.ManifestPath -Raw |
        ConvertFrom-Json
    $duplicate_patch_manifest.patches = @(
        $duplicate_patch_manifest.patches[0],
        $duplicate_patch_manifest.patches[0],
        $duplicate_patch_manifest.patches[1]
    )
    $duplicate_patch_manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $duplicate_patch.ManifestPath -Encoding utf8NoBOM
    $duplicate_patch_rejected = $false
    try {
        & $validator -ArtifactDirectory (Split-Path $duplicate_patch.RuntimePath) `
            -ExpectedRecipeCommit $recipe_commit | Out-Null
    }
    catch {
        $duplicate_patch_rejected = $_.Exception.Message -like `
            "Duplicate GTK staging patch '001-fix-font-rendering.patch'."
    }
    Assert-True $duplicate_patch_rejected `
        'A patch list with a duplicate reviewed patch was accepted.'
}
finally {
    Remove-Item -LiteralPath $test_root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'GTK4 staging artifact contract tests: PASS'
