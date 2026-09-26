[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$ArchivePath,
    [switch]$RequireSignature,
    [switch]$RequireTimestamp,
    [switch]$IncludeInstallerBatchFiles,
    [string]$UntrustedTestRootCertificatePath,
    [string]$ExpectedTestSignerThumbprint
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$packageParent = Join-Path $artifactsRoot 'package'
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$packagePrefix = [IO.Path]::GetFullPath($packageParent).TrimEnd('\') + '\'
if (-not $package.StartsWith(
    $packagePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Package must be below the repository artifacts directory: $package"
}

$packageLeaf = Split-Path -Leaf $package
$expectedArchive =
    [IO.Path]::GetFullPath((Join-Path $artifactsRoot ($packageLeaf + '.zip')))
$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not $archive.Equals(
    $expectedArchive,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Unexpected archive path: $archive"
}
$archiveHashPath = $archive + '.sha256'
$useUntrustedTestRoot =
    -not [string]::IsNullOrWhiteSpace($UntrustedTestRootCertificatePath)
$hasExpectedTestSigner =
    -not [string]::IsNullOrWhiteSpace($ExpectedTestSignerThumbprint)
if ($useUntrustedTestRoot -ne $hasExpectedTestSigner) {
    throw (
        'UntrustedTestRootCertificatePath and ExpectedTestSignerThumbprint ' +
        'must be supplied together.'
    )
}
$normalizedExpectedTestSigner = if ($hasExpectedTestSigner) {
    ($ExpectedTestSignerThumbprint -replace '\s', '').ToUpperInvariant()
} else {
    $null
}
if (
    $hasExpectedTestSigner -and
    $normalizedExpectedTestSigner -notmatch '^[A-F0-9]{40}$'
) {
    throw 'ExpectedTestSignerThumbprint must be a 40-digit SHA-1 thumbprint.'
}
if ($useUntrustedTestRoot -and $RequireTimestamp) {
    throw 'An untrusted test root cannot satisfy timestamped release checks.'
}
$resolvedTestRootCertificatePath = $null
$testSignatureValidator = $null
if ($useUntrustedTestRoot) {
    $resolvedTestRootCertificatePath =
        (Resolve-Path -LiteralPath $UntrustedTestRootCertificatePath).Path
    $repositoryPrefix =
        [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
    if ($resolvedTestRootCertificatePath.StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The untrusted test root must not be stored inside the repository.'
    }
    $testSignatureValidator =
        Join-Path $repositoryRoot 'tests\Assert-UntrustedTestSignature.ps1'
    if (-not (Test-Path -LiteralPath $testSignatureValidator -PathType Leaf)) {
        throw 'The untrusted Authenticode test validator is missing.'
    }
    $RequireSignature = $true
}

$reparsePoints = @(
    Get-ChildItem -LiteralPath $package -Recurse -Force |
        Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }
)
if ($reparsePoints.Count -gt 0) {
    throw "The package contains a reparse point: $($reparsePoints[0].FullName)"
}

$installerBatchRelativePaths = @(
    'installer\Setup.cmd',
    'installer\Status.cmd',
    'installer\Uninstall-NvidiaAppOculinkShim.cmd'
)
$actualInstallerBatchPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$actualInstallerBatchFiles = @(
    Get-ChildItem -LiteralPath $package -Recurse -File |
        Where-Object Extension -eq '.cmd'
)
foreach ($file in $actualInstallerBatchFiles) {
    $actualInstallerBatchPaths.Add(
        $file.FullName.Substring($package.Length + 1)
    ) | Out-Null
}
$expectedInstallerBatchPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($relative in $installerBatchRelativePaths) {
    $expectedInstallerBatchPaths.Add($relative) | Out-Null
}
$previewMarker = Join-Path $package 'UNSIGNED-PREVIEW.txt'
$expectedBatchFlag = $IncludeInstallerBatchFiles.ToString().ToLowerInvariant()
$buildInfo = Get-Content -LiteralPath (Join-Path $package 'BUILD-INFO.txt')
$batchFlagLines = @(
    $buildInfo | Where-Object {
        $_ -eq "Installer-Batch-Files-Included: $expectedBatchFlag"
    }
)
if ($batchFlagLines.Count -ne 1) {
    throw 'BUILD-INFO does not match the installer-batch package mode.'
}
$expectedPackageProfile = if ($IncludeInstallerBatchFiles) {
    'installer-batch-preview'
} else {
    'native-launcher'
}
if (@($buildInfo | Where-Object {
    $_ -eq "Package-Profile: $expectedPackageProfile"
}).Count -ne 1) {
    throw 'BUILD-INFO does not match the package profile.'
}
if (@($buildInfo | Where-Object {
    $_ -eq 'Repository-Source-Included: false'
}).Count -ne 1) {
    throw 'BUILD-INFO must exclude repository source.'
}
if (@($buildInfo | Where-Object {
    $_ -eq 'Maintainer-Documentation-Included: false'
}).Count -ne 1) {
    throw 'BUILD-INFO must exclude maintainer documentation.'
}
if ($IncludeInstallerBatchFiles) {
    if ($RequireSignature -or $RequireTimestamp) {
        throw (
            'Installer batch entry points are forbidden in a signed package. ' +
            'Use the NativeAOT launcher for trusted releases.'
        )
    }
    if (-not $actualInstallerBatchPaths.SetEquals(
        $expectedInstallerBatchPaths
    )) {
        throw 'The installer batch file set does not match its explicit allowlist.'
    }
    if (-not (Test-Path -LiteralPath $previewMarker -PathType Leaf)) {
        throw 'The unsigned preview warning is missing.'
    }
} elseif (
    $actualInstallerBatchPaths.Count -ne 0 -or
    (Test-Path -LiteralPath $previewMarker)
) {
    throw 'Installer batch files or preview warnings require the explicit preview switch.'
}

$signableRelativePaths = @(
    'NvidiaAppOculinkUpdateBridge.exe',
    'payload\NvidiaAppOculinkShim.exe',
    'AutoRepair-NvidiaAppOculinkShim.ps1',
    'Install-NvidiaAppOculinkShim.ps1',
    'Migrate-V3ToV4.ps1',
    'MaintenanceManifest.ps1',
    'NvidiaAppOculinkShim.Common.psm1',
    'Repair-NvidiaAppOculinkShim.ps1',
    'Setup.ps1',
    'Status.ps1',
    'Test-NvidiaAppOculinkShim.ps1',
    'Uninstall-NvidiaAppOculinkShim.ps1'
)
$signableFiles = @(
    foreach ($relative in $signableRelativePaths) {
        $candidate = Join-Path $package $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Required signable file is missing: $relative"
        }
        Get-Item -LiteralPath $candidate
    }
)
$signatureByPath = @{}
if ($IncludeInstallerBatchFiles) {
    foreach ($file in $signableFiles) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        $signatureByPath[$file.FullName] = $signature
        if (
            $signature.Status -ne 'NotSigned' -or
            $signature.SignerCertificate -or
            $signature.TimeStamperCertificate
        ) {
            throw (
                'The installer-batch preview must be consistently unsigned: ' +
                $file.Name
            )
        }
    }
}
if ($RequireTimestamp) {
    $RequireSignature = $true
}
if ($RequireSignature) {
    $serviceBinary = Join-Path $package 'payload\NvidiaAppOculinkShim.exe'
    $serviceSignature =
        Get-AuthenticodeSignature -LiteralPath $serviceBinary
    $signatureByPath[$serviceBinary] = $serviceSignature
    if (-not $serviceSignature.SignerCertificate) {
        throw 'The service executable has no Authenticode signer certificate.'
    }
    $serviceSignerThumbprint =
        $serviceSignature.SignerCertificate.Thumbprint.ToUpperInvariant()
    $expectedSignerThumbprint = if ($useUntrustedTestRoot) {
        if ($serviceSignerThumbprint -ne $normalizedExpectedTestSigner) {
            throw 'The service signer does not match the expected test certificate.'
        }
        $normalizedExpectedTestSigner
    } else {
        $serviceSignerThumbprint
    }
    $signatureFailures = @(
        foreach ($file in $signableFiles) {
            $signature = $signatureByPath[$file.FullName]
            if (-not $signature) {
                $signature =
                    Get-AuthenticodeSignature -LiteralPath $file.FullName
                $signatureByPath[$file.FullName] = $signature
            }
            if ($useUntrustedTestRoot) {
                try {
                    & $testSignatureValidator `
                        -Signature $signature `
                        -ExpectedSignerThumbprint $expectedSignerThumbprint `
                        -RootCertificatePath $resolvedTestRootCertificatePath `
                        -FileName $file.Name
                } catch {
                    "$($file.Name): $($_.Exception.Message)"
                }
            } elseif (
                $signature.Status -ne 'Valid' -or
                -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Thumbprint -ne
                    $expectedSignerThumbprint
            ) {
                "$($file.Name): $($signature.Status)"
            } elseif (
                $RequireTimestamp -and
                -not $signature.TimeStamperCertificate
            ) {
                "$($file.Name): missing timestamp"
            }
        }
    )
    if ($signatureFailures.Count -gt 0) {
        throw (
            'Required Authenticode signatures are invalid: ' +
            ($signatureFailures -join ', ')
        )
    }
}

$manifestPath = Join-Path $package 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -LiteralPath $manifestPath -Force
}
$manifest = Get-ChildItem -LiteralPath $package -Recurse -File |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($package.Length + 1)
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        "$hash  $relative"
    }
