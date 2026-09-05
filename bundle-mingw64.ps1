# bundle-mingw64.ps1: Powershell Script to create gnucash-setup.exe on MinGW64.
# Copyright 2017 John Ralls <jralls@ceridwen.us>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of
# the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, contact:
# Free Software Foundation           Voice:  +1-617-542-5942
# 51 Franklin Street, Fifth Floor    Fax:    +1-617-542-2652
# Boston, MA  02110-1301,  USA       gnu@gnu.org

<#
.SYNOPSIS

Runs Inno-Setup to create a gnucash installer program.

.DESCRIPTION

Creates a GnuCash installer program from a GnuCash build. Note that we need to extract the Gtk, AqBanking, and Gwenhywfar message catalogs from the mingw_prefix hierarchy so using the same values for that and prefix will cause extraneous message catalogs to be included in the installer.

This script must not be moved from the gnucash-on-windows.git working directory.

You may need to allow running scripts on your computer and depending
on where the target_dir is you may need to run the script with
Administrator privileges.

.PARAMETER mingw_prefix

Optional. The path to the mingw_arch directory, default c:\gcdev64\msys2\ucrt64

.PARAMETER gnc_build_dir

Optional. The path to the GnuCash build directory, default: c:\gcdev64\gnucash-build

.PARAMETER prefix

Optional. The value of CMAKE_INSTALL_PREFIX used when configuring the GnuCash and GnuCash Documentation builds. It's where this script expects to find the installed GnuCash and GnuCash-Docs files. The installer is written to the directory containing this script. Default: c:\gcdev64\inst

.PARAMETER git_build

Optional. Boolean to indicate whether or not this is a git build. Default $true

#>

[CmdletBinding()]
Param(
    [string]$mingw_prefix='c:\gcdev64\msys2\ucrt64',
    [string]$gnc_build_dir='c:\gcdev64\gnucash-build',
    [string]$prefix='c:\gcdev64\inst',
    [bool]$git_build=$true
)

$script_dir = Split-Path $script:MyInvocation.MyCommand.Path
$target_dir = $script_dir

$progressPreference = 'silentlyContinue'
$ErrorActionPreference = 'Stop'

try {
    $signature =
    ' [DllImport("kernel32.dll")]
      public static extern bool GetBinaryType(string lpApplicationName,
					      ref int lpBinaryType);'
    add-type -MemberDefinition $signature -Name BinaryType -Namespace Win32Utils
}
catch {} #type already loaded, ignore problem.


function version_item([string]$tag, [string]$path) {
    $splits = select-string -pattern $tag -path $path | %{$_ -split "\s+"}
    if ($splits.Count -lt 3 -or [string]::IsNullOrWhiteSpace($splits[2])) {
        throw "Unable to read $tag from $path."
    }
    return $splits[2]
}

function guile-version([string]$prefix) {
    $guile = Join-Path $prefix 'bin\guile.exe'
    if (!(Test-Path -LiteralPath $guile)) {
        throw "Guile executable not found: $guile"
    }
    $version_output = & $guile --version
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query the Guile version (exit code $LASTEXITCODE)."
    }
    $version_match = [regex]::Match(($version_output -join "`n"), '(?m)^guile \(GNU Guile\) (\d+\.\d+)')
    if (!$version_match.Success) {
        throw "Unable to parse the Guile major.minor version from: $($version_output -join ' ')"
    }
    return $version_match.Groups[1].Value
}

if ($git_build) {
  $gnucash = "gnucash-git"
}
else {
  $gnucash = get-childitem -path $target_dir\build | where-object {$_.Name -match "gnucash-[0-9.]+"} |sort-object -Property {$_.CreationTime} | select-object -last 1
}

if ($PSVersionTable.PSVersion.Major -ge 3) {
    $PSDefaultParameterValues['*:Encoding'] = 'utf8'
    }

$gnc_config_h = "$gnc_build_dir\common\config.h"

$major_version = version_item -tag "PROJECT_VERSION_MAJOR" -path $gnc_config_h
$minor_version = version_item -tag "PROJECT_VERSION_MINOR" -path $gnc_config_h
$package_version = "$major_version.$minor_version"
$guile_version = guile-version -prefix $mingw_prefix

