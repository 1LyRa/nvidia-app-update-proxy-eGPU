[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$packageParent = Join-Path $artifactsRoot 'package'

& (Join-Path $PSScriptRoot 'Assert-SemVer.ps1') -Version $Version |
    Out-Null

$package = (Resolve-Path -LiteralPath $PackagePath).Path
$packagePrefix = [IO.Path]::GetFullPath($packageParent).TrimEnd('\') + '\'
if (-not $package.StartsWith(
    $packagePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Package must be below the repository artifacts directory: $package"
}

$maintenanceRelativePaths = @(
    'AutoRepair-NvidiaAppOculinkShim.ps1',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1',
    'payload\NvidiaAppOculinkShim.exe'
)

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Manifest-Version: 1')
$lines.Add("# Package-Version: $Version")
$lines.Add('# Runtime-Identifier: win-x64')
foreach ($relative in $maintenanceRelativePaths) {
    $candidate = Join-Path $package $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Required maintenance file is missing: $relative"
    }
    $item = Get-Item -LiteralPath $candidate -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Maintenance files cannot be reparse points: $relative"
    }
    $hash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    $lines.Add("# File-SHA256: $hash  $($item.Length)  $relative")
}

$manifestPath = Join-Path $package 'MaintenanceManifest.ps1'
[IO.File]::WriteAllLines(
    $manifestPath,
    $lines,
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Manifest = $manifestPath
    PackageVersion = $Version
    RuntimeIdentifier = 'win-x64'
    Files = $maintenanceRelativePaths.Count
} | Format-List
