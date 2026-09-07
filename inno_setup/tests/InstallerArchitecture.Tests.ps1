[CmdletBinding()]
param(
    [string]$InnoCompiler,
    [switch]$RunInstallerFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$architecture_module = (Resolve-Path (Join-Path $PSScriptRoot '..\InstallerArchitecture.psm1')).Path
Import-Module $architecture_module -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function Assert-X64IncludeContent {
    param([Parameter(Mandatory)][string]$Content)

    $allowed = @([regex]::Matches($Content, '(?m)^ArchitecturesAllowed=x64compatible\s*$'))
    $mode = @([regex]::Matches($Content, '(?m)^ArchitecturesInstallIn64BitMode=x64compatible\s*$'))
    Assert-True ($allowed.Count -eq 1) 'Expected one x64-compatible architecture restriction.'
    Assert-True ($mode.Count -eq 1) 'Expected one x64-compatible 64-bit install-mode directive.'
}

function Assert-PreviousInstallLookupContent {
    param([Parameter(Mandatory)][string]$Content)

    foreach ($root in @('HKLM64', 'HKLM32', 'HKCU')) {
        Assert-True ($Content -match "TryGetPrevInstallInfo\($root\)") `
            "Previous-install lookup does not inspect $root."
    }
    Assert-True ($Content -match "and \(PrevUninstallString <> ''\)") `
        'An empty UninstallString must not stop the cross-view lookup.'
    Assert-True ($Content -match '(?s)Exec\(UninstallExecutable.*?ResultCode\) and \(ResultCode = 0\)') `
        'Previous uninstall success no longer requires process exit code zero.'
    Assert-True ($Content -match "GetPrevInstallInfo;\s+if PrevUninstallString = '' then\s+Result := 3") `
        'Previous uninstall success no longer verifies registration removal.'
    Assert-True ($Content -match 'if CurStep = ssInstall then begin\s+if UninstallRequired then begin\s+if UnInstallOldVersion\(\) <> 3 then\s+RaiseException') `
        'A failed previous-version uninstall no longer stops setup.'
}

function Assert-ProductionRecipe {
    $recipe = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\gnucash-mingw64.iss') -Raw
    Assert-True ($recipe -match '(?m)^DefaultDirName=\{autopf\}\\@PACKAGE@\s*$') `
        'The production default directory is not based on {autopf}.'
    Assert-True ($recipe -match '(?m)^UsePreviousAppDir=yes\s*$') `
        'The production recipe no longer preserves a previous user-selected directory.'
    Assert-True ($recipe -match '(?m)^#include "@GC_WIN_REPOS_DIR@\\inno_setup\\WindowsX64Setup\.issinc"\s*$') `
        'The production recipe does not consume the central x64 setup fragment.'
    Assert-True ($recipe -match '(?m)^#include "@GC_WIN_REPOS_DIR@\\inno_setup\\PreviousInstall\.issinc"\s*$') `
        'The production recipe does not consume the central previous-install lookup.'
}

function New-PeFixture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][UInt16]$Machine
    )

    $bytes = [byte[]]::new(512)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([UInt32]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x84)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-InnoCompiler {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Recipe
    )

    $stdout = "$Recipe.stdout.log"
    $stderr = "$Recipe.stderr.log"
    $process = Start-Process -FilePath $Compiler -ArgumentList @('/Q', "`"$Recipe`"") `
        -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        $output = @(
            if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw }
            if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw }
        ) -join [Environment]::NewLine
        throw "Inno fixture compilation failed with exit code $($process.ExitCode): $output"
    }
}

function Invoke-InstallerProcess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if (!$AllowFailure -and $process.ExitCode -ne 0) {
        throw "Installer fixture failed with exit code $($process.ExitCode): $Path"
    }
    return $process.ExitCode
}

function Remove-RegistryFixture {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryView]$View,
        [Parameter(Mandatory)][string]$Subkey
    )

    $base_key = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $base_key.DeleteSubKeyTree($Subkey, $false)
    }
    finally {
        $base_key.Dispose()
    }
}

