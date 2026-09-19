[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$InstallerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# HTML Help Workshop 1.3 is no longer distributed by Microsoft. GnuCash's
# documentation instructions retain this fixed capture of Microsoft's installer.
$html_help_workshop_url = 'https://web.archive.org/web/20160201063255id_/http://download.microsoft.com/download/0/A/9/0A939EF6-E31C-430F-A3DF-DFAE7960D564/htmlhelp.exe'
$html_help_workshop_sha256 = 'B2B3140D42A818870C1AB13C1C7B8D4536F22BD994FA90AADE89729A6009A3AE'

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'RUNNER_TEMP is required for the temporary HTML Help Workshop tool directory.'
}

$runner_temp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\', '/')
$output_directory = [IO.Path]::GetFullPath($OutputDirectory)
$runner_temp_prefix = $runner_temp + [IO.Path]::DirectorySeparatorChar
if (!$output_directory.StartsWith($runner_temp_prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "HTML Help Workshop output must be below RUNNER_TEMP: $output_directory"
}
if (Test-Path -LiteralPath $output_directory) {
    throw "Refusing to reuse an existing HTML Help Workshop output directory: $output_directory"
}

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $runner_temp 'html-help-workshop-1.3.exe'
    Invoke-WebRequest -Uri $html_help_workshop_url -OutFile $InstallerPath -MaximumRedirection 5
}

if (!(Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "HTML Help Workshop installer was not found: $InstallerPath"
}

$actual_hash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash
if ($actual_hash -ne $html_help_workshop_sha256) {
    throw "Unexpected SHA-256 for HTML Help Workshop installer: $actual_hash"
}

$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
if ($signature.Status -ne 'Valid' -or !$signature.SignerCertificate -or
    $signature.SignerCertificate.Subject -notlike 'CN=Microsoft Corporation,*') {
    throw "HTML Help Workshop installer signature is not a valid Microsoft Corporation signature: $($signature.Status)"
}

$tar = Get-Command tar.exe -ErrorAction Stop
New-Item -ItemType Directory -Path $output_directory -ErrorAction Stop | Out-Null
& $tar.Source -xf $InstallerPath -C $output_directory
if ($LASTEXITCODE -ne 0) {
    throw "Could not extract HTML Help Workshop to $output_directory (exit code $LASTEXITCODE)."
}

foreach ($required_file in 'hhc.exe', 'itcc.dll', 'hha.dll') {
    $required_path = Join-Path $output_directory $required_file
    if (!(Test-Path -LiteralPath $required_path -PathType Leaf) -or
        (Get-Item -LiteralPath $required_path).Length -eq 0) {
        throw "HTML Help Workshop extraction is missing $required_file."
    }
}

Write-Output (Join-Path $output_directory 'hhc.exe')
