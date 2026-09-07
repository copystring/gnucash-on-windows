[CmdletBinding()]
param([string]$InnoCompiler)

$ErrorActionPreference = 'Stop'
$module = (Resolve-Path (Join-Path $PSScriptRoot '..\Gtk3Payload.psm1')).Path
Import-Module $module -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-EmptyFile {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    New-Item -ItemType File -Path $Path -Force | Out-Null
}

function Assert-RejectedGtk3Payload {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Expected)

    $rejected = $false
    try {
        Assert-NoGtk3Payload -Root $Root
    }
    catch {
        $rejected = $_.Exception.Message -match [regex]::Escape($Expected)
    }
    Assert-True $rejected "GTK3 payload was not rejected: $Expected"
}

function Assert-RecipeFilter {
    $recipe = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\gnucash-mingw64.iss') -Raw
    $icons = 'Source: "@MINGW_DIR@\\share\\icons\\\*"; DestDir: "\{app\}\\share\\icons"; Excludes: "gtk3-demo\*,gtk3-widget-factory\*"; Flags: recursesubdirs; Components: main'
    $themes = 'Source: "@MINGW_DIR@\\share\\themes\\\*"; DestDir: "\{app\}\\share\\themes"; Excludes: "gtk-3\.0\\\*"; Flags: recursesubdirs skipifsourcedoesntexist; Components: main'
    $gtk4 = 'Source: "@MINGW_DIR@\\share\\gtk-4\.0\\\*"; DestDir: "\{app\}\\share\\gtk-4\.0"; Flags: recursesubdirs; Components: main'
    $schemas = 'Source: "@INST_DIR@\\share\\glib-2\.0\\\*"; DestDir: "\{app\}\\share\\glib-2\.0"; Flags: recursesubdirs; Components: main'

    Assert-True ($recipe -match $icons) 'The recursive icon payload lacks the GTK3 demo exclusion.'
    Assert-True ($recipe -match $themes) 'The recursive theme payload lacks the GTK3 theme exclusion.'
    Assert-True ($recipe -match $gtk4) 'The required GTK4 runtime data source must remain fail-fast.'
    Assert-True ($recipe -match $schemas) 'The required GSettings schema source must remain fail-fast.'
}

function Get-RecipeSourceLine {
    param([Parameter(Mandatory)][string]$RelativeSource)

    $recipe = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\gnucash-mingw64.iss')
    $matches = @($recipe | Where-Object { $_ -like "Source: `"@MINGW_DIR@\$RelativeSource`";*" })
    Assert-True ($matches.Count -eq 1) "Expected one Inno source line for $RelativeSource."
    return $matches[0]
}

function New-InnoFixtureRecipe {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SourceLine,
        [Parameter(Mandatory)][string]$Name
    )

    $output = Join-Path $Root 'output'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $source = $SourceLine.Replace('@MINGW_DIR@', $Root)
    $recipe = Join-Path $Root "$Name.iss"
    $content = @"
[Setup]
AppName=Inno fixture
AppVersion=1
DefaultDirName={autopf}\InnoFixture
Uninstallable=no
OutputDir=$output
OutputBaseFilename=$Name

[Components]
Name: "main"; Description: "Main payload"; Types: full

[Files]
$source
"@
    [IO.File]::WriteAllText($recipe, $content, [Text.UTF8Encoding]::new($true))
    return $recipe
}

function Assert-InnoCompile {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Recipe,
        [Parameter(Mandatory)][bool]$ExpectedSuccess,
        [Parameter(Mandatory)][string]$Description
    )

    $stdout = "$Recipe.stdout.log"
    $stderr = "$Recipe.stderr.log"
    $process = Start-Process -FilePath $Compiler -ArgumentList @('/Q', "`"$Recipe`"") `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    $exit_code = $process.ExitCode
    $output = @(
        if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw }
        if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw }
    ) -join [Environment]::NewLine
    $succeeded = $exit_code -eq 0
    if ($succeeded -ne $ExpectedSuccess) {
        throw "Inno fixture '$Description' exit $exit_code; expected success=${ExpectedSuccess}: $output"
    }
    if (!$ExpectedSuccess -and $output -notmatch 'No files found matching') {
        throw "Inno fixture '$Description' failed for an unexpected reason (exit $exit_code): $output"
    }
}

