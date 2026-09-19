[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\prepare-html-help-workshop.ps1')).Path
$test_root = Join-Path ([IO.Path]::GetTempPath()) ('html-help-workshop-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path
$previous_runner_temp = $env:RUNNER_TEMP
$env:RUNNER_TEMP = $resolved_test_root

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

try {
    $fixture = Join-Path $test_root 'fixture.exe'
    [IO.File]::WriteAllBytes($fixture, [byte[]](1, 2, 3, 4))

    $outside_output = Join-Path ([IO.Path]::GetTempPath()) ('html-help-workshop-outside-' + [guid]::NewGuid())
    $outside_rejected = $false
    try {
        & $helper -InstallerPath $fixture -OutputDirectory $outside_output | Out-Null
    }
    catch {
        $outside_rejected = $_.Exception.Message -match 'must be below RUNNER_TEMP'
    }
    Assert-True $outside_rejected 'The helper accepted an output directory outside RUNNER_TEMP.'
    Write-Host 'temporary output path: passed'

    $output_directory = Join-Path $test_root 'output'
    $hash_rejected = $false
    try {
        & $helper -InstallerPath $fixture -OutputDirectory $output_directory | Out-Null
    }
    catch {
        $hash_rejected = $_.Exception.Message -match 'Unexpected SHA-256'
    }
    Assert-True $hash_rejected 'The helper accepted an installer with an unexpected SHA-256.'
    Assert-True (!(Test-Path -LiteralPath $output_directory)) 'The helper extracted files before validating the installer hash.'
    Write-Host 'installer hash and no-extract-on-failure: passed'

    Write-Host 'HTML Help Workshop helper tests passed.'
}
finally {
    $env:RUNNER_TEMP = $previous_runner_temp
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

exit 0
