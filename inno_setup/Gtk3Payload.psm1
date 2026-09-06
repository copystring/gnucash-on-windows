# Gtk3Payload.psm1: Reject GTK3-only files from a GTK4 installer payload.
# Copyright 2026 GnuCash Development Team
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 2 of the License, or (at your option)
# any later version.

Set-StrictMode -Version Latest

function Assert-NoGtk3Payload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $root_path = (Resolve-Path -LiteralPath $Root).Path
    $forbidden_paths = @(
        'bin\libgtk-3-0.dll',
        'bin\libgdk-3-0.dll',
        'lib\gtk-3.0',
        'share\gtk-3.0',
        'lib\girepository-1.0\Gtk-3.0.typelib',
        'lib\girepository-1.0\Gdk-3.0.typelib'
    )

    foreach ($relative_path in $forbidden_paths) {
        $path = Join-Path $root_path $relative_path
        if (Test-Path -LiteralPath $path) {
            throw "Unexpected GTK3 runtime payload: $path"
        }
    }

    $themes = Join-Path $root_path 'share\themes'
    if (Test-Path -LiteralPath $themes -PathType Container) {
        $gtk3_theme = Get-ChildItem -LiteralPath $themes -Directory -Recurse |
            Where-Object { $_.Name -ieq 'gtk-3.0' } |
            Select-Object -First 1
        if ($gtk3_theme) {
            throw "Unexpected GTK3 theme payload: $($gtk3_theme.FullName)"
        }
    }

    $icons = Join-Path $root_path 'share\icons'
    if (Test-Path -LiteralPath $icons -PathType Container) {
        $gtk3_icon = Get-ChildItem -LiteralPath $icons -File -Recurse |
            Where-Object { $_.Name -match '(?i)^gtk3-(demo|widget-factory)(?:[-.]|$)' } |
            Select-Object -First 1
        if ($gtk3_icon) {
            throw "Unexpected GTK3 demo asset: $($gtk3_icon.FullName)"
        }
    }
}

Export-ModuleMember -Function Assert-NoGtk3Payload
