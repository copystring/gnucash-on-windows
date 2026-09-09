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

    $version_stdout = Join-Path $test_root 'logs\version.stdout.log'
    $version_stderr = Join-Path $test_root 'logs\version.stderr.log'
    $script:captured_version_parameters = $null
    $script:version_process = $null
    $version_launcher = {
        param($Parameters)
        $script:captured_version_parameters = $Parameters
        Set-Content -LiteralPath $Parameters.RedirectStandardOutput -Value 'GnuCash fixture 5.90'
        Set-Content -LiteralPath $Parameters.RedirectStandardError -Value ''
        $script:version_process = [pscustomobject]@{ Id = 81; ExitCode = 0; Disposed = $false }
        $script:version_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            $this.Disposed = $true
        }
        return $script:version_process
    }
    $version = Invoke-CheckedGnuCashVersion -FilePath 'fixture-gnucash.exe' `
        -StandardOutputPath $version_stdout -StandardErrorPath $version_stderr `
        -ProcessResultsPath $process_log -ProcessLauncher $version_launcher
    Assert-True $script:captured_version_parameters.Wait 'Version process was not explicitly awaited.'
    Assert-True $script:captured_version_parameters.PassThru 'Version process did not return a process handle.'
    Assert-True ($script:captured_version_parameters.WindowStyle -eq 'Hidden') `
        'Version process was not hidden.'
    Assert-True ($version.Output -contains 'GnuCash fixture 5.90') 'Version output was not read after process completion.'
    Assert-True ($version.ProcessId -eq 81) 'Version process ID was not returned.'
    Assert-True $script:version_process.Disposed 'Version process handle was not disposed.'
    $version_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($version_record.ProcessId -eq 81) 'Version process ID was not recorded.'

    $script:missing_exit_version_process = $null
    $missing_exit_version_launcher = {
        param($Parameters)
        Set-Content -LiteralPath $Parameters.RedirectStandardOutput -Value ''
        Set-Content -LiteralPath $Parameters.RedirectStandardError -Value ''
        $script:missing_exit_version_process = [pscustomobject]@{ Id = 82; ExitCode = $null; Disposed = $false }
        $script:missing_exit_version_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            $this.Disposed = $true
        }
        return $script:missing_exit_version_process
    }
    $missing_version_exit_reported = $false
    try {
        Invoke-CheckedGnuCashVersion -FilePath 'fixture-gnucash-no-exit.exe' `
            -StandardOutputPath $version_stdout -StandardErrorPath $version_stderr `
            -ProcessResultsPath $process_log -ProcessLauncher $missing_exit_version_launcher | Out-Null
    }
    catch {
        $missing_version_exit_reported = $_.Exception.Message -eq `
            'GnuCash --version did not provide a process exit code.'
    }
    Assert-True $missing_version_exit_reported 'A missing version process exit code was accepted.'
    Assert-True $script:missing_exit_version_process.Disposed `
        'Version process handle was not disposed after a missing exit code.'
    $missing_version_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($missing_version_record.ProcessId -eq 82) `
        'Version process ID was not recorded for a missing exit code.'

    $script:failed_version_process = $null
    $failed_version_launcher = {
        param($Parameters)
        Set-Content -LiteralPath $Parameters.RedirectStandardOutput -Value ''
        Set-Content -LiteralPath $Parameters.RedirectStandardError -Value 'fixture version failure'
        $script:failed_version_process = [pscustomobject]@{ Id = 83; ExitCode = 23; Disposed = $false }
        $script:failed_version_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            $this.Disposed = $true
        }
        return $script:failed_version_process
    }
    $failed_version_reported = $false
    try {
        Invoke-CheckedGnuCashVersion -FilePath 'fixture-gnucash-fails.exe' `
            -StandardOutputPath $version_stdout -StandardErrorPath $version_stderr `
            -ProcessResultsPath $process_log -ProcessLauncher $failed_version_launcher | Out-Null
    }
    catch {
        $failed_version_reported = $_.Exception.Message -like '*failed with exit code 23:*' -and `
            $_.Exception.Message -like '*fixture version failure*'
    }
    Assert-True $failed_version_reported 'A non-zero version exit code and stderr were not preserved.'
    Assert-True $script:failed_version_process.Disposed `
        'Version process handle was not disposed after a non-zero exit code.'
    $failed_version_record = Get-Content -LiteralPath $process_log | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($failed_version_record.ProcessId -eq 83 -and $failed_version_record.ExitCode -eq 23) `
        'Non-zero version process result was not recorded with its process ID.'

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

    $owner_process = [pscustomobject]@{
        Id = 42
        ProcessName = 'fixture-owner'
        Disposed = $false
        Modules = @(
            [pscustomobject]@{ FileName = (Join-Path $install_root 'bin\locked.dll') }
            [pscustomobject]@{ FileName = "${install_root}-shadow\bin\not-an-owner.dll" }
            [pscustomobject]@{ FileName = (Join-Path $test_root 'outside.dll') }
        )
    }
    $owner_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $inaccessible_process = [pscustomobject]@{ Id = 43; ProcessName = 'fixture-inaccessible'; Modules = @() }
    $module_enumerator = {
        param($process)
        if ($process.Id -eq 43) {
            throw 'fixture module inspection failed'
        }
        return $process.Modules
    }.GetNewClosure()
    $owners_path = Join-Path $test_root 'process-owners.json'
    $owner_result = Write-InstallPayloadProcessInventory -Root $install_root -OutputPath $owners_path `
        -Processes @($owner_process, $inaccessible_process) -ModuleEnumerator $module_enumerator
    Assert-True ($owner_result.OwnerCount -eq 1) 'Install-root module owner was not mapped exactly once.'
    Assert-True ($owner_result.InspectionErrorCount -eq 1) 'Module inspection failure was not recorded.'
    $owner_diagnostics = Get-Content -LiteralPath $owners_path -Raw | ConvertFrom-Json
    Assert-True (!$owner_diagnostics.InspectionComplete) `
        'Incomplete process inspection was incorrectly reported as complete.'
    Assert-True ($owner_diagnostics.Owners[0].ProcessId -eq 42) 'Module owner process ID was not recorded.'
    Assert-True ($owner_diagnostics.InspectionErrors[0].Error -eq 'fixture module inspection failed') `
        'The original module inspection exception was not preserved.'
    Assert-True (!$owner_process.Disposed) 'Borrowed injected process object was disposed.'

    $empty_modules_process = [pscustomobject]@{
        Id = 45
        ProcessName = 'fixture-empty-modules'
        Modules = @()
    }
    $null_modules_process = [pscustomobject]@{
        Id = 46
        ProcessName = 'fixture-null-modules'
        Modules = $null
    }
    $missing_file_name_process = [pscustomobject]@{
        Id = 47
        ProcessName = 'fixture-malformed-module'
        Modules = @([pscustomobject]@{ ModuleName = 'missing-filename' })
    }
    $module_shape_path = Join-Path $test_root 'process-module-shapes.json'
    $module_shape_result = Write-InstallPayloadProcessInventory -Root $install_root `
        -OutputPath $module_shape_path `
        -Processes @($empty_modules_process, $null_modules_process, $missing_file_name_process)
    Assert-True ($module_shape_result.OwnerCount -eq 0) `
        'Empty or null module results were incorrectly recorded as owners.'
    Assert-True ($module_shape_result.InspectionErrorCount -eq 1) `
        'Only the malformed module record should make the inspection incomplete.'
    $module_shape_diagnostics = Get-Content -LiteralPath $module_shape_path -Raw | ConvertFrom-Json
    Assert-True (!$module_shape_diagnostics.InspectionComplete) `
        'A malformed module record was incorrectly reported as complete.'
    Assert-True ($module_shape_diagnostics.InspectionErrors[0].ProcessId -eq 47) `
        'The malformed module record was not attributed to its process.'
    Assert-True ($module_shape_diagnostics.InspectionErrors[0].Error -eq `
        'Module record does not expose a FileName property.') `
        'The malformed module record did not retain its explicit diagnostic.'

    $unbound_process = [System.Diagnostics.Process]::new()
    try {
        $legacy_property_error = $null
        try {
            foreach ($module in @($unbound_process.Modules)) {
                $null = [string]$module.FileName
            }
        }
        catch {
            $legacy_property_error = $_.Exception.Message
        }
        Assert-True ($legacy_property_error -match 'FileName') `
            'The legacy property access did not reproduce the masked FileName diagnostic.'

        $native_getter_path = Join-Path $test_root 'process-native-getter.json'
        $native_getter_result = Write-InstallPayloadProcessInventory -Root $install_root `
            -OutputPath $native_getter_path -Processes @($unbound_process)
        Assert-True ($native_getter_result.OwnerCount -eq 0) `
            'An unconnected process was incorrectly recorded as an owner.'
        Assert-True ($native_getter_result.InspectionErrorCount -eq 1) `
            'The native Process.Modules getter failure was not recorded.'
        $native_getter_diagnostics = Get-Content -LiteralPath $native_getter_path -Raw | ConvertFrom-Json
        Assert-True (!$native_getter_diagnostics.InspectionComplete) `
            'A native Process.Modules getter failure was incorrectly reported as complete.'
        Assert-True ($native_getter_diagnostics.InspectionErrors[0].Error -match `
            'No process is associated with this object') `
            'The native Process.Modules getter failure was not preserved.'
        Assert-True ($native_getter_diagnostics.InspectionErrors[0].Error -notmatch 'FileName') `
            'The native Process.Modules getter failure was masked as a FileName diagnostic.'
    }
    finally {
        $unbound_process.Dispose()
    }

    $owned_process = [pscustomobject]@{
        Id = 44
        ProcessName = 'fixture-owned'
        Disposed = $false
        Modules = @()
    }
    $owned_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $owned_enumerator = { return $owned_process }.GetNewClosure()
    Write-InstallPayloadProcessInventory -Root $install_root `
        -OutputPath (Join-Path $test_root 'owned-processes.json') `
        -ProcessEnumerator $owned_enumerator | Out-Null
    Assert-True $owned_process.Disposed 'Process object created by the inventory was not disposed.'

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
