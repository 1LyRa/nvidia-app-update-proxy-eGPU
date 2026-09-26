[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$browserOrigin = 'https://nvfile'
$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$profilePath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\UpdateFramework\' +
    'profile-catalog\component_profiles.json'
)
$localizedConfigPath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\NvConfig\LocalizedConfig.json'
)
$installRoot = Join-Path $programData 'NVIDIAAppOCuLinkDriverShim'
$runtimeRoot = Join-Path $installRoot 'runtime'
$configPath = Join-Path $installRoot 'config.json'
$statePath = Join-Path $installRoot 'state.json'
$serviceExePath = Join-Path $installRoot 'NvidiaAppOculinkShim.exe'
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$serviceName = 'NvidiaAppOculinkShim'
$requiredProxyVersion = 4
Import-Module `
    (Join-Path $PSScriptRoot 'NvidiaAppOculinkShim.Common.psm1') `
    -Force

function ConvertTo-StrictUtcTimestampText {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Description
    )

    $format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    if ($Value -is [DateTime]) {
        $dateValue = [DateTime]$Value
        if ($dateValue.Kind -ne [DateTimeKind]::Utc) {
            throw "$Description is not a UTC timestamp."
        }
        return $dateValue.ToString(
            $format,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [DateTimeOffset]) {
        $offsetValue = [DateTimeOffset]$Value
        if ($offsetValue.Offset -ne [TimeSpan]::Zero) {
            throw "$Description is not a UTC timestamp."
        }
        return $offsetValue.UtcDateTime.ToString(
            $format,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    $textValue = [string]$Value
    $parsedValue = [DateTimeOffset]::MinValue
    if (
        $textValue -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or
        -not [DateTimeOffset]::TryParseExact(
            $textValue,
            $format,
            [Globalization.CultureInfo]::InvariantCulture,
            (
                [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal
            ),
            [ref]$parsedValue
        )
    ) {
        throw "$Description is invalid: $textValue"
    }
    return $textValue
}

function Get-LoopbackBaseUrl {
    param(
        [int]$Port,
        [string]$Token
    )

    if ($Port -eq 80) {
        return "http://127.0.0.1/$Token/"
    }
    return "http://127.0.0.1:$Port/$Token/"
}

foreach (
    $requiredPath in @(
        $profilePath,
        $localizedConfigPath,
        $configPath,
        $statePath,
        $serviceExePath,
        $pidPath
    )
) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required shim file was not found: $requiredPath"
    }
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.status -ne 'installed') {
    throw "Shim state is '$($state.status)', not 'installed'."
}
if ([string]$state.uiRedirectStatus -ne 'installed') {
    throw "NVIDIA App UI redirect state is '$($state.uiRedirectStatus)', not 'installed'."
}
if ([int]$state.proxyVersion -ne $requiredProxyVersion) {
    throw "Protected state records proxy version '$($state.proxyVersion)', not version $requiredProxyVersion."
}
if (
    [string]$state.hostKind -ne 'windows-service' -or
    [string]$state.serviceName -ne $serviceName -or
    [string]$state.productVersion -notmatch '^4\.'
) {
    throw 'Protected state does not record the expected v4 Windows service.'
}
if (
    [int]$state.listenerPort -ne 80 -or
    [string]$state.endpointCompatibility -ne 'implicit-http-default-port'
) {
    throw 'Protected state does not record the implicit-port NVIDIA compatibility mode.'
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([int]$config.port -ne 80) {
    throw "The v4 helper must use implicit HTTP port 80; found '$($config.port)'."
}
$baseUrl =
    Get-LoopbackBaseUrl `
        -Port ([int]$config.port) `
        -Token ([string]$config.token)
if ($baseUrl -notmatch '^http://127\.0\.0\.1/[a-f0-9]{32,128}/$') {
    throw 'The v4 loopback URL exposes an explicit port to NVIDIA App.'
}
if ($baseUrl -ne [string]$state.localBaseUrl) {
    throw 'The protected config and state contain different loopback URLs.'
}
if (
    [string]::IsNullOrWhiteSpace([string]$state.configSha256) -or
    (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne
        [string]$state.configSha256
) {
    throw 'The protected v4 helper configuration failed its SHA-256 check.'
}
if (
    [string]::IsNullOrWhiteSpace([string]$state.serviceBinarySha256) -or
    (Get-FileHash -LiteralPath $serviceExePath -Algorithm SHA256).Hash -ne
        [string]$state.serviceBinarySha256
) {
    throw 'The installed v4 service executable failed its SHA-256 check.'
}

$localizedConfig = Get-Content -LiteralPath $localizedConfigPath -Raw | ConvertFrom-Json
$localizedServer = [string]$localizedConfig.localizedConfig.gfwsl.server
if ($localizedServer -ne $baseUrl) {
    throw "NVIDIA App is not using the loopback metadata endpoint: $localizedServer"
}
if ($null -eq $state.patchedLocalizedConfigTimestamp) {
    throw 'Protected state does not record the deferred localized-config timestamp.'
}
$patchedLocalizedTimestamp =
    ConvertTo-StrictUtcTimestampText `
        -Value $state.patchedLocalizedConfigTimestamp `
        -Description 'The protected deferred localized configTimestamp'
$parsedPatchedLocalizedTimestamp = [DateTimeOffset]::MinValue
if (
    $patchedLocalizedTimestamp -notmatch
        '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or
    -not [DateTimeOffset]::TryParseExact(
        $patchedLocalizedTimestamp,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        (
            [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal
        ),
        [ref]$parsedPatchedLocalizedTimestamp
    )
) {
    throw 'Protected state contains an invalid deferred localized-config timestamp.'
}
$liveLocalizedTimestamp =
    ConvertTo-StrictUtcTimestampText `
        -Value $localizedConfig.configTimestamp `
        -Description 'The live localized configTimestamp'
if ($liveLocalizedTimestamp -ne $patchedLocalizedTimestamp) {
    throw "NvLocalizedConfig no longer has the deferred refresh timestamp: $liveLocalizedTimestamp"
}
if ($parsedPatchedLocalizedTimestamp -lt [DateTimeOffset]::UtcNow.AddDays(7)) {
    throw 'The localized-config refresh timestamp is not safely deferred into the future.'
}
if ([string]::IsNullOrWhiteSpace([string]$state.localizedConfigBackupRelative)) {
    throw 'Protected state does not record an original LocalizedConfig backup.'
}
$installRootFull = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') + '\'
$localizedBackupPath = [IO.Path]::GetFullPath(
    (Join-Path $installRoot ([string]$state.localizedConfigBackupRelative))
)
if (-not $localizedBackupPath.StartsWith(
    $installRootFull,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The LocalizedConfig backup path escapes the protected install directory.'
}
if (-not (Test-Path -LiteralPath $localizedBackupPath)) {
    throw "The protected LocalizedConfig backup is missing: $localizedBackupPath"
}
$backupHash = (Get-FileHash -LiteralPath $localizedBackupPath -Algorithm SHA256).Hash
if ($backupHash -ne [string]$state.originalLocalizedConfigSha256) {
    throw 'The protected LocalizedConfig backup failed its SHA-256 check.'
}
$backupLocalizedConfig =
    Get-Content -LiteralPath $localizedBackupPath -Raw |
    ConvertFrom-Json
$backupLocalizedTimestamp =
    ConvertTo-StrictUtcTimestampText `
        -Value $backupLocalizedConfig.configTimestamp `
        -Description 'The protected backup localized configTimestamp'
if ($null -eq $state.originalLocalizedConfigTimestamp) {
    throw 'Protected state does not record the original localized configTimestamp.'
}
$stateOriginalLocalizedTimestamp =
    ConvertTo-StrictUtcTimestampText `
        -Value $state.originalLocalizedConfigTimestamp `
        -Description 'The protected original localized configTimestamp'
if ($stateOriginalLocalizedTimestamp -ne $backupLocalizedTimestamp) {
    throw 'The protected state and LocalizedConfig backup contain different original timestamps.'
}
$liveLocalizedHash = (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
if ($liveLocalizedHash -ne [string]$state.patchedLocalizedConfigSha256) {
    throw 'The live LocalizedConfig changed after the UI redirect was installed.'
}

$profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
foreach ($name in @('grd', 'crd')) {
    $entry = @($profiles | Where-Object componentName -eq $name)
    if (
        $entry.Count -ne 1 -or
        [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $baseUrl
    ) {
        throw "NVIDIA component '$name' is not redirected to the installed helper."
    }
}
if (
    [string]::IsNullOrWhiteSpace([string]$state.patchedProfileSha256) -or
    (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash -ne
        [string]$state.patchedProfileSha256
) {
    throw 'The live NVIDIA component profile changed after the redirect was installed.'
}

if ($state.helperAccount -ne 'LocalService') {
    throw 'The protected install state does not record the LocalService helper.'
}

$health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 5
if (
    $health.status -ne 'ok' -or
    [int]$health.version -ne $requiredProxyVersion -or
    [int]$health.port -ne 80
) {
    throw 'The implicit-port loopback v4 helper health check failed.'
}
if (
    [string]$health.browserOrigin -ne $browserOrigin -or
    [string]$health.upstream -ne 'https://gfwsl.geforce.com'
) {
    throw 'The helper health response contains unexpected origin or upstream settings.'
}

$pidText = [string](Get-Content -LiteralPath $pidPath -Raw)
$shimPid = 0
if (
    -not [int]::TryParse($pidText.Trim(), [ref]$shimPid) -or
    $shimPid -ne [int]$health.pid
) {
    throw 'The helper PID file does not match the running helper.'
}
$helperProcess = Get-Process -Id $shimPid -ErrorAction Stop
$service = Get-Service -Name $serviceName -ErrorAction Stop
$serviceConfiguration = & sc.exe qc $serviceName
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the installed Windows service configuration.'
}
$binaryPathLine = @(
    $serviceConfiguration |
        Where-Object { $_ -match '^\s*BINARY_PATH_NAME\s*:' }
)
$serviceAccountLine = @(
    $serviceConfiguration |
        Where-Object { $_ -match '^\s*SERVICE_START_NAME\s*:' }
)
$configuredBinaryPath = (
    [string]$binaryPathLine[0] -replace '^\s*BINARY_PATH_NAME\s*:\s*', ''
)
$configuredServiceAccount = (
    [string]$serviceAccountLine[0] -replace '^\s*SERVICE_START_NAME\s*:\s*', ''
)
$expectedBinaryPath =
    '"' + $serviceExePath + '" --service --config "' + $configPath + '"'
$expectedUnquotedBinaryPath =
    $serviceExePath + ' --service --config ' + $configPath
if (
    $helperProcess.ProcessName -ne 'NvidiaAppOculinkShim' -or
    [string]$service.Status -ne 'Running' -or
    $configuredServiceAccount -notin @(
        'NT AUTHORITY\LocalService',
        'NT AUTHORITY\LOCAL SERVICE'
    ) -or
    (
        -not [string]::Equals(
            $configuredBinaryPath,
            $expectedBinaryPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        -not [string]::Equals(
            $configuredBinaryPath,
            $expectedUnquotedBinaryPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    )
) {
    throw 'The helper PID is not the protected LocalService Windows service.'
}

[string[]]$recordedDeviceIds = @(
    $state.detectedDeviceIds |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
)
[string[]]$detectedDeviceIds = @(
    if ($recordedDeviceIds.Count -gt 0) {
        $recordedDeviceIds
    } else {
        Get-PresentNvidiaDeviceIds
    }
)
$windowsVersion = [Environment]::OSVersion.Version
$payload = [ordered]@{
    gcV = '11.0.8.299'
    lg = '1033'
    gLg = 'en-US'
    dIDa = $detectedDeviceIds
    osC = "$($windowsVersion.Major).$($windowsVersion.Minor)"
    osB = [string]$windowsVersion.Build
    is6 = '1'
    GFPV = '0'
    dch = '1'
    iLp = '1'
    isB = '0'
    gIsB = '0'
    isO = '1'
    go = 'US'
    prvMd = '0'
    cSR = '0'
    IsQ = '0'
    uCst = '0'
    upCRD = '0'
    isCRD = '0'
    isInst = '1'
}
$controller = 'nvidia_web_services/controller.gfeclientcontent.NG.php/'
$recommendationEndpoint =
    $controller +
    'com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
$encoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
$recommendation = Invoke-RestMethod `
    -Uri ($baseUrl + $recommendationEndpoint + $encoded) `
    -TimeoutSec 40

$supported = ([string]$recommendation.criteria.IsSupported.state).ToLowerInvariant()
$latestText = [string]$recommendation.criteria.IsDispDriverNewer.latestDispDriverVersion
$recommendationUri = [Uri][string]$recommendation.DriverAttributes.DownloadURLAdmin
if ($supported -notin @('1', 'true')) {
    throw 'NVIDIA metadata did not mark the OCuLink GPU as supported.'
}
if ([string]::IsNullOrWhiteSpace($latestText)) {
    throw 'NVIDIA metadata did not return a latest driver version.'
}
$escapedLatest = [regex]::Escape($latestText)
if (
    $recommendationUri.Scheme -ne 'https' -or
    $recommendationUri.Host -notmatch '(^|\.)nvidia\.com$' -or
    $recommendationUri.AbsolutePath -notmatch "/Windows/$escapedLatest/"
) {
    throw "NVIDIA recommendation returned an unexpected package URL: $recommendationUri"
}

$payload.GFPV = $latestText
$payload.isInst = '0'
$detailsEndpoint =
    $controller +
    'com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/'
$detailsEncoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
$detailsUri = $baseUrl + $detailsEndpoint + $detailsEncoded
$requestedHeaders = 'telemetry,ot-tracer-spanid,x-request-id'
$preflight = Invoke-WebRequest `
    -UseBasicParsing `
    -Method Options `
    -Uri $detailsUri `
    -Headers @{
        Origin = $browserOrigin
        'Access-Control-Request-Method' = 'GET'
        'Access-Control-Request-Headers' = $requestedHeaders
        'Access-Control-Request-Private-Network' = 'true'
    } `
    -TimeoutSec 10

$allowedHeaderTokens = @(
    ([string]$preflight.Headers['Access-Control-Allow-Headers']).Split(',') |
        ForEach-Object { $_.Trim().ToLowerInvariant() }
)
$allowedMethodTokens = @(
    ([string]$preflight.Headers['Access-Control-Allow-Methods']).Split(',') |
        ForEach-Object { $_.Trim().ToUpperInvariant() }
)
if (
    [int]$preflight.StatusCode -ne 204 -or
    [string]$preflight.Headers['Access-Control-Allow-Origin'] -ne $browserOrigin -or
    [string]$preflight.Headers['Access-Control-Allow-Credentials'] -ne 'true' -or
    [string]$preflight.Headers['Access-Control-Allow-Private-Network'] -ne 'true' -or
    'GET' -notin $allowedMethodTokens
) {
    throw 'The NVIDIA App CORS/private-network preflight failed.'
}
foreach ($requestedHeader in $requestedHeaders.Split(',')) {
    if ($requestedHeader -notin $allowedHeaderTokens) {
        throw "The preflight did not allow requested header '$requestedHeader'."
    }
}

$detailsWebResponse = Invoke-WebRequest `
    -UseBasicParsing `
    -Method Get `
    -Uri $detailsUri `
    -Headers @{ Origin = $browserOrigin; telemetry = 'shim-verification' } `
    -TimeoutSec 40
if (
    [int]$detailsWebResponse.StatusCode -ne 200 -or
    [string]$detailsWebResponse.Headers['Access-Control-Allow-Origin'] -ne $browserOrigin -or
    [string]$detailsWebResponse.Headers['Access-Control-Allow-Credentials'] -ne 'true'
) {
    throw 'The NVIDIA App details response is missing required credentialed CORS headers.'
}
$details = $detailsWebResponse.Content | ConvertFrom-Json
$detailsSupported = ([string]$details.criteria.IsSupported.state).ToLowerInvariant()
$detailsDownloadUri = [Uri][string]$details.DriverAttributes.DownloadURL
$clientUxCount = @($details.DriverAttributes.clientUX.PSObject.Properties).Count
if (
    $detailsSupported -notin @('1', 'true') -or
    [string]::IsNullOrWhiteSpace([string]$details.DriverAttributes.ID) -or
    [string]::IsNullOrWhiteSpace([string]$details.DriverAttributes.ReleaseDateTime) -or
    $clientUxCount -lt 1 -or
    $detailsDownloadUri.Scheme -ne 'https' -or
    $detailsDownloadUri.Host -notmatch '(^|\.)nvidia\.com$' -or
    $detailsDownloadUri.AbsolutePath -notmatch "/Windows/$escapedLatest/"
) {
    throw "NVIDIA did not return complete details for requested GFPV $latestText."
}

[pscustomobject]@{
    ShimStatus = $health.status
    ProxyVersion = $health.version
    ServiceAccount = $configuredServiceAccount
    UiRedirect = $state.uiRedirectStatus
    LoopbackRedirect = 'configured'
    RefreshDeferredTimestamp = $liveLocalizedTimestamp
    ProfileComponents = 'grd, crd'
    DeviceSupported = $recommendation.criteria.IsSupported.state
    LatestVersion = $latestText
    RecommendationHost = $recommendationUri.Host
    CorsOrigin = $preflight.Headers['Access-Control-Allow-Origin']
    CorsCredentials = $preflight.Headers['Access-Control-Allow-Credentials']
    PrivateNetwork = $preflight.Headers['Access-Control-Allow-Private-Network']
    DetailsId = $details.DriverAttributes.ID
    DetailsGfpv = $latestText
    DetailsHost = $detailsDownloadUri.Host
    MetadataOnly = $true
} | Format-List