$date = get-date -format "yyyy-MM-dd"
$setup_result = "$target_dir\gnucash-$package_version.setup.exe"
$final_file = ""
if ($git_build) {
  $gnc_vcsinfo_h = "$gnc_build_dir\libgnucash\core-utils\gnc-vcs-info.h"
  $vcs_rev = version_item -tag "GNC_VCS_REV" -path $gnc_vcsinfo_h | %{$_ -replace """", ""}
  $final_file = "$target_dir\gnucash-$package_version-$date-git-$vcs_rev.setup.exe"
  }
else {
  $final_file = "$target_dir\gnucash-$package_version.setup.exe"
}

# Inno-setup isn't able to easily pick out particular message catalogs from $mingw_prefix/share/locale, so copy the ones we want to $prefix\share\locale.

$source_locale_dir = "$mingw_prefix\share\locale"
$inst_locale_dir = "$prefix\share\locale"
foreach ($msgcat in "gtk40.mo", "iso_4217.mo", "aqbanking.mo", "gwenhywfar.mo") {
    foreach ($dir in Get-ChildItem -LiteralPath $source_locale_dir -Directory) {
        $source_path = Join-Path $dir.FullName "LC_MESSAGES\$msgcat"
        if (Test-Path -LiteralPath $source_path -PathType Leaf) {
            $inst_path = Join-Path $inst_locale_dir "$($dir.Name)\LC_MESSAGES"
            New-Item -ItemType Directory -Path $inst_path -Force | Out-Null
            Copy-Item -LiteralPath $source_path -Destination $inst_path
        }
    }
}
# Consolidate every GSettings compiler input and reject incomplete schemas.
& "$script_dir\inno_setup\prepare-gsettings-schemas.ps1" `
    -SourceDirectory "$mingw_prefix\share\glib-2.0\schemas" `
    -TargetDirectory "$prefix\share\glib-2.0\schemas" `
    -CompilerPath "$mingw_prefix\bin\glib-compile-schemas.exe" `
    -GSettingsPath "$mingw_prefix\bin\gsettings.exe"

# configure gnucash.iss

$msys_prefix = (Resolve-Path $mingw_prefix).Path

$content = Get-Content -Raw -Path inno_setup\gnucash-mingw64.iss
$content = $content.replace("@MINGW_DIR@", "$msys_prefix")
$content = $content.replace("@INST_DIR@", "$prefix")
$content = $content.replace("@PACKAGE_VERSION@", "$package_version")
$content = $content.replace("@PACKAGE@", "gnucash")
$content = $content.replace("@GNUCASH_MAJOR_VERSION@", "$major_version")
$content = $content.replace("@GNUCASH_MINOR_VERSION@", "$minor_version")
$content = $content.replace("@GUILE_VERSION@", "$guile_version")
$content = $content.replace("@GC_WIN_REPOS_DIR@", ".")
if ($content -match '@[A-Z_]+@') {
    throw "Unresolved Inno template token: $($matches[0])"
}
set-content -Path gnucash.iss -Value $content -Encoding utf8BOM

write-host "Running Inno Setup to create $final_file."

if (test-path -path $setup_result) {
    remove-item -path $setup_result
}
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (!(Test-Path -LiteralPath $iscc)) {
    $iscc = Join-Path ${env:ProgramFiles(x86)} 'inno\iscc.exe'
}
if (!(Test-Path -LiteralPath $iscc)) {
    throw 'Inno Setup compiler not found.'
}

Push-Location $target_dir
try {
    & $iscc /Q "$target_dir\gnucash.iss"
    $iscc_status = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($iscc_status -ne 0) {
    throw "Inno Setup failed with exit code $iscc_status."
}

if ($git_build) {
  if ((test-path -path $setup_result) -and (test-path -path $final_file)) {
    remove-item $final_file
  }
  if (!(test-path -path $setup_result)) {
    throw "Inno Setup did not create $setup_result."
  }
  rename-item -path $setup_result $final_file
}
return $final_file