function Test-InnoThemeFixtures {
    param([Parameter(Mandatory)][string]$Compiler,
          [Parameter(Mandatory)][string]$Root)

    if (!(Test-Path -LiteralPath $Compiler -PathType Leaf)) {
        throw "Inno compiler not found: $Compiler"
    }

    $theme_source = Get-RecipeSourceLine 'share\themes\*'
    $required_gtk4_source = Get-RecipeSourceLine 'share\gtk-4.0\*'
    $without_optional = $theme_source.Replace(' skipifsourcedoesntexist', '')

    foreach ($case in @('missing', 'empty', 'gtk3-only', 'gtk4-present')) {
        $fixture = Join-Path $Root $case
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        switch ($case) {
            'empty' { New-Item -ItemType Directory -Path (Join-Path $fixture 'share\themes') | Out-Null }
            'gtk3-only' {
                foreach ($theme in @('Default', 'Emacs')) {
                    New-EmptyFile (Join-Path $fixture "share\themes\$theme\gtk-3.0\gtk-keys.css")
                }
            }
            'gtk4-present' { New-EmptyFile (Join-Path $fixture 'share\themes\Default\gtk-4.0\gtk.css') }
        }
        $recipe = New-InnoFixtureRecipe -Root $fixture -SourceLine $theme_source -Name 'theme-fixture'
        Assert-InnoCompile -Compiler $Compiler -Recipe $recipe -ExpectedSuccess $true -Description "optional theme source: $case"
    }

    $excluded = Join-Path $Root 'gtk3-only'
    $negative = New-InnoFixtureRecipe -Root $excluded -SourceLine $without_optional -Name 'theme-required'
    Assert-InnoCompile -Compiler $Compiler -Recipe $negative -ExpectedSuccess $false -Description 'GTK3-only theme source without optional flag'

    $required_missing = Join-Path $Root 'required-gtk4-missing'
    New-Item -ItemType Directory -Path $required_missing -Force | Out-Null
    $negative = New-InnoFixtureRecipe -Root $required_missing -SourceLine $required_gtk4_source -Name 'gtk4-required'
    Assert-InnoCompile -Compiler $Compiler -Recipe $negative -ExpectedSuccess $false -Description 'missing required GTK4 runtime data'
}

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('gtk3-payload-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path

try {
    Assert-RecipeFilter
    Write-Host 'recursive Inno source filters: passed'

    if ($InnoCompiler) {
        Test-InnoThemeFixtures -Compiler $InnoCompiler -Root (Join-Path $test_root 'inno')
        Write-Host 'optional external theme Inno fixtures: passed'
    }

    $clean = Join-Path $test_root 'clean'
    New-EmptyFile (Join-Path $clean 'bin\libgtk-4-1.dll')
    New-EmptyFile (Join-Path $clean 'lib\gdk-pixbuf-2.0\2.10.0\loaders\libpixbufloader-png.dll')
    New-EmptyFile (Join-Path $clean 'share\icons\hicolor\scalable\apps\org.gtk.Demo4.svg')
    New-EmptyFile (Join-Path $clean 'share\icons\hicolor\scalable\apps\org.gtk.WidgetFactory4.svg')
    New-EmptyFile (Join-Path $clean 'share\icons\hicolor\16x16\apps\document-open.png')
    New-EmptyFile (Join-Path $clean 'share\themes\Default\gtk-4.0\gtk.css')
    Assert-NoGtk3Payload -Root $clean
    Write-Host 'GTK4 and common icon/theme assets: passed'

    $forbidden_paths = @(
        @{ Name = 'gtk-library'; RelativePath = 'bin\libgtk-3-0.dll'; Expected = 'libgtk-3-0.dll' },
        @{ Name = 'gdk-library'; RelativePath = 'bin\libgdk-3-0.dll'; Expected = 'libgdk-3-0.dll' },
        @{ Name = 'gtk-module'; RelativePath = 'lib\gtk-3.0\3.0.0\immodules\im-test.dll'; Expected = 'lib\gtk-3.0' },
        @{ Name = 'gtk-share'; RelativePath = 'share\gtk-3.0\gtk.css'; Expected = 'share\gtk-3.0' },
        @{ Name = 'gtk-typelib'; RelativePath = 'lib\girepository-1.0\Gtk-3.0.typelib'; Expected = 'Gtk-3.0.typelib' },
        @{ Name = 'gdk-typelib'; RelativePath = 'lib\girepository-1.0\Gdk-3.0.typelib'; Expected = 'Gdk-3.0.typelib' }
    )
    foreach ($forbidden in $forbidden_paths) {
        $fixture = Join-Path $test_root $forbidden.Name
        New-EmptyFile (Join-Path $fixture $forbidden.RelativePath)
        Assert-RejectedGtk3Payload -Root $fixture -Expected $forbidden.Expected
    }
    Write-Host 'GTK3 libraries, modules, share data and typelibs: passed'

    foreach ($theme in @('Default', 'Emacs')) {
        $fixture = Join-Path $test_root "gtk3-theme-$theme"
        New-EmptyFile (Join-Path $fixture "share\themes\nested\$theme\gtk-3.0\gtk-keys.css")
        Assert-RejectedGtk3Payload -Root $fixture -Expected 'GTK3 theme payload'
    }
    Write-Host 'GTK3 theme subtrees: passed'

    foreach ($asset in @('gtk3-demo.png', 'gtk3-widget-factory-symbolic.symbolic.png')) {
        $fixture = Join-Path $test_root "gtk3-icon-$asset"
        New-EmptyFile (Join-Path $fixture "share\icons\hicolor\extra\16x16\apps\$asset")
        Assert-RejectedGtk3Payload -Root $fixture -Expected 'GTK3 demo asset'
    }
    Write-Host 'GTK3 demo and WidgetFactory assets: passed'
}
finally {
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

Write-Host 'GTK3 payload guard tests passed.'
exit 0
