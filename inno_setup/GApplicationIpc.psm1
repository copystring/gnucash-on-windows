# GApplicationIpc.psm1: Installed-runtime GApplication IPC verification.
# Copyright 2026 GnuCash Development Team
# SPDX-License-Identifier: GPL-2.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcessEnvironmentVariableState {
    param([Parameter(Mandatory)][string]$Name)

    $item = Get-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Exists = $null -ne $item
        Value = if ($null -eq $item) { $null } else { $item.Value }
    }
}

function Remove-ProcessEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)

    Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath "Env:$Name") {
        throw "Unable to remove process environment variable $Name."
    }
}

function Restore-ProcessEnvironmentVariableState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$State
    )

    if ($State.Exists) {
        Set-Item -LiteralPath "Env:$Name" -Value $State.Value
    }
    else {
        Remove-ProcessEnvironmentVariable -Name $Name
    }
}

function Write-IpcDiagnosticJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    try {
        $output = [IO.Path]::GetFullPath($Path)
        $parent = Split-Path -Parent $output
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText(
            $output,
            (ConvertTo-Json -InputObject $Value -Depth 6),
            [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-Warning "Unable to write GApplication IPC diagnostics to ${Path}: $($_.Exception.Message)"
    }
}

function Get-GdbusProcessSnapshot {
    param([scriptblock]$ProcessProvider)

    $records = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $processes = @()
    $dispose_processes = !$ProcessProvider
    try {
        if ($ProcessProvider) {
            $provided = & $ProcessProvider
            $processes = @($provided.Processes)
            $enumeration_errors = @($provided.Errors)
        }
        else {
            $enumeration_errors = @()
            $processes = @(Get-Process -Name 'gdbus' -ErrorAction SilentlyContinue `
                -ErrorVariable enumeration_errors)
        }
        foreach ($enumeration_error in $enumeration_errors) {
            if ($enumeration_error.FullyQualifiedErrorId -like 'NoProcessFoundForGivenName,*') {
                continue
            }
            $errors.Add([ordered]@{
                ProcessId = $null
                Error = $enumeration_error.Exception.Message
            })
        }
        foreach ($process in $processes) {
            try {
                $records.Add([ordered]@{
                    ProcessId = [int]$process.Id
                    ImagePath = [IO.Path]::GetFullPath([string]$process.Path)
                    StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
                })
            }
            catch {
                $inspection_error = $_
                $failed_process_id = $null
                try { $failed_process_id = [int]$process.Id } catch {}
                $errors.Add([ordered]@{
                    ProcessId = $failed_process_id
                    Error = $inspection_error.Exception.Message
                })
            }
        }
    }
    finally {
        if ($dispose_processes) {
            foreach ($process in $processes) {
                try { $process.Dispose() } catch {
                    Write-Warning "Unable to dispose gdbus process object: $($_.Exception.Message)"
                }
            }
        }
    }

    return [pscustomobject]@{
        InspectionComplete = $errors.Count -eq 0
        Processes = @($records)
        InspectionErrors = @($errors)
    }
}

function Read-IpcRecord {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            throw "Invalid GApplication IPC record line: $line"
        }
        $key = $line.Substring(0, $separator)
        if ($values.ContainsKey($key)) {
            throw "Duplicate GApplication IPC record key: $key"
        }
        $values[$key] = $line.Substring($separator + 1)
    }
    return $values
}

function Wait-IpcFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$PrimaryProcess,
        [int]$TimeoutMilliseconds = 30000
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath $Path)) {
        if ($PrimaryProcess.HasExited) {
            throw "GApplication IPC primary process exited before creating $Path (exit code $($PrimaryProcess.ExitCode))."
        }
        if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw "Timed out waiting for GApplication IPC record: $Path"
        }
        Start-Sleep -Milliseconds 100
    }
}

function Wait-GdbusQuiescence {
    param(
        [Parameter(Mandatory)][string]$DiagnosticPath,
        [scriptblock]$GdbusSnapshotProvider,
        [int]$TimeoutMilliseconds = 30000,
        [int]$PollIntervalMilliseconds = 250
    )

    if (!$GdbusSnapshotProvider) {
        $GdbusSnapshotProvider = { Get-GdbusProcessSnapshot }
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $snapshot = & $GdbusSnapshotProvider
        if (!$snapshot.InspectionComplete) {
            Write-IpcDiagnosticJson -Path $DiagnosticPath -Value $snapshot
            throw 'Unable to inspect gdbus while waiting for natural idle exit.'
        }
        if (@($snapshot.Processes).Count -eq 0) {
            Write-IpcDiagnosticJson -Path $DiagnosticPath -Value $snapshot
            return
        }
        if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            Write-IpcDiagnosticJson -Path $DiagnosticPath -Value $snapshot
            $remaining = @($snapshot.Processes | ForEach-Object ProcessId) -join ', '
            throw "Timed out waiting for natural gdbus idle exit; remaining PID(s): $remaining"
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ($true)
}

function Wait-IpcFixtureProcess {
    param(
        [Parameter(Mandatory)][object]$Process,
        [Parameter(Mandatory)][string]$Purpose,
        [int]$TimeoutMilliseconds = 30000
    )

    if ($null -eq $Process.PSObject.Properties['Id']) {
        throw "GApplication IPC $Purpose launcher returned no process."
    }
    if (!$Process.WaitForExit($TimeoutMilliseconds)) {
        throw "GApplication IPC $Purpose process did not exit within $TimeoutMilliseconds ms."
    }
    if ($null -eq $Process.PSObject.Properties['ExitCode'] -or $null -eq $Process.ExitCode) {
        throw "GApplication IPC $Purpose process returned no exit code."
    }
    return [int]$Process.ExitCode
}

function Invoke-GApplicationIpcRuntimeTest {
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$DiagnosticsDirectory,
        [scriptblock]$ProcessLauncher,
        [scriptblock]$GdbusSnapshotProvider
    )

    $fixture = (Resolve-Path -LiteralPath $FixturePath).Path
    $install = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $diagnostics_root = [IO.Path]::GetFullPath($DiagnosticsDirectory)
    $diagnostics = Join-Path $diagnostics_root ('gapplication-ipc-' + [guid]::NewGuid())
    $expected_helper = [IO.Path]::GetFullPath((Join-Path $install 'bin\gdbus.exe'))
    $expected_gio = [IO.Path]::GetFullPath((Join-Path $install 'bin\libgio-2.0-0.dll'))
    if (!(Test-Path -LiteralPath $expected_helper -PathType Leaf)) {
        throw "Installed GLib session-bus helper is missing: $expected_helper"
    }
    New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null

    if (!$ProcessLauncher) {
        $ProcessLauncher = { param($Parameters, $Purpose) Start-Process @Parameters }
    }
    if (!$GdbusSnapshotProvider) {
        $GdbusSnapshotProvider = { Get-GdbusProcessSnapshot }
    }
    $ready_path = Join-Path $diagnostics 'gapplication-ipc-primary.txt'
    $bus_probe_path = Join-Path $diagnostics 'gapplication-ipc-session-bus.txt'
    $forward_path = Join-Path $diagnostics 'gapplication-ipc-forward.txt'
    $primary_cwd = Join-Path $diagnostics 'gapplication-ipc-primary-cwd'
    $client_cwd = Join-Path $diagnostics 'gapplication-ipc-client-cwd'
    $relative_file = 'relative-input.gnucash'
    New-Item -ItemType Directory -Path $primary_cwd -Force | Out-Null
    New-Item -ItemType Directory -Path $client_cwd -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $client_cwd $relative_file) -Value 'fixture' -Encoding utf8

    $primary = $null
    $child_processes = [System.Collections.Generic.List[object]]::new()
    $owned_helpers = @()
    $result = [ordered]@{
        Succeeded = $false
        DiagnosticsDirectory = $diagnostics
        PrimaryProcessId = $null
        ForwardProcessId = $null
        RejectedProcessId = $null
        QuitProcessId = $null
        GdbusProcesses = @()
        Error = $null
    }
    try {
        $before = & $GdbusSnapshotProvider
        Write-IpcDiagnosticJson -Path (Join-Path $diagnostics 'gapplication-ipc-gdbus-before.json') -Value $before
        if (!$before.InspectionComplete) {
            throw 'Unable to establish the pre-test gdbus process state completely.'
        }
        $before_ids = @($before.Processes | ForEach-Object { [int]$_.ProcessId })

        $primary = & $ProcessLauncher @{
            FilePath = $fixture
            ArgumentList = @('--primary', "`"$ready_path`"", "`"$bus_probe_path`"")
            WorkingDirectory = $primary_cwd
            WindowStyle = 'Hidden'
            PassThru = $true
            Environment = @{ G_DBUS_DEBUG = 'address' }
            RedirectStandardOutput = (Join-Path $diagnostics 'gapplication-ipc-primary.stdout.log')
            RedirectStandardError = (Join-Path $diagnostics 'gapplication-ipc-primary.stderr.log')
        } 'Primary'
        if (!$primary -or $null -eq $primary.PSObject.Properties['Id']) {
            throw 'GApplication IPC primary launcher returned no process.'
        }
        $result.PrimaryProcessId = [int]$primary.Id
        try {
            $startup_modules = @($primary.Modules | ForEach-Object {
                [IO.Path]::GetFullPath([string]$_.FileName)
            })
            Write-IpcDiagnosticJson -Path `
                (Join-Path $diagnostics 'gapplication-ipc-primary-modules-startup.json') `
                -Value $startup_modules
        }
        catch {
            Write-IpcDiagnosticJson -Path `
                (Join-Path $diagnostics 'gapplication-ipc-primary-modules-startup-error.json') `
                -Value ([ordered]@{ Error = $_.Exception.Message })
        }
        Wait-IpcFile -Path $ready_path -PrimaryProcess $primary
        if (!(Test-Path -LiteralPath $bus_probe_path)) {
            throw 'GApplication IPC primary process did not write its session-bus probe.'
        }
        $bus_probe = Read-IpcRecord -Path $bus_probe_path
        if ($bus_probe.succeeded -cne 'true' -or
            [string]::IsNullOrWhiteSpace([string]$bus_probe.unique_name)) {
            throw 'GApplication IPC primary process did not establish a named session-bus connection.'
        }
        $primary_record = Read-IpcRecord -Path $ready_path
        if ($primary_record.remote -cne 'false') {
            throw 'GApplication IPC primary invocation was not local.'
        }
        try {
            $primary_modules = @($primary.Modules | ForEach-Object {
                [IO.Path]::GetFullPath([string]$_.FileName)
            })
        }
        catch {
            throw "Unable to inspect the GApplication IPC primary modules: $($_.Exception.Message)"
        }
        Write-IpcDiagnosticJson -Path (Join-Path $diagnostics 'gapplication-ipc-primary-modules.json') `
            -Value $primary_modules
        if (!($primary_modules | Where-Object {
            [string]::Equals($_, $expected_gio, [StringComparison]::OrdinalIgnoreCase)
        })) {
            throw "GApplication IPC primary process did not load the installed GIO DLL: $expected_gio"
        }

        $active = & $GdbusSnapshotProvider
        Write-IpcDiagnosticJson -Path (Join-Path $diagnostics 'gapplication-ipc-gdbus-active.json') -Value $active
        if (!$active.InspectionComplete) {
            throw 'Unable to inspect the active gdbus process state completely.'
        }
        $owned_helpers = @($active.Processes | Where-Object {
            $_.ProcessId -notin $before_ids -and
            [string]::Equals([IO.Path]::GetFullPath([string]$_.ImagePath), $expected_helper,
                [StringComparison]::OrdinalIgnoreCase)
        })
        if ($owned_helpers.Count -ne 1) {
            throw "Expected exactly one new installed gdbus helper at $expected_helper; found $($owned_helpers.Count)."
        }
        $result.GdbusProcesses = @($owned_helpers)

        $forward = & $ProcessLauncher @{
            FilePath = $fixture
            ArgumentList = @('--forward', $relative_file, "`"$forward_path`"")
            WorkingDirectory = $client_cwd
            WindowStyle = 'Hidden'
            PassThru = $true
            RedirectStandardOutput = (Join-Path $diagnostics 'gapplication-ipc-forward.stdout.log')
            RedirectStandardError = (Join-Path $diagnostics 'gapplication-ipc-forward.stderr.log')
        } 'Forward'
        $child_processes.Add($forward)
        $forward_exit_code = Wait-IpcFixtureProcess -Process $forward -Purpose 'forwarding'
        $result.ForwardProcessId = [int]$forward.Id
        if ($forward_exit_code -ne 0) {
            throw "GApplication IPC forwarding process failed with exit code $forward_exit_code."
        }
        if (!(Test-Path -LiteralPath $forward_path)) {
            throw 'GApplication IPC primary process did not write the forwarding record.'
        }
        $forward_record = Read-IpcRecord -Path $forward_path
        if ($forward_record.remote -cne 'true') {
            throw 'GApplication IPC forwarding invocation was not delivered to the primary process.'
        }
        if ($forward_record.argument -cne $relative_file) {
            throw "GApplication IPC changed the forwarded relative argument: $($forward_record.argument)"
        }
        $expected_cwd = [IO.Path]::GetFullPath($client_cwd).TrimEnd('\', '/')
        $actual_cwd = [IO.Path]::GetFullPath([string]$forward_record.cwd).TrimEnd('\', '/')
        if (![string]::Equals($actual_cwd, $expected_cwd, [StringComparison]::OrdinalIgnoreCase)) {
            throw "GApplication IPC did not preserve the client working directory: $actual_cwd"
        }
        $forwarded_uri = [Uri]$forward_record.uri
        $expected_file = [IO.Path]::GetFullPath((Join-Path $client_cwd $relative_file))
        $actual_file = [IO.Path]::GetFullPath($forwarded_uri.LocalPath)
        if (!$forwarded_uri.IsAbsoluteUri -or !$forwarded_uri.IsFile -or
            ![string]::Equals($actual_file, $expected_file, [StringComparison]::OrdinalIgnoreCase)) {
            throw "GApplication IPC did not resolve the relative file against the client CWD: $($forward_record.uri)"
        }

        $reject_stderr = Join-Path $diagnostics 'gapplication-ipc-reject.stderr.log'
        $rejected = & $ProcessLauncher @{
            FilePath = $fixture
            ArgumentList = @('--reject')
            WorkingDirectory = $client_cwd
            WindowStyle = 'Hidden'
            PassThru = $true
            RedirectStandardOutput = (Join-Path $diagnostics 'gapplication-ipc-reject.stdout.log')
            RedirectStandardError = $reject_stderr
        } 'Reject'
        $child_processes.Add($rejected)
        $rejected_exit_code = Wait-IpcFixtureProcess -Process $rejected -Purpose 'rejected'
        $result.RejectedProcessId = [int]$rejected.Id
        $reject_output = if (Test-Path -LiteralPath $reject_stderr) {
            Get-Content -LiteralPath $reject_stderr -Raw
        } else { '' }
        if ($rejected_exit_code -ne 23 -or
            $reject_output -notlike '*Intentional remote fixture rejection.*') {
            throw "GApplication IPC did not preserve the remote rejection status and stderr: exit $rejected_exit_code."
        }

        $quit = & $ProcessLauncher @{
            FilePath = $fixture
            ArgumentList = @('--quit')
            WorkingDirectory = $client_cwd
            WindowStyle = 'Hidden'
            PassThru = $true
            RedirectStandardOutput = (Join-Path $diagnostics 'gapplication-ipc-quit.stdout.log')
            RedirectStandardError = (Join-Path $diagnostics 'gapplication-ipc-quit.stderr.log')
        } 'Quit'
        $child_processes.Add($quit)
        $quit_exit_code = Wait-IpcFixtureProcess -Process $quit -Purpose 'quit'
        $result.QuitProcessId = [int]$quit.Id
        if ($quit_exit_code -ne 0) {
            throw "GApplication IPC quit process failed with exit code $quit_exit_code."
        }
        if (!$primary.WaitForExit(30000)) {
            throw 'GApplication IPC primary process did not exit after the remote quit request.'
        }
        if ([int]$primary.ExitCode -ne 0) {
            throw "GApplication IPC primary process failed with exit code $($primary.ExitCode)."
        }

        $helper_deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $after = & $GdbusSnapshotProvider
            if (!$after.InspectionComplete) {
                throw 'Unable to inspect gdbus while waiting for its natural idle exit.'
            }
            $remaining_helpers = @($after.Processes | Where-Object {
                $_.ProcessId -in @($owned_helpers | ForEach-Object ProcessId)
            })
            if ($remaining_helpers.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $helper_deadline)
        Write-IpcDiagnosticJson -Path (Join-Path $diagnostics 'gapplication-ipc-gdbus-after.json') -Value $after
        if ($remaining_helpers.Count -ne 0) {
            throw 'The test-owned gdbus helper did not exit naturally after all clients disconnected.'
        }

        $result.Succeeded = $true
        Write-Host "Installed GApplication IPC contract passed: primary PID $($primary.Id), helper PID $($owned_helpers[0].ProcessId), client CWD and file URI forwarded."
        return [pscustomobject]$result
    }
    catch {
        $failure = $_
        $result.Error = $failure.Exception.Message
        try {
            $failure_snapshot = & $GdbusSnapshotProvider
            Write-IpcDiagnosticJson -Path `
                (Join-Path $diagnostics 'gapplication-ipc-gdbus-failure.json') `
                -Value $failure_snapshot
        }
        catch {
            Write-IpcDiagnosticJson -Path `
                (Join-Path $diagnostics 'gapplication-ipc-gdbus-failure-error.json') `
                -Value ([ordered]@{ Error = $_.Exception.Message })
        }
        throw $failure
    }
    finally {
        if (!$result.Succeeded) {
            foreach ($process in @($child_processes) + @($primary)) {
                try {
                    if ($process -and !$process.HasExited) {
                        $process_path = [IO.Path]::GetFullPath([string]$process.Path)
                        if ([string]::Equals($process_path, $fixture, [StringComparison]::OrdinalIgnoreCase)) {
                            $process.Kill()
                            [void]$process.WaitForExit(5000)
                        }
                        else {
                            Write-Warning "Refusing to stop fixture PID $($process.Id): executable path no longer matches the test fixture."
                        }
                    }
                }
                catch {
                    Write-Warning "Unable to stop a test-owned fixture process: $($_.Exception.Message)"
                }
            }
        }
        foreach ($process in @($child_processes) + @($primary)) {
            try {
                if ($process -and $process.PSObject.Methods['Dispose']) { $process.Dispose() }
            }
            catch {
                Write-Warning "Unable to dispose GApplication IPC process object: $($_.Exception.Message)"
            }
        }
        Write-IpcDiagnosticJson -Path (Join-Path $diagnostics 'gapplication-ipc-result.json') -Value $result
    }
}

Export-ModuleMember -Function @(
    'Get-GdbusProcessSnapshot',
    'Get-ProcessEnvironmentVariableState',
    'Invoke-GApplicationIpcRuntimeTest',
    'Remove-ProcessEnvironmentVariable',
    'Restore-ProcessEnvironmentVariableState',
    'Wait-GdbusQuiescence'
)
