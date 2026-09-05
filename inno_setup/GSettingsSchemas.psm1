Set-StrictMode -Version Latest

function Get-RequiredGSettingsSchemaIds {
    @(
        'org.gnucash.GnuCash'
        'org.gnome.desktop.interface'
        'org.gtk.gtk4.Settings.FileChooser'
    )
}

function Assert-GSettingsSchemaCache {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$GSettingsPath,
        [string[]]$RequiredSchemaId = (Get-RequiredGSettingsSchemaIds)
    )

    $directory_path = (Resolve-Path -LiteralPath $Directory).Path
    $gsettings = (Resolve-Path -LiteralPath $GSettingsPath).Path
    $compiled = Join-Path $directory_path 'gschemas.compiled'
    if (!(Test-Path -LiteralPath $compiled -PathType Leaf) -or (Get-Item -LiteralPath $compiled).Length -eq 0) {
        throw "Compiled GSettings cache is missing or empty: $compiled"
    }

    $stdout = [IO.Path]::GetTempFileName()
    $stderr = [IO.Path]::GetTempFileName()
    $isolated_data_root = Join-Path ([IO.Path]::GetTempPath()) ('gsettings-data-' + [guid]::NewGuid())
    $isolated_user_data = Join-Path $isolated_data_root 'user'
    $isolated_system_data = Join-Path $isolated_data_root 'system'
    New-Item -ItemType Directory -Path $isolated_user_data, $isolated_system_data | Out-Null
    $resolved_isolated_data_root = (Resolve-Path -LiteralPath $isolated_data_root).Path
    $old_schema_dir = $env:GSETTINGS_SCHEMA_DIR
    $old_user_data = $env:XDG_DATA_HOME
    $old_system_data = $env:XDG_DATA_DIRS
    try {
        $env:GSETTINGS_SCHEMA_DIR = $directory_path
        $env:XDG_DATA_HOME = $isolated_user_data
        $env:XDG_DATA_DIRS = $isolated_system_data
        $process = Start-Process -FilePath $gsettings -ArgumentList 'list-schemas' `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $schema_ids = @(Get-Content -LiteralPath $stdout | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
        if ($process.ExitCode -ne 0) {
            $error_output = Get-Content -LiteralPath $stderr -Raw
            throw "gsettings list-schemas failed with exit code $($process.ExitCode): $error_output"
        }
    }
    finally {
        $env:GSETTINGS_SCHEMA_DIR = $old_schema_dir
        $env:XDG_DATA_HOME = $old_user_data
        $env:XDG_DATA_DIRS = $old_system_data
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (!$resolved_isolated_data_root.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean an unexpected GSettings isolation directory: $resolved_isolated_data_root"
        }
        Remove-Item -LiteralPath $resolved_isolated_data_root -Recurse -Force -ErrorAction SilentlyContinue
    }

    $missing_schema_ids = @($RequiredSchemaId | Where-Object { $_ -notin $schema_ids })
    if ($missing_schema_ids.Count -ne 0) {
        throw "Required IDs are missing from compiled GSettings cache ${compiled}: $($missing_schema_ids -join ', ')"
    }
}

function Install-GSettingsSchemas {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,
        [Parameter(Mandatory)]
        [string]$TargetDirectory,
        [Parameter(Mandatory)]
        [string]$CompilerPath,
        [Parameter(Mandatory)]
        [string]$GSettingsPath,
        [string[]]$RequiredSchemaId = (Get-RequiredGSettingsSchemaIds)
    )

    $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
    $compiler = (Resolve-Path -LiteralPath $CompilerPath).Path
    if (!(Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    }
    $target = (Resolve-Path -LiteralPath $TargetDirectory).Path

    $schema_inputs = @(Get-ChildItem -LiteralPath $source -File | Where-Object {
        $_.Name -like '*.gschema.xml' -or
        $_.Name -like '*.enums.xml' -or
        $_.Name -like '*.gschema.override'
    })
    if (!($schema_inputs | Where-Object { $_.Name -like '*.gschema.xml' })) {
        throw "No GSettings schema definitions found in source directory: $source"
    }
    foreach ($input_file in $schema_inputs) {
        Copy-Item -LiteralPath $input_file.FullName -Destination $target -Force
    }

    $compiled = Join-Path $target 'gschemas.compiled'
    if (Test-Path -LiteralPath $compiled) {
        Remove-Item -LiteralPath $compiled -Force
    }

    $compiler_process = Start-Process -FilePath $compiler `
        -ArgumentList @('--strict', ('"{0}"' -f $target)) `
        -NoNewWindow -PassThru -Wait
    if ($compiler_process.ExitCode -ne 0) {
        throw "glib-compile-schemas failed with exit code $($compiler_process.ExitCode)."
    }
    if (!(Test-Path -LiteralPath $compiled -PathType Leaf) -or (Get-Item -LiteralPath $compiled).Length -eq 0) {
        throw "glib-compile-schemas did not create a non-empty cache: $compiled"
    }
    Assert-GSettingsSchemaCache -Directory $target -GSettingsPath $GSettingsPath -RequiredSchemaId $RequiredSchemaId

    Write-Host "Compiled $($schema_inputs.Count) GSettings inputs with --strict; required schema IDs are present."
}

Export-ModuleMember -Function @(
    'Assert-GSettingsSchemaCache',
    'Get-RequiredGSettingsSchemaIds',
    'Install-GSettingsSchemas'
)
