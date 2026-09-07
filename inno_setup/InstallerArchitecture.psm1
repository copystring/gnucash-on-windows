Set-StrictMode -Version Latest

function Get-InnoProductRegistrations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProductKey)

    $subkey = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductKey"
    foreach ($hive in @(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryHive]::CurrentUser
    )) {
        $views = if ($hive -eq [Microsoft.Win32.RegistryHive]::CurrentUser) {
            # HKCU\Software isn't redirected; do not report the same key twice.
            @([Microsoft.Win32.RegistryView]::Default)
        }
        else {
            @(
                [Microsoft.Win32.RegistryView]::Registry64,
                [Microsoft.Win32.RegistryView]::Registry32
            )
        }
        foreach ($view in $views) {
            $base_key = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $key = $base_key.OpenSubKey($subkey)
                if ($key) {
                    try {
                        [pscustomobject]@{
                            Hive = $hive
                            View = $view
                            ProductKey = $ProductKey
                            DisplayName = $key.GetValue('DisplayName')
                            InstallLocation = $key.GetValue('InstallLocation')
                            UninstallString = $key.GetValue('UninstallString')
                        }
                    }
                    finally {
                        $key.Dispose()
                    }
                }
            }
            finally {
                $base_key.Dispose()
            }
        }
    }
}

function Get-ProgramFiles64 {
    [CmdletBinding()]
    param()

    if (![Environment]::Is64BitOperatingSystem) {
        throw 'The AMD64 installer preflight requires 64-bit Windows.'
    }
    $program_files = [Environment]::GetEnvironmentVariable('ProgramW6432', 'Process')
    if ([string]::IsNullOrWhiteSpace($program_files)) {
        $program_files = [Environment]::GetEnvironmentVariable('ProgramW6432', 'Machine')
    }
    if ([string]::IsNullOrWhiteSpace($program_files)) {
        throw 'Unable to resolve the 64-bit Program Files directory from ProgramW6432.'
    }
    return [IO.Path]::GetFullPath($program_files)
}

function Assert-InnoProductNotRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProductKey)

    $registrations = @(Get-InnoProductRegistrations -ProductKey $ProductKey)
    if ($registrations.Count -ne 0) {
        $locations = $registrations | ForEach-Object { "$($_.Hive)/$($_.View): $($_.InstallLocation)" }
        throw "Refusing to run an installer preflight over an existing $ProductKey registration:`n$($locations -join "`n")"
    }
}

function Assert-InnoProductRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProductKey,
        [Parameter(Mandatory)][string]$ExpectedInstallLocation
    )

    $registrations = @(Get-InnoProductRegistrations -ProductKey $ProductKey)
    if ($registrations.Count -ne 1) {
        throw "Expected exactly one $ProductKey registration; found $($registrations.Count)."
    }
    $registration = $registrations[0]
    if ($registration.Hive -ne [Microsoft.Win32.RegistryHive]::LocalMachine -or
        $registration.View -ne [Microsoft.Win32.RegistryView]::Registry64) {
        throw "Expected $ProductKey in HKLM 64-bit view; found $($registration.Hive)/$($registration.View)."
    }
    $expected = [IO.Path]::GetFullPath($ExpectedInstallLocation).TrimEnd('\')
    $actual = [IO.Path]::GetFullPath([string]$registration.InstallLocation).TrimEnd('\')
    if (!$actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer registration path mismatch: expected '$expected', found '$actual'."
    }
}

function Assert-GnuCashRegistryView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedInstallLocation)

    $expected = [IO.Path]::GetFullPath($ExpectedInstallLocation).TrimEnd('\')
    $values = @()
    foreach ($view in @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )) {
        $base_key = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $key = $base_key.OpenSubKey('Software\GnuCash')
            if ($key) {
                try {
                    $values += [pscustomobject]@{
                        View = $view
                        InstallationDirectory = $key.GetValue('InstallationDirectory')
                    }
                }
                finally {
                    $key.Dispose()
                }
            }
        }
        finally {
            $base_key.Dispose()
        }
    }
    if ($values.Count -ne 1 -or $values[0].View -ne [Microsoft.Win32.RegistryView]::Registry64) {
        throw "Expected the GnuCash application registry key only in the 64-bit HKLM view."
    }
    $actual = [IO.Path]::GetFullPath([string]$values[0].InstallationDirectory).TrimEnd('\')
    if (!$actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "GnuCash registry path mismatch: expected '$expected', found '$actual'."
    }
}

function Get-PeMachine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Not a DOS/PE image: $Path"
        }
        $stream.Position = 0x3C
        $pe_offset = $reader.ReadUInt32()
        if ($pe_offset -gt ($stream.Length - 6)) {
            throw "Invalid PE header offset in $Path"
        }
        $stream.Position = $pe_offset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Missing PE signature in $Path"
        }
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Assert-Amd64ApplicationPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$MainExecutable = 'bin\gnucash.exe'
    )

    $bin = Join-Path $Root 'bin'
    $lib = Join-Path $Root 'lib'
    $main = Join-Path $Root $MainExecutable
    foreach ($required in @($bin, $lib)) {
        if (!(Test-Path -LiteralPath $required -PathType Container)) {
            throw "Required application/runtime directory is missing: $required"
        }
    }
    if (!(Test-Path -LiteralPath $main -PathType Leaf)) {
        throw "Required main application executable is missing: $main"
    }
    $binaries = @(
        Get-ChildItem -LiteralPath $bin -File -Recurse -ErrorAction Stop |
            Where-Object { $_.Extension -in '.exe', '.dll' }
        Get-ChildItem -LiteralPath $lib -File -Recurse -Filter '*.dll' -ErrorAction Stop
    )
    if ($binaries.Count -eq 0) {
        throw "No application/runtime PE files found under $Root."
    }
    $wrong_machine = @($binaries | Where-Object { (Get-PeMachine -Path $_.FullName) -ne 0x8664 })
    if ($wrong_machine.Count -ne 0) {
        throw "Non-AMD64 application/runtime PE files found:`n$($wrong_machine.FullName -join "`n")"
    }
    return [pscustomobject]@{
        FilesChecked = $binaries.Count
        MainExecutable = $main
    }
}

Export-ModuleMember -Function @(
    'Get-InnoProductRegistrations',
    'Get-ProgramFiles64',
    'Assert-InnoProductNotRegistered',
    'Assert-InnoProductRegistration',
    'Assert-GnuCashRegistryView',
    'Get-PeMachine',
    'Assert-Amd64ApplicationPayload'
)
