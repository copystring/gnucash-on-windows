# InstallerDiagnostics.psm1: Diagnostics for installer preflight processes and cleanup.
# Copyright 2026 GnuCash Development Team
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ProcessResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Executable,
        [AllowNull()][Nullable[int]]$ExitCode,
        [AllowNull()][string]$StartError,
        [AllowNull()][Nullable[int]]$ProcessId = $null
    )

    try {
        $record = [ordered]@{
            Description = $Description
            Executable = $Executable
            ProcessId = $ProcessId
            ExitCode = $ExitCode
            StartError = $StartError
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding utf8
        return $true
    }
    catch {
        Write-Warning "Unable to record the process result for '${Description}': $($_.Exception.Message)"
        return $false
    }
}

function Invoke-CheckedInnoProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$ProcessResultsPath,
        [scriptblock]$ProcessLauncher
    )

    $log = [IO.Path]::GetFullPath($LogPath)
    $results = [IO.Path]::GetFullPath($ProcessResultsPath)
    foreach ($parent in @((Split-Path -Parent $log), (Split-Path -Parent $results)) | Select-Object -Unique) {
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }
    $arguments = @($ArgumentList) + "/LOG=`"$log`""
    $start_parameters = @{
        FilePath = $FilePath
        ArgumentList = $arguments
        NoNewWindow = $true
        PassThru = $true
        Wait = $true
    }

    if (!$ProcessLauncher) {
        $ProcessLauncher = { param($Parameters) Start-Process @Parameters }
    }

    try {
        $process = & $ProcessLauncher $start_parameters
    }
    catch {
        Write-ProcessResult -Path $results -Description $Description -Executable $FilePath `
            -ExitCode $null -StartError $_.Exception.Message | Out-Null
        throw "$Description could not be started: $($_.Exception.Message)"
    }

    if ($null -eq $process -or $null -eq $process.PSObject.Properties['ExitCode'] -or
        $null -eq $process.ExitCode) {
        Write-ProcessResult -Path $results -Description $Description -Executable $FilePath `
            -ExitCode $null -StartError 'Process launcher returned no exit code.' | Out-Null
        throw "$Description did not provide a process exit code."
    }

    $exit_code = [int]$process.ExitCode
    Write-ProcessResult -Path $results -Description $Description -Executable $FilePath `
        -ExitCode $exit_code -StartError $null | Out-Null
    Write-Host "$Description exit code: $exit_code"
    if ($exit_code -ne 0) {
        throw "$Description failed with exit code $exit_code."
    }
    return $exit_code
}

function Invoke-CheckedGnuCashVersion {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$StandardOutputPath,
        [Parameter(Mandatory)][string]$StandardErrorPath,
        [Parameter(Mandatory)][string]$ProcessResultsPath,
        [scriptblock]$ProcessLauncher
    )

    $stdout = [IO.Path]::GetFullPath($StandardOutputPath)
    $stderr = [IO.Path]::GetFullPath($StandardErrorPath)
    $results = [IO.Path]::GetFullPath($ProcessResultsPath)
    foreach ($parent in @(
        (Split-Path -Parent $stdout),
        (Split-Path -Parent $stderr),
        (Split-Path -Parent $results)
    ) | Select-Object -Unique) {
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }
    $start_parameters = @{
        FilePath = $FilePath
        ArgumentList = @('--version')
        WindowStyle = 'Hidden'
        PassThru = $true
        Wait = $true
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
    }
    if (!$ProcessLauncher) {
        $ProcessLauncher = { param($Parameters) Start-Process @Parameters }
    }

    $process = $null
    try {
        try {
            $process = & $ProcessLauncher $start_parameters
        }
        catch {
            Write-ProcessResult -Path $results -Description 'GnuCash --version' -Executable $FilePath `
                -ExitCode $null -StartError $_.Exception.Message | Out-Null
            throw "GnuCash --version could not be started: $($_.Exception.Message)"
        }

        $process_id = if ($process -and $process.PSObject.Properties['Id'] -and
            $null -ne $process.Id) { [int]$process.Id } else { $null }
        if ($null -eq $process -or $null -eq $process.PSObject.Properties['ExitCode'] -or
            $null -eq $process.ExitCode) {
            Write-ProcessResult -Path $results -Description 'GnuCash --version' -Executable $FilePath `
                -ExitCode $null -StartError 'Process launcher returned no exit code.' `
                -ProcessId $process_id | Out-Null
            throw 'GnuCash --version did not provide a process exit code.'
        }

        $exit_code = [int]$process.ExitCode
        Write-ProcessResult -Path $results -Description 'GnuCash --version' -Executable $FilePath `
            -ExitCode $exit_code -StartError $null -ProcessId $process_id | Out-Null
        Write-Host "GnuCash --version process ID: $process_id; exit code: $exit_code"
        $output = @(
            if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout }
            if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr }
        )
        if ($output.Count -ne 0) {
            Write-Host ($output -join [Environment]::NewLine)
        }
        if ($exit_code -ne 0) {
            throw "GnuCash --version failed with exit code ${exit_code}: $($output -join ' ')"
        }
        return [pscustomobject]@{
            ProcessId = $process_id
            ExitCode = $exit_code
            Output = $output
        }
    }
    finally {
        if ($process -and $process.PSObject.Methods['Dispose']) {
            $process.Dispose()
        }
    }
}

