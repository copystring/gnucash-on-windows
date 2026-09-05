[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$module = (Resolve-Path (Join-Path $PSScriptRoot '..\GSettingsSchemas.psm1')).Path
Import-Module $module -Force

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('gsettings-schemas-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path
$mock_compiler = Join-Path $test_root 'mock-glib-compile-schemas.ps1'
$mock_compiler_command = Join-Path $test_root 'mock-glib-compile-schemas.cmd'
$mock_gsettings = Join-Path $test_root 'mock-gsettings.ps1'
$mock_gsettings_command = Join-Path $test_root 'mock-gsettings.cmd'

@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$ErrorActionPreference = 'Stop'
if ($Arguments.Count -ne 2 -or $Arguments[0] -ne '--strict') {
    [Console]::Error.WriteLine('Expected --strict and a schema directory.')
    exit 22
}
if ($env:MOCK_SCHEMA_COMPILER_FAIL -eq 'true') {
    [Console]::Error.WriteLine('Deliberate compiler failure.')
    exit 23
}
if (!(Test-Path -LiteralPath (Join-Path $Arguments[1] 'org.gnome.desktop.enums.xml'))) {
    [Console]::Error.WriteLine('Referenced enum is not defined.')
    exit 24
}
$Arguments -join ' ' | Set-Content -LiteralPath $env:MOCK_SCHEMA_COMPILER_LOG
Set-Content -LiteralPath (Join-Path $Arguments[1] 'gschemas.compiled') -Value 'compiled'
exit 0
'@ | Set-Content -LiteralPath $mock_compiler -Encoding utf8
@'
@echo off
pwsh -NoProfile -File "%~dp0mock-glib-compile-schemas.ps1" %*
'@ | Set-Content -LiteralPath $mock_compiler_command -Encoding ascii
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
if ($Arguments.Count -ne 1 -or $Arguments[0] -ne 'list-schemas') {
    [Console]::Error.WriteLine('Expected list-schemas.')
    exit 25
}
if (!(Test-Path -LiteralPath (Join-Path $env:GSETTINGS_SCHEMA_DIR 'gschemas.compiled'))) {
    [Console]::Error.WriteLine('Compiled cache is missing.')
    exit 26
}
'org.gnucash.GnuCash'
'org.gtk.gtk4.Settings.FileChooser'
$user_data_parent = Split-Path $env:XDG_DATA_HOME -Parent
$system_data_parent = Split-Path $env:XDG_DATA_DIRS -Parent
$isolated = $user_data_parent -eq $system_data_parent -and
    (Split-Path $env:XDG_DATA_HOME -Leaf) -eq 'user' -and
    (Split-Path $env:XDG_DATA_DIRS -Leaf) -eq 'system' -and
    (Test-Path -LiteralPath $env:XDG_DATA_HOME -PathType Container) -and
    (Test-Path -LiteralPath $env:XDG_DATA_DIRS -PathType Container)
if ($env:MOCK_GSETTINGS_MISSING_ID -ne 'true' -or !$isolated) {
    'org.gnome.desktop.interface'
}
exit 0
'@ | Set-Content -LiteralPath $mock_gsettings -Encoding utf8
@'
@echo off
pwsh -NoProfile -File "%~dp0mock-gsettings.ps1" %*
'@ | Set-Content -LiteralPath $mock_gsettings_command -Encoding ascii

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-SchemaFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$IncludeEnum
    )

    $source = Join-Path $Root 'source'
    $target = Join-Path $Root 'target'
    New-Item -ItemType Directory -Path $source, $target | Out-Null

    @'
<schemalist>
  <schema id="org.gtk.gtk4.Settings.FileChooser" path="/org/gtk/gtk4/settings/file-chooser/">
    <key name="sort-directories-first" type="b"><default>false</default></key>
  </schema>
</schemalist>
'@ | Set-Content -LiteralPath (Join-Path $source 'org.gtk.gtk4.Settings.FileChooser.gschema.xml') -Encoding utf8
    @'
<schemalist>
  <schema id="org.gnome.desktop.interface" path="/org/gnome/desktop/interface/">
    <key name="toolbar-style" enum="org.gnome.desktop.ToolbarStyle"><default>'both-horiz'</default></key>
  </schema>
</schemalist>
'@ | Set-Content -LiteralPath (Join-Path $source 'org.gnome.desktop.interface.gschema.xml') -Encoding utf8
    if ($IncludeEnum) {
        @'
<schemalist>
  <enum id="org.gnome.desktop.ToolbarStyle">
    <value nick="both-horiz" value="0"/>
  </enum>
</schemalist>
'@ | Set-Content -LiteralPath (Join-Path $source 'org.gnome.desktop.enums.xml') -Encoding utf8
    }
    @'
<schemalist>
  <schema id="org.gnucash.GnuCash" path="/org/gnucash/GnuCash/">
    <key name="test" type="b"><default>false</default></key>
  </schema>
</schemalist>
'@ | Set-Content -LiteralPath (Join-Path $target 'org.gnucash.GnuCash.gschema.xml') -Encoding utf8

    [pscustomobject]@{ Source = $source; Target = $target }
}

