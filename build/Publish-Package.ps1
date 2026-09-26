[CmdletBinding()]
param(
    [string]$Version = '4.0.0',
    [switch]$SkipBuild,
    [switch]$IncludeInstallerBatchFiles
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$project =
    Join-Path $repositoryRoot 'src\NvidiaAppOculinkShim\NvidiaAppOculinkShim.csproj'
$launcherProject =
    Join-Path $repositoryRoot 'src\NvidiaAppOculinkLauncher\NvidiaAppOculinkLauncher.csproj'
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$publishRoot = Join-Path $artifactsRoot 'publish\win-x64'
$launcherPublishRoot = Join-Path $artifactsRoot 'publish\launcher-win-x64'
$packageName = "NvidiaAppOculinkUpdateBridge-$Version-win-x64"
$packageRoot = Join-Path $artifactsRoot (Join-Path 'package' $packageName)
$payloadRoot = Join-Path $packageRoot 'payload'
$archivePath = Join-Path $artifactsRoot ($packageName + '.zip')
$continuousIntegrationBuild =
    if ($env:GITHUB_ACTIONS -eq 'true') { 'true' } else { 'false' }
$packageProfile = if ($IncludeInstallerBatchFiles) {
    'installer-batch-preview'
} else {
    'native-launcher'
}

& (Join-Path $PSScriptRoot 'Assert-SemVer.ps1') -Version $Version |
    Out-Null

if (-not $SkipBuild) {
    if (Test-Path -LiteralPath $publishRoot) {
        $resolvedPublishRoot = (Resolve-Path -LiteralPath $publishRoot).Path
        $expectedPublishParent =
            (Join-Path $artifactsRoot 'publish').TrimEnd('\') + '\'
        if (-not $resolvedPublishRoot.StartsWith(
            $expectedPublishParent,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to replace unexpected publish directory: $resolvedPublishRoot"
        }
        Remove-Item -LiteralPath $resolvedPublishRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $launcherPublishRoot) {
        $resolvedLauncherPublishRoot =
            (Resolve-Path -LiteralPath $launcherPublishRoot).Path
        $expectedPublishParent =
            (Join-Path $artifactsRoot 'publish').TrimEnd('\') + '\'
        if (-not $resolvedLauncherPublishRoot.StartsWith(
            $expectedPublishParent,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw (
                'Refusing to replace unexpected launcher publish directory: ' +
                $resolvedLauncherPublishRoot
            )
        }
        Remove-Item `
            -LiteralPath $resolvedLauncherPublishRoot `
            -Recurse `
            -Force
    }

    dotnet publish $project `
        -c Release `
        -r win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:PublishTrimmed=false `
        -p:Version=$Version `
        -p:ContinuousIntegrationBuild=$continuousIntegrationBuild `
        -o $publishRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'dotnet publish failed.'
    }

    dotnet publish $launcherProject `
        -c Release `
        -p:Version=$Version `
        -p:ContinuousIntegrationBuild=$continuousIntegrationBuild `
        -o $launcherPublishRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Launcher publish failed.'
    }
}

$serviceBinary = Join-Path $publishRoot 'NvidiaAppOculinkShim.exe'
if (-not (Test-Path -LiteralPath $serviceBinary -PathType Leaf)) {
    throw "Published service binary is missing: $serviceBinary"
}
$launcherBinary =
    Join-Path $launcherPublishRoot 'NvidiaAppOculinkUpdateBridge.exe'
if (-not (Test-Path -LiteralPath $launcherBinary -PathType Leaf)) {
    throw "Published launcher binary is missing: $launcherBinary"
}
$launcherOutputs = @(Get-ChildItem -LiteralPath $launcherPublishRoot -File)
if (
    $launcherOutputs.Count -ne 1 -or
    $launcherOutputs[0].Name -ne 'NvidiaAppOculinkUpdateBridge.exe'
) {
    throw 'The NativeAOT launcher publish directory must contain exactly one EXE.'
}
$serviceProductVersion =
    [Diagnostics.FileVersionInfo]::GetVersionInfo($serviceBinary).ProductVersion
if (
    [string]::IsNullOrWhiteSpace($serviceProductVersion) -or
    $serviceProductVersion -ne $Version
) {
    throw (
        'The published service version does not match the package version. ' +
        'Build again without -SkipBuild.'
    )
}
$launcherProductVersion =
    [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherBinary).ProductVersion
if (
    [string]::IsNullOrWhiteSpace($launcherProductVersion) -or
    (
        $launcherProductVersion -ne $Version
    )
) {
    throw (
        'The published launcher version does not match the package version. ' +
        'Build again without -SkipBuild.'
    )
}
$launcherSelfTest = Start-Process `
    -FilePath $launcherBinary `
    -ArgumentList '--self-test' `
    -WorkingDirectory $launcherPublishRoot `
    -Wait `
    -PassThru
if ($launcherSelfTest.ExitCode -ne 0) {
    throw (
        'The published NativeAOT launcher self-test failed with exit code ' +
        $launcherSelfTest.ExitCode + '.'
    )
}

if (Test-Path -LiteralPath $packageRoot) {
    $resolved = (Resolve-Path -LiteralPath $packageRoot).Path
    $expectedParent =
        (Join-Path $artifactsRoot 'package').TrimEnd('\') + '\'
    if (-not $resolved.StartsWith(
        $expectedParent,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to replace unexpected package directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
Copy-Item -LiteralPath $serviceBinary -Destination $payloadRoot
Copy-Item -LiteralPath $launcherBinary -Destination $packageRoot
$installerFiles = @(
    'AutoRepair-NvidiaAppOculinkShim.ps1',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
foreach ($installerFile in $installerFiles) {
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot (Join-Path 'installer' $installerFile)) `
        -Destination $packageRoot
}
if ($IncludeInstallerBatchFiles) {
    $installerBatchRoot = Join-Path $packageRoot 'installer'
    New-Item -ItemType Directory -Path $installerBatchRoot -Force |
        Out-Null
    $installerBatchFiles = @(
        'Setup.cmd',
        'Status.cmd',
        'Uninstall-NvidiaAppOculinkShim.cmd'
    )
    foreach ($installerBatchFile in $installerBatchFiles) {
        Copy-Item `
            -LiteralPath (
                Join-Path `
                    $repositoryRoot `
                    (Join-Path 'installer' $installerBatchFile)
            ) `
            -Destination $installerBatchRoot
    }
    [IO.File]::WriteAllLines(
        (Join-Path $packageRoot 'UNSIGNED-PREVIEW.txt'),
        @(
            'UNSIGNED INSTALLER-BATCH PREVIEW',
            '',
            "Version: $Version",
            'This package is not Authenticode signed.',
            'The installer\*.cmd entry points bypass the signed NativeAOT maintenance trust boundary.',
            'Windows PowerShell, rather than this project, will appear in the UAC prompt.',
            'Review the scripts and verify the published ZIP SHA-256 before use.',
            'For setup or upgrade, open installer\Setup.cmd from a normal user session.',
            'Setup automatically selects a fresh install, v3 migration, or v4 repair.',
            'Use installer\Status.cmd for status and installer\Uninstall-NvidiaAppOculinkShim.cmd to uninstall.',
            'Do not redistribute this preview as a trusted or production-ready installer.'
        ),
        [Text.UTF8Encoding]::new($false)
    )
}
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot 'LICENSE') `
    -Destination $packageRoot
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot 'packaging\INSTALL.md') `
    -Destination $packageRoot

$sourceCommit = (
    git -c "safe.directory=$($repositoryRoot.Replace('\', '/'))" `
        -C $repositoryRoot rev-parse HEAD
).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[a-f0-9]{40}$') {
    throw 'Unable to determine the source Git commit.'
}
$dotnetSdk = (dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or $dotnetSdk -notmatch '^\d+\.\d+\.\d+') {
    throw 'Unable to determine the .NET SDK version.'
}
[IO.File]::WriteAllLines(
    (Join-Path $packageRoot 'BUILD-INFO.txt'),
    @(
        "Version: $Version",
        "Source-Commit: $sourceCommit",
        "Dotnet-SDK: $dotnetSdk",
        "Package-Profile: $packageProfile",
        'Service-Runtime: win-x64 self-contained',
        'Launcher-Runtime: Win11 x64 NativeAOT self-contained',
        "Installer-Batch-Files-Included: $($IncludeInstallerBatchFiles.ToString().ToLowerInvariant())",
        'Repository-Source-Included: false',
        'Maintainer-Documentation-Included: false',
        'Driver-Payloads-Included: false'
    ),
    [Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot 'New-MaintenanceManifest.ps1') `
    -PackagePath $packageRoot `
    -Version $Version |
    Out-Null
$packagedLauncher = Join-Path $packageRoot 'NvidiaAppOculinkUpdateBridge.exe'
$packageVerification = Start-Process `
    -FilePath $packagedLauncher `
    -ArgumentList '--verify-package' `
    -WorkingDirectory $packageRoot `
    -Wait `
    -PassThru
if ($packageVerification.ExitCode -ne 0) {
    throw (
        'The NativeAOT launcher rejected its unsigned package with exit code ' +
        $packageVerification.ExitCode + '.'
    )
}

& (Join-Path $PSScriptRoot 'Finalize-Package.ps1') `
    -PackagePath $packageRoot `
    -ArchivePath $archivePath `
    -IncludeInstallerBatchFiles:$IncludeInstallerBatchFiles
