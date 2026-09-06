[CmdletBinding()]
param()

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
    $themes = 'Source: "@MINGW_DIR@\\share\\themes\\\*"; DestDir: "\{app\}\\share\\themes"; Excludes: "gtk-3\.0\\\*"; Flags: recursesubdirs; Components: main'

    Assert-True ($recipe -match $icons) 'The recursive icon payload lacks the GTK3 demo exclusion.'
    Assert-True ($recipe -match $themes) 'The recursive theme payload lacks the GTK3 theme exclusion.'
}

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('gtk3-payload-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path

try {
    Assert-RecipeFilter
    Write-Host 'recursive Inno source filters: passed'

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