function Write-InstallPayloadProcessInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OutputPath,
        [object[]]$Processes,
        [scriptblock]$ProcessEnumerator,
        [scriptblock]$ModuleEnumerator
    )

    $dispose_processes = !$PSBoundParameters.ContainsKey('Processes')
    $processes_to_dispose = @()
    try {
        $resolved_root = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $root_prefix = $resolved_root + [IO.Path]::DirectorySeparatorChar
        $owners = [System.Collections.Generic.List[object]]::new()
        $inspection_errors = [System.Collections.Generic.List[object]]::new()
        if ($dispose_processes) {
            if ($ProcessEnumerator) {
                $Processes = @(& $ProcessEnumerator)
            }
            else {
                $process_enumeration_errors = @()
                $Processes = @(Get-Process -ErrorAction SilentlyContinue `
                    -ErrorVariable process_enumeration_errors)
                foreach ($enumeration_error in @($process_enumeration_errors)) {
                    $inspection_errors.Add([ordered]@{
                        Stage = 'ProcessEnumeration'
                        ProcessId = $null
                        ProcessName = $null
                        Error = $enumeration_error.Exception.Message
                    })
                }
            }
            $processes_to_dispose = @($Processes)
        }
        foreach ($process in @($Processes)) {
            try {
                if ($ModuleEnumerator) {
                    $modules = & $ModuleEnumerator $process
                }
                elseif ($process -is [System.Diagnostics.Process]) {
                    $modules = $process.get_Modules()
                }
                else {
                    $modules = $process.Modules
                }
                if ($null -eq $modules) {
                    continue
                }
                $process_id = $process.Id
                $process_name = $process.ProcessName
                foreach ($module in @($modules)) {
                    if ($null -eq $module) {
                        continue
                    }
                    $file_name = $module.PSObject.Properties['FileName']
                    if ($null -eq $file_name) {
                        throw [InvalidOperationException]::new(
                            'Module record does not expose a FileName property.')
                    }
                    $module_path = [string]$file_name.Value
                    if ([string]::IsNullOrWhiteSpace($module_path)) {
                        continue
                    }
                    $full_module_path = [IO.Path]::GetFullPath($module_path)
                    if ($full_module_path.StartsWith($root_prefix, [StringComparison]::OrdinalIgnoreCase)) {
                        $owners.Add([ordered]@{
                            ProcessId = $process_id
                            ProcessName = $process_name
                            ModulePath = $full_module_path
                        })
                    }
                }
            }
            catch {
                $inspection_error = $_
                $failed_process_id = $null
                $failed_process_name = $null
                try { $failed_process_id = $process.Id } catch {}
                try { $failed_process_name = $process.ProcessName } catch {}
                $inspection_errors.Add([ordered]@{
                    Stage = 'ModuleEnumeration'
                    ProcessId = $failed_process_id
                    ProcessName = $failed_process_name
                    Error = $inspection_error.Exception.Message
                })
            }
        }

        $record = [ordered]@{
            Root = $resolved_root
            InspectionComplete = $inspection_errors.Count -eq 0
            Owners = @($owners)
            InspectionErrors = @($inspection_errors)
        }
        $output = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $output
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText(
            $output,
            (ConvertTo-Json -InputObject $record -Depth 5),
            [Text.UTF8Encoding]::new($false))
        Write-Host "Install-payload process owners: $($owners.Count); inspection errors: $($inspection_errors.Count); full JSON: $output"
        foreach ($owner in $owners) {
            Write-Host "  PID $($owner.ProcessId) $($owner.ProcessName): $($owner.ModulePath)"
        }
        return [pscustomobject]@{
            Succeeded = $true
            OwnerCount = $owners.Count
            InspectionErrorCount = $inspection_errors.Count
        }
    }
    catch {
        Write-Warning "Unable to record install-payload process owners for ${Root}: $($_.Exception.Message)"
        return [pscustomobject]@{
            Succeeded = $false
            OwnerCount = $null
            InspectionErrorCount = $null
        }
    }
    finally {
        if ($dispose_processes) {
            foreach ($process in $processes_to_dispose) {
                try {
                    if ($process -and $process.PSObject.Methods['Dispose']) {
                        $process.Dispose()
                    }
                }
                catch {
                    Write-Warning "Unable to dispose inspected process object: $($_.Exception.Message)"
                }
            }
        }
    }
}

function Write-RemainingInstallInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OutputPath
    )

    try {
        $resolved_root = [IO.Path]::GetFullPath($Root)
        $root_item = Get-Item -LiteralPath $resolved_root -Force -ErrorAction Stop
        $children = @(Get-ChildItem -LiteralPath $resolved_root -Force -Recurse -ErrorAction Stop |
            Sort-Object FullName)
        $records = [System.Collections.Generic.List[object]]::new()
        $records.Add([pscustomobject]@{
            RelativePath = '.'
            Type = if (($root_item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                'ReparsePoint'
            }
            elseif ($root_item.PSIsContainer) {
                'Directory'
            }
            else {
                'File'
            }
            SizeBytes = $null
            Attributes = [string]$root_item.Attributes
        })

        foreach ($item in $children) {
            $is_reparse_point = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            $type = if ($is_reparse_point) {
                'ReparsePoint'
            }
            elseif ($item.PSIsContainer) {
                'Directory'
            }
            else {
                'File'
            }
            $size = if ($item.PSIsContainer) { $null } else { [long]$item.Length }
            $records.Add([pscustomobject]@{
                RelativePath = [IO.Path]::GetRelativePath($resolved_root, $item.FullName)
                Type = $type
                SizeBytes = $size
                Attributes = [string]$item.Attributes
            })
        }

        $output = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $output
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $records | Export-Csv -LiteralPath $output -NoTypeInformation -Encoding utf8

        Write-Host "Remaining installation root state: Empty=$($children.Count -eq 0); ChildItems=$($children.Count)"
        Write-Host "Remaining installation inventory: $($records.Count) item(s), including root; full CSV: $output"
        $console_limit = 200
        foreach ($record in $records | Select-Object -First $console_limit) {
            $size_text = if ($null -eq $record.SizeBytes) { '-' } else { [string]$record.SizeBytes }
            Write-Host "  $($record.Type)`t$size_text`t$($record.Attributes)`t$($record.RelativePath)"
        }
        if ($records.Count -gt $console_limit) {
            Write-Host "  ... $($records.Count - $console_limit) additional item(s) are recorded in the CSV."
        }
        return [pscustomobject]@{
            Succeeded = $true
            RootEmpty = $children.Count -eq 0
            ChildItemCount = $children.Count
        }
    }
    catch {
        Write-Warning "Unable to record the remaining installation inventory for ${Root}: $($_.Exception.Message)"
        return [pscustomobject]@{
            Succeeded = $false
            RootEmpty = $null
            ChildItemCount = $null
        }
    }
}

function Write-ProductRegistrationDiagnostics {
    param(
        [AllowEmptyCollection()][object[]]$Registrations = @(),
        [Parameter(Mandatory)][string]$OutputPath
    )

    try {
        $output = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $output
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $records = @($Registrations | ForEach-Object {
            [ordered]@{
                Hive = [string]$_.Hive
                View = [string]$_.View
                ProductKey = [string]$_.ProductKey
                DisplayName = [string]$_.DisplayName
                InstallLocation = [string]$_.InstallLocation
                UninstallString = [string]$_.UninstallString
            }
        })
        $json = if ($records.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $records -Depth 3 }
        [IO.File]::WriteAllText($output, $json, [Text.UTF8Encoding]::new($false))
        Write-Host "Post-uninstall product registration count: $($records.Count); full JSON: $output"
        foreach ($record in $records) {
            Write-Host "  $($record.Hive)/$($record.View): $($record.InstallLocation)"
        }
        return $true
    }
    catch {
        Write-Warning "Unable to record post-uninstall product registrations: $($_.Exception.Message)"
        return $false
    }
}

function Write-InstallPathObservation {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$OutputPath
    )

    try {
        $output = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $output
        if (!(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $exists = Test-Path -LiteralPath $Root
        $record = [ordered]@{
            Label = $Label
            Root = [IO.Path]::GetFullPath($Root)
            Exists = $exists
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $output -Encoding utf8
        Write-Host "Installation root observation '$Label': Exists=$exists; Root=$Root"
        return $exists
    }
    catch {
        Write-Warning "Unable to record installation root observation '${Label}': $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function @(
    'Invoke-CheckedInnoProcess',
    'Invoke-CheckedGnuCashVersion',
    'Write-InstallPayloadProcessInventory',
    'Write-RemainingInstallInventory',
    'Write-ProductRegistrationDiagnostics',
    'Write-InstallPathObservation'
)
