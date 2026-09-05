[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('publish-ucrt64-repo-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
$mockGh = Join-Path $testRoot 'mock-gh.ps1'
$mockGhCommand = Join-Path $testRoot 'mock-gh.cmd'
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\fetch-ucrt64-repo-assets.ps1')).Path

@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$ErrorActionPreference = 'Continue'
$Arguments -join ' ' | Add-Content -LiteralPath $env:MOCK_GH_LOG
if ($Arguments -contains 'api') {
    if ($env:MOCK_GH_MODE -eq 'auth-404') { Write-Error 'HTTP 404: Not Found'; exit 1 }
    $endpoint = $Arguments[-1]
    if ($endpoint -like '*/releases?per_page=100') {
        if ($env:MOCK_GH_MODE -eq 'no-release') { Write-Output '[[]]'; exit 0 }
        if ($env:MOCK_GH_MODE -eq 'multi-page') { Write-Output '[[{"tag_name":"other"}],[{"tag_name":"rolling"}]]'; exit 0 }
        Write-Output '[[{"tag_name":"rolling"}]]'
        exit 0
    }
    if ($endpoint -like '*/releases/tags/*') {
        if ($env:MOCK_GH_MODE -eq 'metadata-failure') { Write-Error 'metadata unavailable'; exit 1 }
        if ($env:MOCK_GH_MODE -eq 'empty-first-release') { Write-Output '{"tag_name":"rolling","assets":[]}'; exit 0 }
        if ($env:MOCK_GH_MODE -eq 'partial-pair') { Write-Output '{"tag_name":"rolling","assets":[{"name":"gnc-ucrt64.db.tar.zst"}]}'; exit 0 }
        if ($env:MOCK_GH_MODE -eq 'existing-packages-nodbs') { Write-Output '{"tag_name":"rolling","assets":[{"name":"gnucash-1.pkg.tar.zst"}]}'; exit 0 }
        Write-Output '{"tag_name":"rolling","assets":[{"name":"gnc-ucrt64.db.tar.zst"},{"name":"gnc-ucrt64.files.tar.zst"}]}'
        exit 0
    }
    Write-Output '{}'
    exit 0
}
if ($Arguments -contains 'download') {
    if ($env:MOCK_GH_MODE -eq 'asset-404') { Write-Error 'HTTP 404: Not Found'; exit 1 }
    if ($env:MOCK_GH_MODE -eq 'download-failure') { Write-Error 'network failure'; exit 1 }
    $dirIndex = [Array]::IndexOf($Arguments, '--dir')
    $packageDir = $Arguments[$dirIndex + 1]
    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
    Set-Content -LiteralPath (Join-Path $packageDir 'gnc-ucrt64.db.tar.zst') -Value 'db'
    if ($env:MOCK_GH_MODE -eq 'missing-download') { exit 0 }
    if ($env:MOCK_GH_MODE -eq 'empty-download') {
        [IO.File]::WriteAllBytes((Join-Path $packageDir 'gnc-ucrt64.files.tar.zst'), [byte[]]@())
        exit 0
    }
    Set-Content -LiteralPath (Join-Path $packageDir 'gnc-ucrt64.files.tar.zst') -Value 'files'
    exit 0
}
if ($Arguments -contains 'upload') {
    Set-Content -LiteralPath $env:MOCK_UPLOAD_MARKER -Value 'upload-called'
    exit 0
}
exit 0
'@ | Set-Content -LiteralPath $mockGh -Encoding utf8
@'
@echo off
pwsh -NoProfile -File "%~dp0mock-gh.ps1" %*
'@ | Set-Content -LiteralPath $mockGhCommand -Encoding ascii

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

try {
    foreach ($case in @(
        @{ Name = 'no-release'; ExpectedExit = 0; ExpectedUpload = $true; ExpectedCreate = 'true' },
        @{ Name = 'empty-first-release'; ExpectedExit = 0; ExpectedUpload = $true; ExpectedCreate = 'false' },
        @{ Name = 'existing-release'; ExpectedExit = 0; ExpectedUpload = $true; ExpectedCreate = 'false' },
        @{ Name = 'multi-page'; ExpectedExit = 0; ExpectedUpload = $true; ExpectedCreate = 'false' },
        @{ Name = 'auth-404'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = $null },
        @{ Name = 'metadata-failure'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = $null },
        @{ Name = 'asset-404'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = 'false' },
        @{ Name = 'partial-pair'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = $null },
        @{ Name = 'existing-packages-nodbs'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = $null },
        @{ Name = 'download-failure'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = 'false' },
        @{ Name = 'missing-download'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = 'false' },
        @{ Name = 'empty-download'; ExpectedExit = 1; ExpectedUpload = $false; ExpectedCreate = 'false' })) {
        $caseRoot = Join-Path $testRoot $case.Name
        $packageDir = Join-Path $caseRoot 'packages'
        New-Item -ItemType Directory -Path $packageDir | Out-Null
        $env:MOCK_GH_MODE = $case.Name
        $env:MOCK_GH_LOG = Join-Path $caseRoot 'gh.log'
        $env:MOCK_UPLOAD_MARKER = Join-Path $caseRoot 'upload.marker'
        $env:GITHUB_ENV = Join-Path $caseRoot 'github.env'

        $ErrorActionPreference = 'Continue'
        $helperOutput = & pwsh -NoProfile -File $helper -PackageDir $packageDir -Owner 'owner' -Repository 'deps' -ReleaseTag 'rolling' -GhCommand $mockGhCommand 2>&1
        $helperExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Assert-True ($helperExit -eq $case.ExpectedExit) "$($case.Name): expected helper exit $($case.ExpectedExit), got ${helperExit}: $helperOutput"
        $flag = if (Test-Path -LiteralPath $env:GITHUB_ENV) { Get-Content -LiteralPath $env:GITHUB_ENV -Raw } else { $null }
        if ($null -eq $case.ExpectedCreate) {
            Assert-True ($null -eq $flag) "$($case.Name): unexpected release creation flag"
        } else {
            Assert-True ($flag.Trim() -eq "UCRT64_RELEASE_NEEDS_CREATE=$($case.ExpectedCreate)") "$($case.Name): unexpected release creation flag"
        }
        if ($helperExit -eq 0) {
            & $mockGhCommand upload
        }
        Assert-True ((Test-Path -LiteralPath $env:MOCK_UPLOAD_MARKER -PathType Leaf) -eq $case.ExpectedUpload) "$($case.Name): incorrect upload gate result"
        if ($case.Name -eq 'existing-release') {
            Assert-True (Test-Path -LiteralPath (Join-Path $packageDir 'gnc-ucrt64.db.tar.zst') -PathType Leaf) 'existing-release: database asset missing'
            Assert-True (Test-Path -LiteralPath (Join-Path $packageDir 'gnc-ucrt64.files.tar.zst') -PathType Leaf) 'existing-release: files asset missing'
        }
        Write-Host "$($case.Name): passed"
    }
    Write-Host 'fetch-ucrt64-repo-assets mock tests passed.'
} finally {
    $cleanupTarget = (Resolve-Path -LiteralPath $testRoot).Path
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanupTarget -ne $resolvedTestRoot -or !$cleanupTarget.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanupTarget"
    }
    Remove-Item -LiteralPath $cleanupTarget -Recurse -Force
}

# A deliberately failing child process must not become the caller's exit code.
exit 0
