$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (!$Condition) {
        throw $Message
    }
}

$repository_root = Split-Path -Parent $PSScriptRoot
$setup_script = Join-Path $repository_root 'setup-mingw64.ps1'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$test_root = Join-Path ([IO.Path]::GetTempPath()) ('setup-mingw64-' + [guid]::NewGuid())

function Invoke-SetupScript {
    param([string]$ScriptPath, [string[]]$ScriptArguments)

    $previous_error_action = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powershell -NoProfile -File $ScriptPath @ScriptArguments 2>&1
        $exit_code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous_error_action
    }
    [pscustomobject]@{
        ExitCode = $exit_code
        Output = $output -join "`n"
    }
}

try {
    New-Item -ItemType Directory -Path $test_root | Out-Null

    $invalid_target = Join-Path $test_root 'invalid-target'
    $invalid = Invoke-SetupScript -ScriptPath $setup_script -ScriptArguments @(
        '-mingw_arch', 'not-an-architecture', '-target_dir', $invalid_target
    )
    Assert-True ($invalid.ExitCode -ne 0) 'Unsupported architecture returned success.'
    Assert-True ($invalid.Output -match 'not-an-architecture is not supported\.') `
        'Unsupported architecture did not reach the product error path.'
    Assert-True (!(Test-Path -LiteralPath $invalid_target)) 'Unsupported architecture created a target directory.'

    $script_only_root = Join-Path $test_root 'script-only'
    New-Item -ItemType Directory -Path $script_only_root | Out-Null
    Copy-Item -LiteralPath $setup_script -Destination (Join-Path $script_only_root 'setup-mingw64.ps1')
    Copy-Item -LiteralPath (Join-Path $repository_root 'setup-mingw64.sh') `
        -Destination (Join-Path $script_only_root 'setup-mingw64.sh')
    $clang_target = Join-Path $test_root 'clang-target'
    $missing_recipes = Invoke-SetupScript -ScriptPath (Join-Path $script_only_root 'setup-mingw64.ps1') -ScriptArguments @(
        '-mingw_arch', 'clang64', '-target_dir', $clang_target
    )
    Assert-True ($missing_recipes.ExitCode -ne 0) 'clang64 without package recipes returned success.'
    Assert-True ($missing_recipes.Output -match 'requires package recipes') `
        'clang64 without recipes did not report the script-relative preflight error.'
    Assert-True (!(Test-Path -LiteralPath $clang_target)) 'Missing clang64 recipes caused bootstrap side effects.'

    $downloads = Join-Path $test_root 'downloads'
    New-Item -ItemType Directory -Path $downloads | Out-Null

    # Dot-sourcing reaches the product helper definitions but returns before
    # bootstrap side effects. The two replacements below exercise the actual
    # install-package path without a network transfer or child process.
    . $setup_script
    Assert-True ((quote-windows-command-line-argument '') -ceq '""') `
        'Windows command-line quoting did not preserve an empty argument.'
    Assert-True ((quote-windows-command-line-argument 'with space') -ceq '"with space"') `
        'Windows command-line quoting did not preserve spaces.'
    Assert-True ((quote-windows-command-line-argument 'alpha"beta') -ceq '"alpha\"beta"') `
        'Windows command-line quoting did not escape an embedded quote.'
    $backslashes_before_quote = 'alpha' + ('\' * 2) + '"beta'
    $expected_backslashes_before_quote = '"alpha' + ('\' * 5) + '"beta"'
    Assert-True ((quote-windows-command-line-argument $backslashes_before_quote) -ceq $expected_backslashes_before_quote) `
        'Windows command-line quoting did not double backslashes before a quote.'
    $trailing_backslashes = 'trailing' + ('\' * 2)
    $expected_trailing_backslashes = '"trailing' + ('\' * 4) + '"'
    Assert-True ((quote-windows-command-line-argument $trailing_backslashes) -ceq $expected_trailing_backslashes) `
        'Windows command-line quoting did not double trailing backslashes.'

    $download_dir = $downloads
    $script:curl_exit_code = 0
    $script:curl_output_paths = @()
    $script:curl_used_fail = $false
    $script:curl_used_location = $false
    $script:installer_exit_code = 0
    $script:installer_calls = 0
    function curl.exe {
        $script:curl_used_fail = $args -contains '--fail'
        $script:curl_used_location = $args -contains '--location'
        $output_index = [Array]::IndexOf($args, '--output')
        if ($output_index -lt 0) {
            throw 'curl stub did not receive an output path.'
        }
        $output_path = $args[$output_index + 1]
        $script:curl_output_paths += $output_path
        Set-Content -LiteralPath $output_path -Value 'fixture payload' -NoNewline
        $global:LASTEXITCODE = $script:curl_exit_code
    }
    function Start-SetupInstallerProcess {
        param([Diagnostics.ProcessStartInfo]$process_info)

        $script:installer_calls++
        $process = [pscustomobject]@{ ExitCode = $script:installer_exit_code }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
        return $process
    }

    $successful_download = Join-Path $downloads 'fixture-success.exe'
    $foreign_partial = "$successful_download.partial"
    Set-Content -LiteralPath $foreign_partial -Value 'foreign partial' -NoNewline
    install-package -url 'https://fixture.invalid/fixture-success.exe' -setup_args ''
    Assert-True (Test-Path -LiteralPath $successful_download -PathType Leaf) `
        'Successful download was not atomically published.'
    Assert-True ((Get-Content -LiteralPath $foreign_partial -Raw) -eq 'foreign partial') `
        'Download cleanup removed an unrelated partial file.'
    Assert-True $script:curl_used_fail 'Download did not request HTTP failure status from curl.'
    Assert-True $script:curl_used_location 'Download did not follow the configured redirect path.'

    $script:curl_exit_code = 22
    $failed_download = Join-Path $downloads 'fixture-failure.exe'
    $download_rejected = $false
    try {
        install-package -url 'https://fixture.invalid/fixture-failure.exe' -setup_args ''
    }
    catch {
        $download_rejected = $_.Exception.Message -match 'Downloading .* failed with exit code 22'
    }
    Assert-True $download_rejected 'HTTP/download failure was accepted.'
    Assert-True (!(Test-Path -LiteralPath $failed_download)) 'Partial download became a cache entry.'
    $failed_temporary_download = $script:curl_output_paths[-1]
    Assert-True ($failed_temporary_download -match '\.fixture-failure\.exe\.[0-9a-f]{32}\.partial$') `
        'Download did not use a unique temporary path.'
    Assert-True (!(Test-Path -LiteralPath $failed_temporary_download)) `
        'Failed download left its own temporary file behind.'

    $script:curl_exit_code = 0
    $script:installer_exit_code = 37
    $installer_rejected = $false
    try {
        install-package -url 'https://fixture.invalid/fixture-installer.exe' -setup_args ''
    }
    catch {
        $installer_rejected = $_.Exception.Message -match 'Installer .* failed with exit code 37'
    }
    Assert-True $installer_rejected 'Nonzero fixture installer exit was accepted.'
    Assert-True ($script:installer_calls -eq 2) 'Installer fixture did not run exactly for successful download and explicit installer failure.'

    $git_bash = 'C:\Program Files\Git\bin\bash.exe'
    Assert-True (Test-Path -LiteralPath $git_bash -PathType Leaf) 'Git Bash is required for the quoting fixture.'
    # Construct Unicode explicitly: Windows PowerShell reads BOM-less scripts
    # with the legacy ANSI encoding, unlike PowerShell 7.
    $space_root = Join-Path $test_root ('script root ' + [char]0x00FC)
    New-Item -ItemType Directory -Path $space_root | Out-Null
    $marker = Join-Path $space_root 'quoted-marker'
    $bash_path = $git_bash
    $space_root_unix = make-unixpath -path $space_root
    $marker_unix = make-unixpath -path $marker
    bash-command -command "test ""`$PATH"" = /usr/bin && cd ""$space_root_unix"" && printf quoted > ""$marker_unix"""
    Assert-True ((Get-Content -LiteralPath $marker -Raw) -eq 'quoted') `
        'Script-relative Bash command failed for a path containing spaces.'

    $failed_command_marker = Join-Path $space_root 'unexpected-after-failure'
    $failed_command_marker_unix = make-unixpath -path $failed_command_marker
    $command_rejected = $false
    try {
        bash-command -command "false; printf unexpected > ""$failed_command_marker_unix"""
    }
    catch {
        $command_rejected = $_.Exception.Message -match 'Shell command failed with exit code 1:'
    }
    Assert-True $command_rejected 'Bash continued after a failed command.'
    Assert-True (!(Test-Path -LiteralPath $failed_command_marker)) `
        'Bash executed a command after an earlier failure.'

    $source_root = Join-Path $test_root ('source root ' + [char]0x00E4)
    $destination_root = Join-Path $test_root ('destination root ' + [char]0x00F6)
    New-Item -ItemType Directory -Path $source_root, $destination_root | Out-Null
    $source_file = Join-Path $source_root 'htmlhelp.h'
    $destination_file = Join-Path $destination_root 'htmlhelp.h'
    Set-Content -LiteralPath $source_file -Value 'fixture header' -NoNewline
    $source_file_unix = make-unixpath -path $source_file
    $destination_root_unix = make-unixpath -path $destination_root
    bash-command -command "cp ""$source_file_unix"" ""$destination_root_unix"""
    Assert-True ((Get-Content -LiteralPath $destination_file -Raw) -eq 'fixture header') `
        'Bash cp failed for source and destination paths containing spaces.'
}
finally {
    if (Test-Path -LiteralPath $test_root) {
        $resolved_root = (Resolve-Path -LiteralPath $test_root).Path
        $expected_root = [IO.Path]::GetFullPath($test_root)
        $expected_parent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($test_root))
        $root_prefix = $expected_parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $is_expected_root = [string]::Equals(
            [IO.Path]::GetFullPath($resolved_root), $expected_root,
            [StringComparison]::OrdinalIgnoreCase)
        $is_owned_guid_root = [IO.Path]::GetFileName($resolved_root) -match '(?i)^setup-mingw64-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        if (!$is_expected_root -or
            ![IO.Path]::GetFullPath($resolved_root).StartsWith($root_prefix, [StringComparison]::OrdinalIgnoreCase) -or
            !$is_owned_guid_root) {
            throw "Refusing to clean unexpected fixture directory: $resolved_root"
        }
        Remove-Item -LiteralPath $resolved_root -Recurse -Force
    }
}

exit 0