[IO.File]::WriteAllLines(
    $manifestPath,
    $manifest,
    [Text.UTF8Encoding]::new($false)
)

if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
if (Test-Path -LiteralPath $archiveHashPath) {
    Remove-Item -LiteralPath $archiveHashPath -Force
}
Compress-Archive `
    -LiteralPath $package `
    -DestinationPath $archive `
    -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
[IO.File]::WriteAllText(
    $archiveHashPath,
    "$archiveHash  $([IO.Path]::GetFileName($archive))`n",
    [Text.UTF8Encoding]::new($false)
)

foreach ($file in $signableFiles) {
    if (-not $signatureByPath[$file.FullName]) {
        $signatureByPath[$file.FullName] =
            Get-AuthenticodeSignature -LiteralPath $file.FullName
    }
}
$serviceBinary = Join-Path $package 'payload\NvidiaAppOculinkShim.exe'
$serviceSignature = $signatureByPath[$serviceBinary]
[pscustomobject]@{
    Package = $package
    Archive = $archive
    ArchiveSha256 = $archiveHash
    ArchiveHashFile = $archiveHashPath
    ServiceSignature = $serviceSignature.Status
    SignerThumbprint =
        if ($serviceSignature.SignerCertificate) {
            $serviceSignature.SignerCertificate.Thumbprint
        } else {
            $null
        }
    SignedPowerShellFiles = @(
        $signableFiles |
            Where-Object Extension -in @('.ps1', '.psm1') |
            Where-Object {
                $useUntrustedTestRoot -or
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
    SignedNativeExecutables = @(
        $signableFiles |
            Where-Object Extension -eq '.exe' |
            Where-Object {
                $useUntrustedTestRoot -or
                $signatureByPath[$_.FullName].Status -eq 'Valid'
            }
    ).Count
} | Format-List
