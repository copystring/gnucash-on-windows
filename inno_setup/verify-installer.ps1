# verify-installer.ps1: Install and test a GnuCash Windows installer.
# Copyright 2026 GnuCash Development Team
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,
    [Parameter(Mandatory)]
    [string]$GApplicationFixturePath,
    [string]$InstallPath,
    [string]$GSettingsPath,
    [string]$DiagnosticsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'GSettingsSchemas.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Gtk3Payload.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'InstallerArchitecture.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'InstallerDiagnostics.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GApplicationIpc.psm1') -Force

if ([string]::IsNullOrWhiteSpace($GSettingsPath)) {
    $gsettings_command = Get-Command 'gsettings.exe' -ErrorAction SilentlyContinue
    if (!$gsettings_command) {
        throw 'gsettings.exe was not found on PATH; provide -GSettingsPath for compiled schema verification.'
    }
    $GSettingsPath = $gsettings_command.Source
}

function Assert-ElevatedSession {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Installer preflight must be run from an elevated PowerShell session because the installer writes machine-wide registry keys.'
    }
}

function Assert-AnyFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter,
        [string]$ExpectedPath = $Path,
        [switch]$Recurse
    )

    $search = @{
        Path = $Path
        File = $true
        Recurse = $Recurse
        ErrorAction = 'SilentlyContinue'
    }
    if ($PSBoundParameters.ContainsKey('Filter')) {
        $search.Filter = $Filter
    }

    if (!(Get-ChildItem @search | Select-Object -First 1)) {
        throw "Expected installer payload is missing: $ExpectedPath"
    }
}

function Assert-NativeWindowsDecorations {
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$EnvironmentFile
    )

    $gtk_csd_lines = @([regex]::Matches($Environment, '(?m)^GTK_CSD=[^\r\n]*') |
        ForEach-Object Value)
    if ($gtk_csd_lines.Count -ne 1 -or $gtk_csd_lines[0] -cne 'GTK_CSD=0') {
        throw "Expected exactly one GTK_CSD=0 entry in ${EnvironmentFile}; found: $($gtk_csd_lines -join ', ')"
    }
}

function Get-Dumpbin {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere)) {
        throw "Visual Studio discovery tool not found: $vswhere"
    }
    $vs_install = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vs_install)) {
        throw 'Unable to locate the Visual Studio C++ tools required for PE import verification.'
    }
    $dumpbin = Get-ChildItem -Path $vs_install.Trim() -Filter dumpbin.exe -File -Recurse | Select-Object -First 1
    if (!$dumpbin) {
        throw 'dumpbin.exe was not found in the installed Visual Studio C++ tools.'
    }
    return $dumpbin.FullName
}

function Get-SystemImports {
    $system_imports = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $system_directories = @(
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'SysWOW64')
    ) | Select-Object -Unique
    foreach ($directory in $system_directories) {
        if (!(Test-Path -LiteralPath $directory)) {
            continue
        }
        foreach ($dll in Get-ChildItem -LiteralPath $directory -File -Filter '*.dll') {
            [void]$system_imports.Add($dll.Name)
        }
    }
    if ($system_imports.Count -eq 0) {
        throw 'Unable to derive the Windows system DLL allowlist.'
    }
    return ,$system_imports
}

function Test-SystemImport {
    param(
        [Parameter(Mandatory)][string]$Import,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$SystemImports
    )

    return $SystemImports.Contains($Import) -or
        $Import -like 'api-ms-win-*.dll' -or
        $Import -like 'ext-ms-win-*.dll'
}

