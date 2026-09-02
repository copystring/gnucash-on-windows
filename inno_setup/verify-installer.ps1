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
    [string]$InstallPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Description = $FilePath
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "$Description failed with exit code $($process.ExitCode)."
    }
}

function Assert-AnyFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )

    if (!(Get-ChildItem -Path $Path -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "Expected installer payload is missing: $Path"
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

$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $InstallPath = Join-Path ([System.IO.Path]::GetTempPath()) "gnucash-installer-preflight-$([guid]::NewGuid().ToString('N'))"
}
$install = [System.IO.Path]::GetFullPath($InstallPath)
if (Test-Path -LiteralPath $install) {
    throw "Installer test destination already exists: $install"
}

$installer_succeeded = $false
$primary_failure = $null
try {
    Invoke-CheckedProcess -FilePath $installer -Description 'Silent installer' -ArgumentList @(
        '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$install`""
    )
    $installer_succeeded = $true

    foreach ($required in @(
        "$install\bin\gnucash.exe",
        "$install\bin\libgtk-4-1.dll",
        "$install\share\glib-2.0\schemas\gschemas.compiled",
        "$install\share\glib-2.0\schemas\org.gtk.gtk4.Settings.*.gschema.xml"
    )) {
        Assert-AnyFile -Path $required
    }
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
        "$install\share\gtk-4.0\*",
        "$install\share\locale\*\LC_MESSAGES\aqbanking.mo",
        "$install\share\locale\*\LC_MESSAGES\gwenhywfar.mo",
        "$install\share\locale\*\LC_MESSAGES\gtk40.mo",
        "$install\share\locale\*\LC_MESSAGES\iso_4217.mo"
    )) {
        Assert-AnyFile -Path $required -Recurse
    }

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

    Test-PeImportClosure -Root $install -Dumpbin (Get-Dumpbin) -SystemImports (Get-SystemImports)

    $old_path = $env:PATH
    $old_guile_load_path = $env:GUILE_LOAD_PATH
    $old_guile_load_compiled_path = $env:GUILE_LOAD_COMPILED_PATH
    $old_scheme_library_path = $env:SCHEME_LIBRARY_PATH
    try {
        $env:PATH = "$install\bin;$env:SystemRoot\System32;$env:SystemRoot"
        $env:GUILE_LOAD_PATH = ''
        $env:GUILE_LOAD_COMPILED_PATH = ''
        $env:SCHEME_LIBRARY_PATH = ''
        $version = & "$install\bin\gnucash.exe" --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "GnuCash --version failed with exit code ${LASTEXITCODE}: $($version -join ' ')"
        }
    }
    finally {
        $env:PATH = $old_path
        $env:GUILE_LOAD_PATH = $old_guile_load_path
        $env:GUILE_LOAD_COMPILED_PATH = $old_guile_load_compiled_path
        $env:SCHEME_LIBRARY_PATH = $old_scheme_library_path
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
            throw "Installed uninstaller not found below $install."
        }
        if ($uninstaller) {
            try {
                Invoke-CheckedProcess -FilePath $uninstaller.FullName -Description 'Silent uninstaller' -ArgumentList @(
                    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
                )
                if (Test-Path -LiteralPath $install) {
                    throw "Silent uninstaller left the installation directory behind: $install"
                }
            }
            catch {
                if ($primary_failure) {
                    Write-Warning "Installer cleanup failed after an earlier failure: $($_.Exception.Message)"
                }
                else {
                    throw
                }
            }
        }
    }
}

Write-Host "Installer preflight passed: $installer"
