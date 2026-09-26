[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [string]$SigningCertificatePath,
    [Parameter(Mandatory)]
    [Security.SecureString]$SigningCertificatePassword,
    [Parameter(Mandatory)]
    [string]$ExpectedSignerThumbprint,
    [string]$UntrustedTestRootCertificatePath,
    [AllowEmptyString()]
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$packageParent = Join-Path $artifactsRoot 'package'
$normalizedExpectedThumbprint = (
    $ExpectedSignerThumbprint -replace '\s', ''
).ToUpperInvariant()
if ($normalizedExpectedThumbprint -notmatch '^[A-F0-9]{40}$') {
    throw 'ExpectedSignerThumbprint must be a 40-digit SHA-1 certificate thumbprint.'
}
$useUntrustedTestRoot =
    -not [string]::IsNullOrWhiteSpace($UntrustedTestRootCertificatePath)
if (
    $useUntrustedTestRoot -and
    -not [string]::IsNullOrWhiteSpace($TimestampServer)
) {
    throw 'An untrusted test root cannot be combined with timestamping.'
}
$package = (Resolve-Path -LiteralPath $PackagePath).Path
$packagePrefix = [IO.Path]::GetFullPath($packageParent).TrimEnd('\') + '\'
if (-not $package.StartsWith(
    $packagePrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Package must be below the repository artifacts directory: $package"
}

$previewMarker = Join-Path $package 'UNSIGNED-PREVIEW.txt'
if (Test-Path -LiteralPath $previewMarker) {
    throw 'Refusing to sign an installer-batch preview package.'
}
$batchFiles = @(
    Get-ChildItem -LiteralPath $package -Recurse -File |
        Where-Object Extension -eq '.cmd'
)
if ($batchFiles.Count -ne 0) {
    throw "Refusing to sign a package containing .cmd: $($batchFiles[0].Name)"
}
$buildInfoPath = Join-Path $package 'BUILD-INFO.txt'
if (-not (Test-Path -LiteralPath $buildInfoPath -PathType Leaf)) {
    throw 'BUILD-INFO.txt is missing.'
}
$buildInfo = Get-Content -LiteralPath $buildInfoPath
$batchModeLines = @(
    $buildInfo |
        Where-Object { $_ -match '^Installer-Batch-Files-Included: (.+)$' }
)
if (
    $batchModeLines.Count -ne 1 -or
    $batchModeLines[0] -ne 'Installer-Batch-Files-Included: false'
) {
    throw 'Refusing to sign a package with an invalid installer-batch mode.'
}
if (@($buildInfo | Where-Object {
    $_ -eq 'Package-Profile: native-launcher'
}).Count -ne 1) {
    throw 'Refusing to sign a package with an invalid package profile.'
}
if (@($buildInfo | Where-Object {
    $_ -eq 'Repository-Source-Included: false'
}).Count -ne 1) {
    throw 'Refusing to sign a package containing repository source.'
}
if (@($buildInfo | Where-Object {
    $_ -eq 'Maintainer-Documentation-Included: false'
}).Count -ne 1) {
    throw 'Refusing to sign a package containing maintainer documentation.'
}

$certificatePath =
    (Resolve-Path -LiteralPath $SigningCertificatePath).Path
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($certificatePath.StartsWith(
    $repositoryPrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The signing certificate must not be stored inside the repository.'
}
$resolvedTestRootCertificatePath = $null
$testSignatureValidator = $null
if ($useUntrustedTestRoot) {
    $resolvedTestRootCertificatePath =
        (Resolve-Path -LiteralPath $UntrustedTestRootCertificatePath).Path
    if ($resolvedTestRootCertificatePath.StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The untrusted test root must not be stored inside the repository.'
    }
    if ($resolvedTestRootCertificatePath.Equals(
        $certificatePath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The signing PFX cannot also be the untrusted test root.'
    }
    $testSignatureValidator =
        Join-Path $repositoryRoot 'tests\Assert-UntrustedTestSignature.ps1'
    if (-not (Test-Path -LiteralPath $testSignatureValidator -PathType Leaf)) {
        throw 'The untrusted Authenticode test validator is missing.'
    }
}

if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
    $timestampUri = $null
    if (
        -not [Uri]::TryCreate(
            $TimestampServer,
            [UriKind]::Absolute,
            [ref]$timestampUri
        ) -or
        $timestampUri.Host -ne 'timestamp.digicert.com' -or
        $timestampUri.Scheme -notin @('http', 'https')
    ) {
        throw 'TimestampServer must be http(s)://timestamp.digicert.com.'
    }
}

$signedContentRelativePaths = @(
    'NvidiaAppOculinkUpdateBridge.exe',
    'payload\NvidiaAppOculinkShim.exe',
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
$maintenanceManifestRelativePath = 'MaintenanceManifest.ps1'
$signableRelativePaths = @(
    $signedContentRelativePaths
    $maintenanceManifestRelativePath
)
$signableFiles = @(
    foreach ($relative in $signableRelativePaths) {
        $candidate = Join-Path $package $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Required signable file is missing: $relative"
        }
        $item = Get-Item -LiteralPath $candidate
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to sign a reparse point: $relative"
        }
        $item
    }
)

$certificateFlags =
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$certificate =
    [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificatePath,
        $SigningCertificatePassword,
        $certificateFlags
    )
try {
    if (-not $certificate.HasPrivateKey) {
        throw 'The signing certificate does not contain a private key.'
    }
    $expectedSignerThumbprint = $certificate.Thumbprint.ToUpperInvariant()
    if ($expectedSignerThumbprint -ne $normalizedExpectedThumbprint) {
        throw (
            'The supplied PFX does not match ExpectedSignerThumbprint. ' +
            "Expected $normalizedExpectedThumbprint; got $expectedSignerThumbprint."
        )
    }

    $signFile = {
        param([IO.FileInfo]$File)

        $relativePath = $File.FullName.Substring($package.Length + 1)
        Write-Output "Signing $relativePath ..."
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $signatureParameters = @{
            LiteralPath = $File.FullName
            Certificate = $certificate
            HashAlgorithm = 'SHA256'
        }
        if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
            $signatureParameters.TimestampServer = $TimestampServer
        }
        if ($useUntrustedTestRoot) {
            $signatureParameters.IncludeChain = 'All'
        }
        $signature = Set-AuthenticodeSignature @signatureParameters
        $stopwatch.Stop()
        if ($useUntrustedTestRoot) {
            & $testSignatureValidator `
                -Signature $signature `
                -ExpectedSignerThumbprint $expectedSignerThumbprint `
                -RootCertificatePath $resolvedTestRootCertificatePath `
                -FileName $relativePath
        } elseif (
            $signature.Status -ne 'Valid' -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne
                $expectedSignerThumbprint
        ) {
            throw "Signing failed for $($File.Name): $($signature.Status)"
        }
        if (
            -not [string]::IsNullOrWhiteSpace($TimestampServer) -and
            -not $signature.TimeStamperCertificate
        ) {
            throw "The signature was not timestamped: $($File.Name)"
        }
        Write-Output (
            "Signed $relativePath in {0:N1}s." -f $stopwatch.Elapsed.TotalSeconds
        )
    }

    foreach ($file in $signableFiles | Where-Object {
        $_.Name -ne $maintenanceManifestRelativePath
    }) {
        & $signFile $file
    }

    $versionLine = @(
        Get-Content -LiteralPath $buildInfoPath |
            Where-Object { $_ -match '^Version: (.+)$' }
    )
    if ($versionLine.Count -ne 1) {
        throw 'BUILD-INFO.txt must contain exactly one Version line.'
    }
    $packageVersion = $versionLine[0].Substring('Version: '.Length)
    & (Join-Path $repositoryRoot 'build\New-MaintenanceManifest.ps1') `
        -PackagePath $package `
        -Version $packageVersion |
        Out-Null
    $manifestFile = Get-Item -LiteralPath (
        Join-Path $package $maintenanceManifestRelativePath
    )
    & $signFile $manifestFile
} finally {
    $certificate.Dispose()
}

[pscustomobject]@{
    Package = $package
    SignedFiles = $signableFiles.Count
    SignatureStatus = if ($useUntrustedTestRoot) {
        'CryptographicallyValidWithUntrustedTestRoot'
    } else {
        'Valid'
    }
    SignerThumbprint = $expectedSignerThumbprint
    Timestamped = -not [string]::IsNullOrWhiteSpace($TimestampServer)
} | Format-List