try {
    $success = New-SchemaFixture -Root (Join-Path $test_root 'success') -IncludeEnum
    $env:MOCK_SCHEMA_COMPILER_FAIL = 'false'
    $env:MOCK_GSETTINGS_MISSING_ID = 'false'
    $env:MOCK_SCHEMA_COMPILER_LOG = Join-Path $test_root 'compiler.log'
    Install-GSettingsSchemas -SourceDirectory $success.Source -TargetDirectory $success.Target `
        -CompilerPath $mock_compiler_command -GSettingsPath $mock_gsettings_command
    Assert-True (Test-Path -LiteralPath (Join-Path $success.Target 'org.gnome.desktop.enums.xml') -PathType Leaf) 'Enum definitions were not copied.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.Target 'gschemas.compiled') -PathType Leaf) 'Compiled schema cache is missing.'
    Assert-True ((Get-Content -LiteralPath $env:MOCK_SCHEMA_COMPILER_LOG -Raw) -match '^--strict ') 'Schema compiler was not invoked with --strict.'
    Write-Host 'complete definitions and strict compilation: passed'

    $missing_enum = New-SchemaFixture -Root (Join-Path $test_root 'missing-enum')
    $caught_missing_enum = $false
    try {
        Install-GSettingsSchemas -SourceDirectory $missing_enum.Source -TargetDirectory $missing_enum.Target `
            -CompilerPath $mock_compiler_command -GSettingsPath $mock_gsettings_command
    }
    catch {
        $caught_missing_enum = $_.Exception.Message -match 'failed with exit code 24'
    }
    Assert-True $caught_missing_enum 'Missing enum dependency was not rejected.'
    Write-Host 'missing enum dependency: passed'

    $compiler_failure = New-SchemaFixture -Root (Join-Path $test_root 'compiler-failure') -IncludeEnum
    Set-Content -LiteralPath (Join-Path $compiler_failure.Target 'gschemas.compiled') -Value 'stale'
    $env:MOCK_SCHEMA_COMPILER_FAIL = 'true'
    $caught_compiler_failure = $false
    try {
        Install-GSettingsSchemas -SourceDirectory $compiler_failure.Source -TargetDirectory $compiler_failure.Target `
            -CompilerPath $mock_compiler_command -GSettingsPath $mock_gsettings_command
    }
    catch {
        $caught_compiler_failure = $_.Exception.Message -match 'failed with exit code 23'
    }
    Assert-True $caught_compiler_failure 'Schema compiler failure was not propagated.'
    Assert-True (!(Test-Path -LiteralPath (Join-Path $compiler_failure.Target 'gschemas.compiled'))) 'Stale compiled cache survived a compiler failure.'
    Write-Host 'compiler failure and stale-cache rejection: passed'

    $missing_cache_id = New-SchemaFixture -Root (Join-Path $test_root 'missing-cache-id') -IncludeEnum
    $env:MOCK_SCHEMA_COMPILER_FAIL = 'false'
    $env:MOCK_GSETTINGS_MISSING_ID = 'true'
    $caught_missing_cache_id = $false
    try {
        Install-GSettingsSchemas -SourceDirectory $missing_cache_id.Source -TargetDirectory $missing_cache_id.Target `
            -CompilerPath $mock_compiler_command -GSettingsPath $mock_gsettings_command
    }
    catch {
        $caught_missing_cache_id = $_.Exception.Message -match 'Required IDs are missing from compiled GSettings cache'
    }
    Assert-True $caught_missing_cache_id 'Missing required ID in compiled cache was not rejected.'
    Write-Host 'required compiled-cache IDs: passed'

    Write-Host 'GSettings schema preparation tests passed.'
}
finally {
    Remove-Item Env:MOCK_SCHEMA_COMPILER_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:MOCK_SCHEMA_COMPILER_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:MOCK_GSETTINGS_MISSING_ID -ErrorAction SilentlyContinue
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

# Deliberately failing child compilers must not become the test process exit code.
exit 0