function Set-RegistryFixture {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory)][Microsoft.Win32.RegistryView]$View,
        [Parameter(Mandatory)][string]$Subkey,
        [Parameter(Mandatory)][string]$UninstallString,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $base_key = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $key = $base_key.CreateSubKey($Subkey)
        try {
            $key.SetValue('UninstallString', $UninstallString)
            $key.SetValue('DisplayName', $DisplayName)
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $base_key.Dispose()
    }
}

function Test-InstalledArchitectureFixture {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ArchitectureInclude
    )

    $fixture_id = 'GnuCashArchitectureFixture' + [guid]::NewGuid().ToString('N')
    $product_key = "${fixture_id}_is1"
    $expected_install = Join-Path (Get-ProgramFiles64) $fixture_id
    $output = Join-Path $Root 'architecture-output'
    $payload = Join-Path $Root 'architecture-payload'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    New-PeFixture -Path (Join-Path $payload 'bin\fixture.exe') -Machine 0x8664
    New-PeFixture -Path (Join-Path $payload 'lib\fixture.dll') -Machine 0x8664
    $recipe = Join-Path $Root 'architecture-fixture.iss'
    $content = @"
[Setup]
AppName=$fixture_id
AppId=$fixture_id
AppVersion=1
DefaultDirName={autopf}\$fixture_id
UsePreviousAppDir=yes
#include "$ArchitectureInclude"
PrivilegesRequired=admin
OutputDir=$output
OutputBaseFilename=architecture-fixture
UninstallFilesDir={app}\uninstall

