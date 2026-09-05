[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceDirectory,
    [Parameter(Mandatory)]
    [string]$TargetDirectory,
    [Parameter(Mandatory)]
    [string]$CompilerPath,
    [Parameter(Mandatory)]
    [string]$GSettingsPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GSettingsSchemas.psm1') -Force

Install-GSettingsSchemas `
    -SourceDirectory $SourceDirectory `
    -TargetDirectory $TargetDirectory `
    -CompilerPath $CompilerPath `
    -GSettingsPath $GSettingsPath