function Test-PeImportClosure {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Dumpbin,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$SystemImports
    )

    $binaries = Get-ChildItem -Path $Root -File -Recurse | Where-Object { $_.Extension -in '.exe', '.dll' }
    if (!$binaries) {
        throw "No PE files found under $Root."
    }
    $payload = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($binary in $binaries) {
        [void]$payload.Add($binary.Name)
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($binary in $binaries) {
        $dependencies = & $Dumpbin /DEPENDENTS $binary.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "dumpbin failed for $($binary.FullName) with exit code $LASTEXITCODE."
        }
        foreach ($line in $dependencies) {
            $match = [regex]::Match($line, '^\s*([^\s]+\.dll)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (!$match.Success) {
                continue
            }
            $import = $match.Groups[1].Value.ToLowerInvariant()
            if (!$payload.Contains($import) -and !(Test-SystemImport -Import $import -SystemImports $SystemImports)) {
                $missing.Add("$($binary.FullName): $import")
            }
        }
    }
    if ($missing.Count -ne 0) {
        throw "PE import closure is incomplete:`n$($missing -join "`n")"
    }
}

Assert-ElevatedSession
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$diagnostics = if ([string]::IsNullOrWhiteSpace($DiagnosticsDirectory)) {
    Join-Path ([IO.Path]::GetTempPath()) "gnucash-installer-preflight-$PID"
}
else {
    [IO.Path]::GetFullPath($DiagnosticsDirectory)
}
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
$installer_log = Join-Path $diagnostics 'installer.log'
$uninstaller_log = Join-Path $diagnostics 'uninstaller.log'
$process_results_log = Join-Path $diagnostics 'process-results.jsonl'
$path_observations_log = Join-Path $diagnostics 'cleanup-path-observations.jsonl'
$version_stdout_log = Join-Path $diagnostics 'gnucash-version.stdout.log'
$version_stderr_log = Join-Path $diagnostics 'gnucash-version.stderr.log'
$product_key = 'GnuCash_is1'
Assert-InnoProductNotRegistered -ProductKey $product_key
$using_default_path = [string]::IsNullOrWhiteSpace($InstallPath)
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = Join-Path (Get-ProgramFiles64) 'gnucash'
}
$install = [System.IO.Path]::GetFullPath($InstallPath)
if (Test-Path -LiteralPath $install) {
    throw "Installer test destination already exists: $install"
}

$installer_succeeded = $false
$primary_failure = $null
try {
    $installer_arguments = @(
        '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        '/COMPONENTS=main,translations,templates'
    )
    if (!$using_default_path) {
        $installer_arguments += "/DIR=`"$install`""
    }
    $installer_exit_code = Invoke-CheckedInnoProcess -FilePath $installer -Description 'Silent installer' `
        -ArgumentList $installer_arguments -LogPath $installer_log -ProcessResultsPath $process_results_log
    $installer_succeeded = $true

    Assert-InnoProductRegistration -ProductKey $product_key -ExpectedInstallLocation $install
    Assert-GnuCashRegistryView -ExpectedInstallLocation $install
    Write-Host "Installer path contract passed: $install"
    Write-Host 'Installer registry contract passed: HKLM Registry64 only (no HKLM Registry32 product key)'

    foreach ($required in @(
        "$install\bin\gnucash.exe",
        "$install\bin\gdbus.exe",
        "$install\bin\libgtk-4-1.dll",
        "$install\share\glib-2.0\schemas\gschemas.compiled",
        "$install\share\glib-2.0\schemas\org.gtk.gtk4.Settings.*.gschema.xml"
    )) {
        Assert-AnyFile -Path $required
    }
    Assert-GSettingsSchemaCache `
        -Directory "$install\share\glib-2.0\schemas" `
        -GSettingsPath $GSettingsPath
    foreach ($required in @(
        "$install\bin\libaqbanking-*.dll",
        "$install\bin\libgwenhywfar-*.dll",
        "$install\bin\libgwengui-gtk4-*.dll",
        "$install\lib\aqbanking\*.dll",
        "$install\lib\dbd\*.dll",
        "$install\lib\gwenhywfar\*.dll",
        "$install\lib\gdk-pixbuf-2.0\2.10.0\loaders\*.dll",
        "$install\share\aqbanking\*",
        "$install\share\gwenhywfar\*",
        "$install\share\gtk-4.0\*"
    )) {
        Assert-AnyFile -Path $required -Recurse
    }
    $locale_root = "$install\share\locale"
    foreach ($catalog in @('aqbanking.mo', 'gwenhywfar.mo', 'gtk40.mo', 'iso_4217.mo')) {
        Assert-AnyFile -Path $locale_root -Filter $catalog -Recurse `
            -ExpectedPath "$locale_root\*\LC_MESSAGES\$catalog"
    }
    Assert-NoGtk3Payload -Root $install

    $environment_file = Join-Path $install 'etc\gnucash\environment'
    $environment = Get-Content -LiteralPath $environment_file -Raw
    if ($environment -notmatch '(?m)^GUILE_LOAD_PATH=.*share/guile/3\.0') {
        throw "Installed environment does not set GUILE_LOAD_PATH to the Guile 3.0 payload: $environment_file"
    }
    if ($environment -match 'share/guile/2\.2') {
        throw "Installed environment still refers to Guile 2.2: $environment_file"
    }
    if ($environment -match '(?i)(?:[a-z]:)?[\\/]+msys(?:2|64)[\\/]') {
        throw "Installed environment still contains an MSYS2 path: $environment_file"
    }
    Assert-NativeWindowsDecorations -Environment $environment -EnvironmentFile $environment_file

    # The Inno Setup bootstrapper and uninstaller may legally remain x86. The
    # shipped GnuCash application/runtime contract under bin and lib is AMD64.
    $pe_summary = Assert-Amd64ApplicationPayload -Root $install
    Write-Host "AMD64 application/runtime contract passed: $($pe_summary.FilesChecked) PE files; main $($pe_summary.MainExecutable)"
    Test-PeImportClosure -Root $install -Dumpbin (Get-Dumpbin) -SystemImports (Get-SystemImports)

    $old_path = $env:PATH
    $old_guile_load_path = $env:GUILE_LOAD_PATH
    $old_guile_load_compiled_path = $env:GUILE_LOAD_COMPILED_PATH
    $old_scheme_library_path = $env:SCHEME_LIBRARY_PATH
    $old_dbus_session_bus_address = [Environment]::GetEnvironmentVariable(
        'DBUS_SESSION_BUS_ADDRESS', 'Process')
    $old_xdg_runtime_dir = [Environment]::GetEnvironmentVariable('XDG_RUNTIME_DIR', 'Process')
    try {
        $env:PATH = "$install\bin;$env:SystemRoot\System32;$env:SystemRoot"
        $env:GUILE_LOAD_PATH = ''
        $env:GUILE_LOAD_COMPILED_PATH = ''
        $env:SCHEME_LIBRARY_PATH = ''
        [Environment]::SetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS', $null, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_RUNTIME_DIR', $null, 'Process')
        Invoke-GApplicationIpcRuntimeTest -FixturePath $GApplicationFixturePath `
            -InstallRoot $install -DiagnosticsDirectory $diagnostics | Out-Null
        $version = Invoke-CheckedGnuCashVersion -FilePath "$install\bin\gnucash.exe" `
            -StandardOutputPath $version_stdout_log -StandardErrorPath $version_stderr_log `
            -ProcessResultsPath $process_results_log
        Wait-GdbusQuiescence `
            -DiagnosticPath (Join-Path $diagnostics 'gdbus-after-gnucash-version.json')
    }
    finally {
        $env:PATH = $old_path
        $env:GUILE_LOAD_PATH = $old_guile_load_path
        $env:GUILE_LOAD_COMPILED_PATH = $old_guile_load_compiled_path
        $env:SCHEME_LIBRARY_PATH = $old_scheme_library_path
        [Environment]::SetEnvironmentVariable(
            'DBUS_SESSION_BUS_ADDRESS', $old_dbus_session_bus_address, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_RUNTIME_DIR', $old_xdg_runtime_dir, 'Process')
    }
}
catch {
    $primary_failure = $_
    throw
}
finally {
    if (Test-Path -LiteralPath $install) {
        $uninstaller = Get-ChildItem -Path $install -File -Recurse -Filter 'unins*.exe' | Select-Object -First 1
        if (!$uninstaller -and $installer_succeeded -and !$primary_failure) {
            Write-RemainingInstallInventory -Root $install `
                -OutputPath (Join-Path $diagnostics 'remaining-installation-items-no-uninstaller.csv') | Out-Null
            throw "Installed uninstaller not found below $install."
        }
        if ($uninstaller) {
            $install_path_remained = $false
            try {
                Write-Host "Selected uninstaller: $($uninstaller.FullName)"
                Write-InstallPayloadProcessInventory -Root $install `
                    -OutputPath (Join-Path $diagnostics 'install-payload-processes-before-uninstall.json') | Out-Null
                $uninstaller_exit_code = Invoke-CheckedInnoProcess -FilePath $uninstaller.FullName `
                    -Description 'Silent uninstaller' -ArgumentList @(
                        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
                    ) -LogPath $uninstaller_log -ProcessResultsPath $process_results_log

                $install_path_remained = Test-Path -LiteralPath $install
                Write-InstallPathObservation -Root $install -Label 'immediate-after-uninstaller' `
                    -OutputPath $path_observations_log | Out-Null
                if ($install_path_remained) {
                    Write-RemainingInstallInventory -Root $install `
                        -OutputPath (Join-Path $diagnostics 'remaining-installation-items-immediate.csv') | Out-Null
                    Start-Sleep -Seconds 2
                    $install_path_remained_after_delay = Test-Path -LiteralPath $install
                    Write-InstallPathObservation -Root $install -Label '2-seconds-after-uninstaller' `
                        -OutputPath $path_observations_log | Out-Null
                    if ($install_path_remained_after_delay) {
                        Write-RemainingInstallInventory -Root $install `
                            -OutputPath (Join-Path $diagnostics 'remaining-installation-items-after-2s.csv') | Out-Null
                        Write-InstallPayloadProcessInventory -Root $install `
                            -OutputPath (Join-Path $diagnostics 'install-payload-processes-after-2s.json') | Out-Null
                    }
                    Write-Host "Installation root exists after 2-second observation: $install_path_remained_after_delay"
                }

                $registrations = @(Get-InnoProductRegistrations -ProductKey $product_key)
                Write-ProductRegistrationDiagnostics -Registrations $registrations `
                    -OutputPath (Join-Path $diagnostics 'post-uninstall-product-registrations.json') | Out-Null
                Assert-InnoProductNotRegistered -ProductKey $product_key
                if ($install_path_remained) {
                    throw "Silent uninstaller left the installation directory behind: $install"
                }
            }
            catch {
                $cleanup_failure = $_
                if ((Test-Path -LiteralPath $install) -and !$install_path_remained) {
                    Write-InstallPathObservation -Root $install -Label 'after-uninstaller-error' `
                        -OutputPath $path_observations_log | Out-Null
                    Write-RemainingInstallInventory -Root $install `
                        -OutputPath (Join-Path $diagnostics 'remaining-installation-items-after-error.csv') | Out-Null
                    Write-InstallPayloadProcessInventory -Root $install `
                        -OutputPath (Join-Path $diagnostics 'install-payload-processes-after-error.json') | Out-Null
                }
                try {
                    $registrations = @(Get-InnoProductRegistrations -ProductKey $product_key)
                    Write-ProductRegistrationDiagnostics -Registrations $registrations `
                        -OutputPath (Join-Path $diagnostics 'post-uninstall-product-registrations.json') | Out-Null
                }
                catch {
                    Write-Warning "Unable to inspect post-uninstall product registrations: $($_.Exception.Message)"
                }
                if ($primary_failure) {
                    Write-Warning "Installer cleanup failed after an earlier failure: $($cleanup_failure.Exception.Message)"
                }
                else {
                    throw $cleanup_failure
                }
            }
        }
        elseif ($primary_failure) {
            Write-RemainingInstallInventory -Root $install `
                -OutputPath (Join-Path $diagnostics 'remaining-installation-items-no-uninstaller.csv') | Out-Null
        }
    }
}

Write-Host "Installer preflight passed: $installer"