[Files]
Source: "$payload\bin\fixture.exe"; DestDir: "{app}\bin"
Source: "$payload\lib\fixture.dll"; DestDir: "{app}\lib"
"@
    [IO.File]::WriteAllText($recipe, $content, [Text.UTF8Encoding]::new($true))

    Assert-InnoProductNotRegistered -ProductKey $product_key
    Assert-True (!(Test-Path -LiteralPath $expected_install)) `
        "Refusing to reuse an existing fixture directory: $expected_install"
    $installed = $false
    try {
        Invoke-InnoCompiler -Compiler $Compiler -Recipe $recipe
        $installer = Join-Path $output 'architecture-fixture.exe'
        Invoke-InstallerProcess -Path $installer -Arguments @(
            '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        ) | Out-Null
        $installed = $true
        Assert-True (Test-Path -LiteralPath (Join-Path $expected_install 'bin\fixture.exe')) `
            'The fixture did not use the 64-bit {autopf} default directory.'
        Assert-InnoProductRegistration -ProductKey $product_key -ExpectedInstallLocation $expected_install
        Assert-Amd64ApplicationPayload -Root $expected_install `
            -MainExecutable 'bin\fixture.exe' | Out-Null
    }
    finally {
        if ($installed) {
            $uninstaller = Get-ChildItem -LiteralPath (Join-Path $expected_install 'uninstall') `
                -File -Filter 'unins*.exe' | Select-Object -First 1
            if ($uninstaller) {
                Invoke-InstallerProcess -Path $uninstaller.FullName -Arguments @(
                    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
                ) | Out-Null
            }
        }
    }
    Assert-InnoProductNotRegistered -ProductKey $product_key
    Assert-True (!(Test-Path -LiteralPath $expected_install)) `
        'The fixture uninstaller left its default installation directory behind.'
}

function Test-InnoCompileFixture {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ArchitectureInclude,
        [Parameter(Mandatory)][string]$PreviousInstallInclude
    )

    $output = Join-Path $Root 'compile-output'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $recipe = Join-Path $Root 'compile-fixture.iss'
    $content = @"
#define PreviousInstallUninstallKey "Software\Fixture\Uninstall"
#define PreviousInstallVersionKey "Software\Fixture\Version"

[Setup]
AppName=GnuCash architecture compile fixture
AppId=GnuCashArchitectureCompileFixture
AppVersion=1
DefaultDirName={tmp}\GnuCashArchitectureCompileFixture
#include "$ArchitectureInclude"
PrivilegesRequired=admin
OutputDir=$output
OutputBaseFilename=compile-fixture
Uninstallable=no

[Code]
var
  PrevAppName, PrevUninstallString: String;
  PrevVersionMajor, PrevVersionMinor, PrevVersionMicro: Cardinal;
  UninstallRequired: Boolean;

#include "$PreviousInstallInclude"

function InitializeSetup(): Boolean;
begin
  GetPrevInstallInfo;
  Result := True;
end;
"@
    [IO.File]::WriteAllText($recipe, $content, [Text.UTF8Encoding]::new($true))
    Invoke-InnoCompiler -Compiler $Compiler -Recipe $recipe
}

function Test-PreviousInstallRegistryViews {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ArchitectureInclude,
        [Parameter(Mandatory)][string]$PreviousInstallInclude
    )

    $fixture_id = 'GnuCashPreviousInstallFixture' + [guid]::NewGuid().ToString('N')
    $uninstall_key = "Software\Microsoft\Windows\CurrentVersion\Uninstall\${fixture_id}_legacy"
    $version_key = "Software\${fixture_id}\Version"
    $output = Join-Path $Root 'lookup-output'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $recipe = Join-Path $Root 'lookup-fixture.iss'
    $content = @"
#define PreviousInstallUninstallKey "$uninstall_key"
#define PreviousInstallVersionKey "$version_key"

[Setup]
AppName=$fixture_id
AppId=$fixture_id
AppVersion=1
DefaultDirName={tmp}\$fixture_id
#include "$ArchitectureInclude"
PrivilegesRequired=admin
OutputDir=$output
OutputBaseFilename=lookup-fixture
Uninstallable=no

[Code]
var
  PrevAppName, PrevUninstallString: String;
  PrevVersionMajor, PrevVersionMinor, PrevVersionMicro: Cardinal;
  UninstallRequired: Boolean;

#include "$PreviousInstallInclude"

function InitializeSetup(): Boolean;
var
  ProbeOutput: String;
begin
  GetPrevInstallInfo;
  ProbeOutput := ExpandConstant('{param:ProbeOutput}');
  SaveStringToFile(ProbeOutput, PrevUninstallString + #13#10 + PrevAppName, False);
  Result := False;
end;
"@
    [IO.File]::WriteAllText($recipe, $content, [Text.UTF8Encoding]::new($true))
    Invoke-InnoCompiler -Compiler $Compiler -Recipe $recipe
    $installer = Join-Path $output 'lookup-fixture.exe'

    $cases = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
    )
    foreach ($case in $cases) {
        $name = "$($case.Hive)-$($case.View)"
        $uninstall_string = "C:\fixture\$name\unins000.exe"
        $probe = Join-Path $Root "$name.txt"
        try {
            Set-RegistryFixture -Hive $case.Hive -View $case.View -Subkey $uninstall_key `
                -UninstallString $uninstall_string -DisplayName $name
            $guard_rejected = $false
            try {
                Assert-InnoProductNotRegistered -ProductKey "${fixture_id}_legacy"
            }
            catch {
                $guard_rejected = $_.Exception.Message -match 'Refusing to run an installer preflight'
            }
            Assert-True $guard_rejected "Existing-product guard did not reject $name."
            $exit_code = Invoke-InstallerProcess -Path $installer -Arguments @(
                '/SP-', '/SILENT', '/SUPPRESSMSGBOXES', "/ProbeOutput=`"$probe`""
            ) -AllowFailure
            Assert-True ($exit_code -eq 1) `
                "Lookup probe returned $exit_code instead of the Inno initialization-abort exit code 1."
            $detected = Get-Content -LiteralPath $probe
            Assert-True ($detected[0] -eq $uninstall_string -and $detected[1] -eq $name) `
                "Production lookup did not detect $name."
        }
        finally {
            Remove-RegistryFixture -Hive $case.Hive -View $case.View -Subkey $uninstall_key
        }
    }
}

function Test-PreviousUninstallContract {
    param(
        [Parameter(Mandatory)][string]$Compiler,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ArchitectureInclude,
        [Parameter(Mandatory)][string]$PreviousInstallInclude
    )

    $fixture_id = 'GnuCashUninstallFixture' + [guid]::NewGuid().ToString('N')
    $legacy_app_id = "${fixture_id}_legacy"
    $legacy_product_key = "${legacy_app_id}_is1"
    $legacy_uninstall_key = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$legacy_product_key"
    $version_key = "Software\${fixture_id}\Version"
    $output = Join-Path $Root 'uninstall-output'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $marker_source = Join-Path $Root 'new-payload.marker'
    [IO.File]::WriteAllText($marker_source, 'new payload')

    $success_helper_recipe = Join-Path $Root 'success-helper.iss'
    [IO.File]::WriteAllText($success_helper_recipe, @"
[Setup]
AppName=$fixture_id success helper
AppId=${fixture_id}_success_helper
AppVersion=1
DefaultDirName={tmp}\${fixture_id}_success_helper
PrivilegesRequired=admin
CreateAppDir=no
Uninstallable=no
OutputDir=$output
OutputBaseFilename=success-helper
"@, [Text.UTF8Encoding]::new($true))
    Invoke-InnoCompiler -Compiler $Compiler -Recipe $success_helper_recipe
    $success_helper = Join-Path $output 'success-helper.exe'
    $helper_exit = Invoke-InstallerProcess -Path $success_helper -Arguments @(
        '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
    ) -AllowFailure
    Assert-True ($helper_exit -eq 0) `
        "Registration-preserving helper returned $helper_exit instead of success."

    $failure_helper_recipe = Join-Path $Root 'failure-helper.iss'
    [IO.File]::WriteAllText($failure_helper_recipe, @"
[Setup]
AppName=$fixture_id failure helper
AppId=${fixture_id}_failure_helper
AppVersion=1
DefaultDirName={tmp}\${fixture_id}_failure_helper
PrivilegesRequired=admin
CreateAppDir=no
Uninstallable=no
OutputDir=$output
OutputBaseFilename=failure-helper

[Code]
function InitializeSetup(): Boolean;
begin
  Result := False;
end;
"@, [Text.UTF8Encoding]::new($true))
    Invoke-InnoCompiler -Compiler $Compiler -Recipe $failure_helper_recipe
    $failure_helper = Join-Path $output 'failure-helper.exe'
    $helper_exit = Invoke-InstallerProcess -Path $failure_helper -Arguments @(
        '/SP-', '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
    ) -AllowFailure
    Assert-True ($helper_exit -eq 1) `
        "Failure helper returned $helper_exit instead of initialization error 1."

    $upgrade_recipe = Join-Path $Root 'upgrade-fixture.iss'
    [IO.File]::WriteAllText($upgrade_recipe, @"
#define PreviousInstallUninstallKey "$legacy_uninstall_key"
#define PreviousInstallVersionKey "$version_key"

[Setup]
AppName=$fixture_id upgrade
AppId=${fixture_id}_upgrade
AppVersion=1
DefaultDirName={tmp}\${fixture_id}_upgrade
#include "$ArchitectureInclude"
PrivilegesRequired=admin
OutputDir=$output
OutputBaseFilename=upgrade-fixture
Uninstallable=no

[Files]
Source: "$marker_source"; DestDir: "{app}"

[Code]
var
  PrevAppName, PrevUninstallString: String;
  PrevVersionMajor, PrevVersionMinor, PrevVersionMicro: Cardinal;
  UninstallRequired: Boolean;

#include "$PreviousInstallInclude"

procedure InitializeWizard;
begin
  CheckUninstallRequired;
end;
"@, [Text.UTF8Encoding]::new($true))
    Invoke-InnoCompiler -Compiler $Compiler -Recipe $upgrade_recipe
    $upgrade_installer = Join-Path $output 'upgrade-fixture.exe'

    $legacy_root = Join-Path $Root 'legacy-install'
    $legacy_marker = Join-Path $Root 'legacy.marker'
    [IO.File]::WriteAllText($legacy_marker, 'legacy payload')
    $legacy_recipe = Join-Path $Root 'legacy-fixture.iss'
    [IO.File]::WriteAllText($legacy_recipe, @"
[Setup]
AppName=$fixture_id legacy
AppId=$legacy_app_id
AppVersion=1
DefaultDirName={tmp}\$legacy_app_id
PrivilegesRequired=admin
OutputDir=$output
OutputBaseFilename=legacy-fixture

[Files]
Source: "$legacy_marker"; DestDir: "{app}"
"@, [Text.UTF8Encoding]::new($true))
    $legacy_uninstaller = $null
    try {
      Invoke-InnoCompiler -Compiler $Compiler -Recipe $legacy_recipe
      Invoke-InstallerProcess -Path (Join-Path $output 'legacy-fixture.exe') -Arguments @(
        '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$legacy_root`""
      ) | Out-Null
      $legacy_uninstaller = Get-ChildItem -LiteralPath $legacy_root -File -Filter 'unins*.exe' |
          Select-Object -First 1
    $legacy_registration = @(Get-InnoProductRegistrations -ProductKey $legacy_product_key)
    Assert-True ($legacy_registration.Count -eq 1 -and
        $legacy_registration[0].Hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine -and
        $legacy_registration[0].View -eq [Microsoft.Win32.RegistryView]::Registry32) `
        'The legacy fixture was not registered in the 32-bit HKLM view.'

    $success_target = Join-Path $Root 'upgrade-success'
    Invoke-InstallerProcess -Path $upgrade_installer -Arguments @(
        '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$success_target`""
    ) | Out-Null
    Assert-InnoProductNotRegistered -ProductKey $legacy_product_key
    Assert-True (Test-Path -LiteralPath (Join-Path $success_target 'new-payload.marker')) `
        'The new payload was not installed after a verified successful legacy uninstall.'

    $negative_cases = @(
        @{ Name = 'nonzero-exit'; Helper = $failure_helper },
        @{ Name = 'registration-remains'; Helper = $success_helper }
    )
      foreach ($case in $negative_cases) {
        $target = Join-Path $Root "upgrade-$($case.Name)"
        $log = Join-Path $Root "upgrade-$($case.Name).log"
        try {
            Set-RegistryFixture -Hive ([Microsoft.Win32.RegistryHive]::LocalMachine) `
                -View ([Microsoft.Win32.RegistryView]::Registry32) -Subkey $legacy_uninstall_key `
                -UninstallString "`"$($case.Helper)`"" -DisplayName $case.Name
            $guard_rejected = $false
            try {
                Assert-InnoProductNotRegistered -ProductKey $legacy_product_key
            }
            catch {
                $guard_rejected = $_.Exception.Message -match 'Refusing to run an installer preflight'
            }
            Assert-True $guard_rejected "Existing-product guard did not reject $($case.Name)."
            $exit_code = Invoke-InstallerProcess -Path $upgrade_installer -Arguments @(
                '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
                "/DIR=`"$target`"", "/LOG=`"$log`""
            ) -AllowFailure
            Assert-True ($exit_code -ne 0) `
                "Upgrade unexpectedly succeeded for $($case.Name)."
            Assert-True (!(Test-Path -LiteralPath (Join-Path $target 'new-payload.marker'))) `
                "Upgrade wrote the new payload after $($case.Name)."
            $log_content = Get-Content -LiteralPath $log -Raw
            Assert-True ($log_content -match 'previous GnuCash installation could not be removed') `
                "Upgrade log lacks the production abort reason for $($case.Name)."
        }
        finally {
            Remove-RegistryFixture -Hive ([Microsoft.Win32.RegistryHive]::LocalMachine) `
                -View ([Microsoft.Win32.RegistryView]::Registry32) -Subkey $legacy_uninstall_key
        }
      }
    }
    finally {
        if ($legacy_uninstaller -and (Test-Path -LiteralPath $legacy_uninstaller.FullName)) {
            Invoke-InstallerProcess -Path $legacy_uninstaller.FullName -Arguments @(
                '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
            ) -AllowFailure | Out-Null
        }
        Remove-RegistryFixture -Hive ([Microsoft.Win32.RegistryHive]::LocalMachine) `
            -View ([Microsoft.Win32.RegistryView]::Registry32) -Subkey $legacy_uninstall_key
    }
}

$test_root = Join-Path ([IO.Path]::GetTempPath()) ('installer-architecture-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $test_root | Out-Null
$resolved_test_root = (Resolve-Path -LiteralPath $test_root).Path
$architecture_include = (Resolve-Path (Join-Path $PSScriptRoot '..\WindowsX64Setup.issinc')).Path
$previous_include = (Resolve-Path (Join-Path $PSScriptRoot '..\PreviousInstall.issinc')).Path

try {
    Assert-ProductionRecipe
    $architecture_content = Get-Content -LiteralPath $architecture_include -Raw
    Assert-X64IncludeContent -Content $architecture_content
    $architecture_regression_rejected = $false
    try {
        Assert-X64IncludeContent -Content ($architecture_content.Replace(
            'ArchitecturesInstallIn64BitMode=x64compatible',
            'ArchitecturesInstallIn64BitMode=x86compatible'))
    }
    catch {
        $architecture_regression_rejected = $true
    }
    Assert-True $architecture_regression_rejected 'The negative 32-bit install-mode mutation was not rejected.'
    Write-Host 'production architecture recipe and negative mutation: passed'

    $previous_content = Get-Content -LiteralPath $previous_include -Raw
    Assert-PreviousInstallLookupContent -Content $previous_content
    $lookup_regression_rejected = $false
    try {
        Assert-PreviousInstallLookupContent -Content ($previous_content.Replace(
            'if TryGetPrevInstallInfo(HKLM32) then',
            'if False then'))
    }
    catch {
        $lookup_regression_rejected = $true
    }
    Assert-True $lookup_regression_rejected 'The missing 32-bit HKLM lookup mutation was not rejected.'
    Write-Host 'cross-view previous-install lookup and negative mutation: passed'

    $pe_root = Join-Path $test_root 'pe'
    $amd64 = Join-Path $pe_root 'bin\amd64.exe'
    $x86 = Join-Path $pe_root 'bin\x86.exe'
    New-PeFixture -Path $amd64 -Machine 0x8664
    New-PeFixture -Path (Join-Path $pe_root 'lib\amd64.dll') -Machine 0x8664
    Assert-True ((Get-PeMachine -Path $amd64) -eq 0x8664) 'AMD64 PE machine was not read correctly.'
    Assert-Amd64ApplicationPayload -Root $pe_root -MainExecutable 'bin\amd64.exe' | Out-Null
    New-PeFixture -Path $x86 -Machine 0x014C
    $x86_rejected = $false
    try {
        Assert-Amd64ApplicationPayload -Root $pe_root -MainExecutable 'bin\amd64.exe' | Out-Null
    }
    catch {
        $x86_rejected = $_.Exception.Message -match [regex]::Escape($x86)
    }
    Assert-True $x86_rejected 'The negative x86 application payload was not rejected.'
    Write-Host 'PE machine parser and negative x86 payload: passed'

    $absent_product = 'GnuCashAbsentFixture' + [guid]::NewGuid().ToString('N') + '_is1'
    Assert-InnoProductNotRegistered -ProductKey $absent_product
    Write-Host 'machine dual-view and current-user existing-product preflight guard: passed'

    if ($InnoCompiler) {
        Assert-True (Test-Path -LiteralPath $InnoCompiler -PathType Leaf) `
            "Inno compiler not found: $InnoCompiler"
        Test-InnoCompileFixture -Compiler $InnoCompiler -Root $test_root `
            -ArchitectureInclude $architecture_include -PreviousInstallInclude $previous_include
        Write-Host 'Inno 6 production include compile fixture: passed'
    }

    if ($RunInstallerFixtures) {
        Assert-True (![string]::IsNullOrWhiteSpace($InnoCompiler)) `
            '-RunInstallerFixtures requires -InnoCompiler.'
        Test-InstalledArchitectureFixture -Compiler $InnoCompiler -Root $test_root `
            -ArchitectureInclude $architecture_include
        Write-Host 'compiled default-path, registry-view and AMD64 fixture: passed'
        Test-PreviousInstallRegistryViews -Compiler $InnoCompiler -Root $test_root `
            -ArchitectureInclude $architecture_include -PreviousInstallInclude $previous_include
        Write-Host 'compiled machine dual-view and current-user lookup fixtures: passed'
        Test-PreviousUninstallContract -Compiler $InnoCompiler -Root $test_root `
            -ArchitectureInclude $architecture_include -PreviousInstallInclude $previous_include
        Write-Host 'verified legacy uninstall success and payload-blocking failure fixtures: passed'
    }
}
finally {
    $cleanup_target = (Resolve-Path -LiteralPath $test_root).Path
    $temp_root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($cleanup_target -ne $resolved_test_root -or !$cleanup_target.StartsWith($temp_root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test directory: $cleanup_target"
    }
    Remove-Item -LiteralPath $cleanup_target -Recurse -Force
}

Write-Host 'Installer architecture tests passed.'
exit 0
