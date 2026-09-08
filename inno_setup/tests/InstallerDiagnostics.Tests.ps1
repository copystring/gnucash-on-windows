[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$diagnostics_module = (Resolve-Path (Join-Path $PSScriptRoot '..\InstallerDiagnostics.psm1')).Path
Import-Module $diagnostics_module -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('installer-diagnostics-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path

try {
    $process_log = Join-Path $test_root 'process-results.jsonl'
    $inno_log = Join-Path $test_root 'logs\installer.log'
    $script:captured_parameters = $null
    $success_launcher = {
        param($Parameters)
        $script:captured_parameters = $Parameters
        [pscustomobject]@{ ExitCode = 0 }
    }
    $exit_code = Invoke-CheckedInnoProcess -FilePath 'fixture-installer.exe' `
        -ArgumentList @('/VERYSILENT') -Description 'Fixture installer' `
        -LogPath $inno_log -ProcessResultsPath $process_log -ProcessLauncher $success_launcher
    Assert-True ($exit_code -eq 0) 'Successful process exit code was not returned.'
    Assert-True ($script:captured_parameters.ArgumentList -contains "/LOG=`"$inno_log`"") `
        'The Inno process did not receive its explicit diagnostic log path.'
    $success_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($success_record.ExitCode -eq 0) 'Successful process exit code was not recorded.'

    $failure_launcher = {
        param($Parameters)
        [pscustomobject]@{ ExitCode = 23 }
    }
    $failure_reported = $false
    try {
        Invoke-CheckedInnoProcess -FilePath 'fixture-uninstaller.exe' `
            -Description 'Fixture uninstaller' -LogPath (Join-Path $test_root 'logs\uninstaller.log') `
            -ProcessResultsPath $process_log -ProcessLauncher $failure_launcher | Out-Null
    }
    catch {
        $failure_reported = $_.Exception.Message -eq 'Fixture uninstaller failed with exit code 23.'
    }
    Assert-True $failure_reported 'A non-zero process exit code was not preserved in the failure.'
    $failure_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($failure_record.ExitCode -eq 23) 'Non-zero process exit code was not recorded.'
    Assert-True ($failure_record.Executable -eq 'fixture-uninstaller.exe') `
        'The selected uninstaller path was not recorded.'

    $missing_exit_launcher = {
        param($Parameters)
        [pscustomobject]@{ ExitCode = $null }
    }
    $missing_exit_reported = $false
    try {
        Invoke-CheckedInnoProcess -FilePath 'fixture-no-exit.exe' `
            -Description 'Fixture without exit code' -LogPath (Join-Path $test_root 'logs\no-exit.log') `
            -ProcessResultsPath $process_log -ProcessLauncher $missing_exit_launcher | Out-Null
    }
    catch {
        $missing_exit_reported = $_.Exception.Message -eq `
            'Fixture without exit code did not provide a process exit code.'
    }
    Assert-True $missing_exit_reported 'A null process exit code was accepted as success.'
    $missing_exit_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($null -eq $missing_exit_record.ExitCode) 'Null process exit code was not recorded as null.'

    $install_root = Join-Path $test_root 'synthetic-install'
    $nested = Join-Path $install_root 'share\fixture'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $nested 'remainder.bin'), [byte[]](1, 2, 3, 4, 5))
    $inventory_path = Join-Path $test_root 'remaining.csv'
    $inventory_result = Write-RemainingInstallInventory -Root $install_root -OutputPath $inventory_path
    Assert-True $inventory_result.Succeeded 'Synthetic remaining-item inventory failed.'
    Assert-True (!$inventory_result.RootEmpty) 'Non-empty synthetic installation root was reported empty.'
    $inventory = @(Import-Csv -LiteralPath $inventory_path)
    $remaining_file = $inventory | Where-Object RelativePath -eq 'share\fixture\remainder.bin'
    Assert-True ($null -ne $remaining_file) 'Remaining file relative path was not recorded.'
    Assert-True ($remaining_file.Type -eq 'File') 'Remaining file type was not recorded.'
    Assert-True ([long]$remaining_file.SizeBytes -eq 5) 'Remaining file size was not recorded.'
    Assert-True (![string]::IsNullOrWhiteSpace($remaining_file.Attributes)) `
        'Remaining file attributes were not recorded.'

    $empty_root = Join-Path $test_root 'empty-install'
    New-Item -ItemType Directory -Path $empty_root | Out-Null
    $empty_inventory_path = Join-Path $test_root 'remaining-empty.csv'
    $empty_inventory_result = Write-RemainingInstallInventory -Root $empty_root `
        -OutputPath $empty_inventory_path
    Assert-True $empty_inventory_result.RootEmpty 'Empty synthetic installation root was reported non-empty.'
    Assert-True (@(Import-Csv -LiteralPath $empty_inventory_path).Count -eq 1) `
        'Empty-root inventory must retain exactly the root record.'

    $observation_path = Join-Path $test_root 'observations.jsonl'
    $exists = Write-InstallPathObservation -Root $install_root -Label 'present' -OutputPath $observation_path
    $missing = Write-InstallPathObservation -Root (Join-Path $test_root 'missing') `
        -Label 'missing' -OutputPath $observation_path
    Assert-True $exists 'Existing installation root observation was false.'
    Assert-True (!$missing) 'Missing installation root observation was true.'
    $observations = @(Get-Content -LiteralPath $observation_path | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($observations.Count -eq 2) 'Both root-state observations were not recorded.'

    $registration_path = Join-Path $test_root 'registrations.json'
    Write-ProductRegistrationDiagnostics -Registrations @([pscustomobject]@{
        Hive = 'LocalMachine'
        View = 'Registry64'
        ProductKey = 'Fixture_is1'
        DisplayName = 'Fixture'
        InstallLocation = 'C:\Program Files\Fixture'
        UninstallString = 'unins000.exe'
    }) -OutputPath $registration_path | Out-Null
    $registrations = @(Get-Content -LiteralPath $registration_path -Raw | ConvertFrom-Json)
    Assert-True ($registrations.Count -eq 1) 'Synthetic registration snapshot count is wrong.'
    Assert-True ($registrations[0].View -eq 'Registry64') 'Synthetic registry view was not recorded.'
    Write-ProductRegistrationDiagnostics -Registrations @() -OutputPath $registration_path | Out-Null
    Assert-True ((Get-Content -LiteralPath $registration_path -Raw).Trim() -eq '[]') `
        'Empty post-uninstall registration state was not recorded explicitly.'

    $missing_inventory = Write-RemainingInstallInventory -Root (Join-Path $test_root 'absent') `
        -OutputPath (Join-Path $test_root 'absent.csv')
    Assert-True (!$missing_inventory.Succeeded) `
        'A diagnostic inventory failure must be reported without throwing over the primary failure.'
}
finally {
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

Write-Host 'Installer diagnostics tests passed.'
exit 0
