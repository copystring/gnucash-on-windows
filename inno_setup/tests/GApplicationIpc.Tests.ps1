[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = (Resolve-Path (Join-Path $PSScriptRoot '..\GApplicationIpc.psm1')).Path
Import-Module $module -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-MockProcess {
    param(
        [int]$Id,
        [string]$Path,
        [Nullable[int]]$ExitCode,
        [bool]$HasExited,
        [object[]]$Modules = @()
    )

    $process = [pscustomobject]@{
        Id = $Id
        Path = $Path
        ExitCode = $ExitCode
        HasExited = $HasExited
        Modules = $Modules
        Killed = $false
        Disposed = $false
    }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param([int]$TimeoutMilliseconds)
        return $this.HasExited
    }
    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $this.Killed = $true
        $this.HasExited = $true
    }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    return $process
}
$new_mock_process = ${function:New-MockProcess}

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('gapplication-ipc-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path

try {
    $fixture = Join-Path $test_root 'gapplication-ipc-fixture.exe'
    $install = Join-Path $test_root 'installed'
    $installed_helper = Join-Path $install 'bin\gdbus.exe'
    $installed_gio = Join-Path $install 'bin\libgio-2.0-0.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $installed_helper) -Force | Out-Null
    Set-Content -LiteralPath $fixture -Value 'fixture'
    Set-Content -LiteralPath $installed_helper -Value 'fixture'
    Set-Content -LiteralPath $installed_gio -Value 'fixture'

    $recipe = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\gnucash-mingw64.iss') -Raw
    $gdbus_source = [regex]::Matches(
        $recipe,
        '(?m)^Source: "@MINGW_DIR@\\bin\\gdbus\.exe"; DestDir: "\{app\}\\bin"; Components: main\s*$')
    Assert-True ($gdbus_source.Count -eq 1) `
        'The Inno recipe must package exactly one required gdbus.exe beside libgio.'

    $state = [pscustomobject]@{
        Primary = $null
        PrimaryCwd = $null
        ForwardCwd = $null
        Launched = [System.Collections.Generic.List[string]]::new()
    }
    $launcher = {
        param($Parameters, $Purpose)
        $state.Launched.Add($Purpose)
        switch ($Purpose) {
            'Primary' {
                $state.PrimaryCwd = $Parameters.WorkingDirectory
                $ready = [string]$Parameters.ArgumentList[1]
                $ready = $ready.Trim('"')
                $bus_probe = ([string]$Parameters.ArgumentList[2]).Trim('"')
                Set-Content -LiteralPath $ready -Value 'remote=false' -Encoding utf8
                @(
                    'succeeded=true'
                    'unique_name=:1.1'
                ) | Set-Content -LiteralPath $bus_probe -Encoding utf8
                if ($Parameters.Environment.G_DBUS_DEBUG -ne 'address') {
                    throw 'Primary did not enable the bounded GDBus address diagnostics.'
                }
                $state.Primary = & $new_mock_process -Id 101 -Path $Parameters.FilePath `
                    -ExitCode 0 -HasExited $false -Modules @(
                        [pscustomobject]@{ FileName = $installed_gio }
                    )
                return $state.Primary
            }
            'Forward' {
                $state.ForwardCwd = $Parameters.WorkingDirectory
                $record = ([string]$Parameters.ArgumentList[2]).Trim('"')
                $argument = [string]$Parameters.ArgumentList[1]
                $target = [IO.Path]::GetFullPath((Join-Path $Parameters.WorkingDirectory $argument))
                $uri = [Uri]::new($target).AbsoluteUri
                @(
                    'remote=true'
                    "cwd=$($Parameters.WorkingDirectory)"
                    "argument=$argument"
                    "uri=$uri"
                ) | Set-Content -LiteralPath $record -Encoding utf8
                return & $new_mock_process -Id 102 -Path $Parameters.FilePath -ExitCode 0 -HasExited $true
            }
            'Reject' {
                Set-Content -LiteralPath $Parameters.RedirectStandardError `
                    -Value 'Intentional remote fixture rejection.' -Encoding utf8
                return & $new_mock_process -Id 103 -Path $Parameters.FilePath -ExitCode 23 -HasExited $true
            }
            'Quit' {
                $state.Primary.HasExited = $true
                return & $new_mock_process -Id 104 -Path $Parameters.FilePath -ExitCode 0 -HasExited $true
            }
            default { throw "Unexpected fixture process purpose: $Purpose" }
        }
    }.GetNewClosure()
    $helper_start = [DateTime]::UtcNow.ToString('o')
    $snapshot_state = [pscustomobject]@{ Call = 0 }
    $snapshots = {
        $snapshot_state.Call++
        $processes = if ($snapshot_state.Call -eq 2) {
            @([pscustomobject]@{
                ProcessId = 201
                ImagePath = $installed_helper
                StartTimeUtc = $helper_start
            })
        }
        else { @() }
        return [pscustomobject]@{
            InspectionComplete = $true
            Processes = $processes
            InspectionErrors = @()
        }
    }.GetNewClosure()
    $diagnostics = Join-Path $test_root 'success-diagnostics'
    New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $diagnostics 'gapplication-ipc-primary.txt') `
        -Value 'remote=true' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $diagnostics 'gapplication-ipc-forward.txt') `
        -Value 'stale=true' -Encoding utf8
    $result = Invoke-GApplicationIpcRuntimeTest -FixturePath $fixture -InstallRoot $install `
        -DiagnosticsDirectory $diagnostics -ProcessLauncher $launcher `
        -GdbusSnapshotProvider $snapshots
    Assert-True $result.Succeeded 'Mocked installed-runtime IPC contract did not pass.'
    Assert-True ($result.PrimaryProcessId -eq 101 -and $result.ForwardProcessId -eq 102 -and `
        $result.RejectedProcessId -eq 103 -and $result.QuitProcessId -eq 104) `
        'IPC process identities were not preserved.'
    Assert-True (($state.Launched -join ',') -eq 'Primary,Forward,Reject,Quit') `
        'IPC process lifecycle did not run in the required order.'
    Assert-True (![string]::Equals($state.PrimaryCwd, $state.ForwardCwd,
            [StringComparison]::OrdinalIgnoreCase)) `
        'Primary and forwarding clients used the same working directory.'
    Assert-True $state.Primary.Disposed 'Primary process object was not disposed.'
    Assert-True (![string]::Equals($result.DiagnosticsDirectory, $diagnostics,
            [StringComparison]::OrdinalIgnoreCase)) `
        'IPC diagnostics reused the caller directory and could consume stale records.'
    Assert-True ([IO.Path]::GetFullPath($result.DiagnosticsDirectory).StartsWith(
            ([IO.Path]::GetFullPath($diagnostics).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar),
            [StringComparison]::OrdinalIgnoreCase)) `
        'IPC diagnostics were not isolated below the caller directory.'
    $success_record = Get-Content -LiteralPath `
        (Join-Path $result.DiagnosticsDirectory 'gapplication-ipc-result.json') `
        -Raw | ConvertFrom-Json
    Assert-True $success_record.Succeeded 'Successful IPC result was not recorded.'

    $state.Primary = $null
    $state.Launched = [System.Collections.Generic.List[string]]::new()
    $snapshot_state.Call = 0
    $outside_snapshots = {
        $snapshot_state.Call++
        $processes = if ($snapshot_state.Call -eq 2) {
            @([pscustomobject]@{
                ProcessId = 301
                ImagePath = 'C:\msys64\ucrt64\bin\gdbus.exe'
                StartTimeUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        else { @() }
        return [pscustomobject]@{
            InspectionComplete = $true
            Processes = $processes
            InspectionErrors = @()
        }
    }
    $outside_rejected = $false
    try {
        Invoke-GApplicationIpcRuntimeTest -FixturePath $fixture -InstallRoot $install `
            -DiagnosticsDirectory (Join-Path $test_root 'outside-helper-diagnostics') `
            -ProcessLauncher $launcher -GdbusSnapshotProvider $outside_snapshots | Out-Null
    }
    catch {
        $outside_rejected = $_.Exception.Message -like `
            'Expected exactly one new installed gdbus helper*found 0.'
    }
    Assert-True $outside_rejected 'A gdbus helper outside the install root produced a false pass.'
    Assert-True $state.Primary.Killed 'Failed IPC verification did not stop its own primary process.'
    Assert-True $state.Primary.Disposed 'Failed IPC verification did not dispose its primary process.'

    $allowed_absence_error = [pscustomobject]@{
        FullyQualifiedErrorId = 'NoProcessFoundForGivenName,Microsoft.PowerShell.Commands.GetProcessCommand'
        Exception = [Exception]::new('No gdbus process exists.')
    }
    $allowed_absence = Get-GdbusProcessSnapshot -ProcessProvider {
        [pscustomobject]@{ Processes = @(); Errors = @($allowed_absence_error) }
    }.GetNewClosure()
    Assert-True $allowed_absence.InspectionComplete `
        'Defined no-process absence was treated as an incomplete snapshot.'

    $unexpected_enumeration_error = [pscustomobject]@{
        FullyQualifiedErrorId = 'FixtureEnumerationFailure'
        Exception = [Exception]::new('fixture enumeration failed')
    }
    $unexpected_enumeration = Get-GdbusProcessSnapshot -ProcessProvider {
        [pscustomobject]@{ Processes = @(); Errors = @($unexpected_enumeration_error) }
    }.GetNewClosure()
    Assert-True (!$unexpected_enumeration.InspectionComplete -and
        $unexpected_enumeration.InspectionErrors.Count -eq 1) `
        'Unexpected process-enumeration failure was reported as complete.'

    $borrowed_process = [pscustomobject]@{
        Id = 401
        Path = $installed_helper
        StartTime = [DateTime]::UtcNow
        Disposed = $false
    }
    $borrowed_process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $borrowed_snapshot = Get-GdbusProcessSnapshot -ProcessProvider {
        [pscustomobject]@{ Processes = @($borrowed_process); Errors = @() }
    }.GetNewClosure()
    Assert-True ($borrowed_snapshot.Processes.Count -eq 1 -and !$borrowed_process.Disposed) `
        'Injected gdbus process object was not treated as borrowed.'

    $missing_state = [pscustomobject]@{ Primary = $null; NullExitForward = $null }
    $missing_exit_launcher = {
        param($Parameters, $Purpose)
        if ($Purpose -eq 'Primary') {
            $ready = ([string]$Parameters.ArgumentList[1]).Trim('"')
            $bus_probe = ([string]$Parameters.ArgumentList[2]).Trim('"')
            Set-Content -LiteralPath $ready -Value 'remote=false' -Encoding utf8
            @('succeeded=true', 'unique_name=:1.2') |
                Set-Content -LiteralPath $bus_probe -Encoding utf8
            $missing_state.Primary = & $new_mock_process -Id 501 -Path $Parameters.FilePath `
                -ExitCode 0 -HasExited $false -Modules @(
                    [pscustomobject]@{ FileName = $installed_gio }
                )
            return $missing_state.Primary
        }
        if ($Purpose -eq 'Forward') {
            $missing_state.NullExitForward = & $new_mock_process -Id 502 -Path $Parameters.FilePath `
                -ExitCode $null -HasExited $true
            return $missing_state.NullExitForward
        }
        throw "Unexpected missing-exit process purpose: $Purpose"
    }.GetNewClosure()
    $missing_snapshot_state = [pscustomobject]@{ Call = 0 }
    $missing_exit_snapshots = {
        $missing_snapshot_state.Call++
        $processes = if ($missing_snapshot_state.Call -eq 2) {
            @([pscustomobject]@{
                ProcessId = 503
                ImagePath = $installed_helper
                StartTimeUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        else { @() }
        [pscustomobject]@{ InspectionComplete = $true; Processes = $processes; InspectionErrors = @() }
    }.GetNewClosure()
    $missing_exit_rejected = $false
    try {
        Invoke-GApplicationIpcRuntimeTest -FixturePath $fixture -InstallRoot $install `
            -DiagnosticsDirectory (Join-Path $test_root 'missing-exit-diagnostics') `
            -ProcessLauncher $missing_exit_launcher -GdbusSnapshotProvider $missing_exit_snapshots | Out-Null
    }
    catch {
        $missing_exit_rejected = $_.Exception.Message -eq `
            'GApplication IPC forwarding process returned no exit code.'
    }
    Assert-True $missing_exit_rejected 'Missing forwarding exit code was accepted.'
    Assert-True $missing_state.NullExitForward.Disposed `
        'Forward process object with a missing exit code was not disposed.'

    $timeout_state = [pscustomobject]@{ Primary = $null; HangingForward = $null }
    $timeout_launcher = {
        param($Parameters, $Purpose)
        if ($Purpose -eq 'Primary') {
            $ready = ([string]$Parameters.ArgumentList[1]).Trim('"')
            $bus_probe = ([string]$Parameters.ArgumentList[2]).Trim('"')
            Set-Content -LiteralPath $ready -Value 'remote=false' -Encoding utf8
            @('succeeded=true', 'unique_name=:1.3') |
                Set-Content -LiteralPath $bus_probe -Encoding utf8
            $timeout_state.Primary = & $new_mock_process -Id 601 -Path $Parameters.FilePath `
                -ExitCode 0 -HasExited $false -Modules @(
                    [pscustomobject]@{ FileName = $installed_gio }
                )
            return $timeout_state.Primary
        }
        if ($Purpose -eq 'Forward') {
            if ($Parameters.ContainsKey('Wait')) {
                throw 'Forward process was launched with an unbounded Start-Process wait.'
            }
            $timeout_state.HangingForward = & $new_mock_process -Id 602 -Path $Parameters.FilePath `
                -ExitCode $null -HasExited $false
            return $timeout_state.HangingForward
        }
        throw "Unexpected timeout process purpose: $Purpose"
    }.GetNewClosure()
    $timeout_snapshot_state = [pscustomobject]@{ Call = 0 }
    $timeout_snapshots = {
        $timeout_snapshot_state.Call++
        $processes = if ($timeout_snapshot_state.Call -eq 2) {
            @([pscustomobject]@{
                ProcessId = 603
                ImagePath = $installed_helper
                StartTimeUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        else { @() }
        [pscustomobject]@{ InspectionComplete = $true; Processes = $processes; InspectionErrors = @() }
    }.GetNewClosure()
    $timeout_rejected = $false
    try {
        Invoke-GApplicationIpcRuntimeTest -FixturePath $fixture -InstallRoot $install `
            -DiagnosticsDirectory (Join-Path $test_root 'timeout-diagnostics') `
            -ProcessLauncher $timeout_launcher -GdbusSnapshotProvider $timeout_snapshots | Out-Null
    }
    catch {
        $timeout_rejected = $_.Exception.Message -eq `
            'GApplication IPC forwarding process did not exit within 30000 ms.'
    }
    Assert-True $timeout_rejected 'A hanging forwarding process was not rejected.'
    Assert-True ($timeout_state.HangingForward.Killed -and $timeout_state.HangingForward.Disposed) `
        'Hanging forwarding process was not stopped and disposed through its owned fixture handle.'
    Assert-True ($timeout_state.Primary.Killed -and $timeout_state.Primary.Disposed) `
        'Primary process was not stopped and disposed after a forwarding timeout.'

    $quiescence_state = [pscustomobject]@{ Call = 0 }
    $quiescence_provider = {
        $quiescence_state.Call++
        $processes = if ($quiescence_state.Call -eq 1) {
            @([pscustomobject]@{ ProcessId = 701; ImagePath = $installed_helper })
        }
        else { @() }
        [pscustomobject]@{ InspectionComplete = $true; Processes = $processes; InspectionErrors = @() }
    }.GetNewClosure()
    $quiescence_path = Join-Path $test_root 'quiescence.json'
    Wait-GdbusQuiescence -DiagnosticPath $quiescence_path `
        -GdbusSnapshotProvider $quiescence_provider -TimeoutMilliseconds 1000 `
        -PollIntervalMilliseconds 1
    Assert-True ($quiescence_state.Call -eq 2) `
        'Natural gdbus quiescence was not observed through an active-to-empty transition.'
    $quiescence_record = Get-Content -LiteralPath $quiescence_path -Raw | ConvertFrom-Json
    Assert-True ($quiescence_record.InspectionComplete -and
        $null -eq $quiescence_record.Processes) `
        "Final gdbus quiescence diagnostics did not record the empty process state: $($quiescence_record | ConvertTo-Json -Compress)"
}
finally {
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + `
        [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or
        !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

Write-Host 'GApplication IPC tests passed.'
exit 0
