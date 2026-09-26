[CmdletBinding()]
param(
    [switch]$ElevatedPhase,
    [string]$ServiceBinary
)

$ErrorActionPreference = 'Stop'
$programData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
$windowsDirectory = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Windows
)
$systemPowerShell = Join-Path `
    $windowsDirectory `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) {
    throw 'The fixed System32 Windows PowerShell executable is missing.'
}
$profilePath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\UpdateFramework\' +
    'profile-catalog\component_profiles.json'
)
$localizedConfigPath = Join-Path $programData (
    'NVIDIA Corporation\NVIDIA App\NvConfig\LocalizedConfig.json'
)
$installRoot = Join-Path $programData 'NVIDIAAppOCuLinkDriverShim'
$runtimeRoot = Join-Path $installRoot 'runtime'
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'
$serviceExePath = Join-Path $installRoot 'NvidiaAppOculinkShim.exe'
$serviceName = 'NvidiaAppOculinkShim'
$nvidiaLocalSystemService = 'NvContainerLocalSystem'
$officialBaseUrl = 'https://gfwsl.geforce.com/'
$mutexName = 'Global\NVIDIAAppOCuLinkDriverShim-Install'
Import-Module `
    (Join-Path $PSScriptRoot 'NvidiaAppOculinkShim.Common.psm1') `
    -Force

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Resolve-ServiceBinary {
    param([string]$RequestedPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates += $RequestedPath
    }
    $candidates +=
        (Join-Path $PSScriptRoot 'payload\NvidiaAppOculinkShim.exe')
    $candidates +=
        (Join-Path (
            Split-Path -Parent $PSScriptRoot
        ) 'artifacts\publish\win-x64\NvidiaAppOculinkShim.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'The v4 service executable was not found.'
}

function Write-Utf8NoBom {
    param([string]$LiteralPath, [string]$Value)
    [IO.File]::WriteAllText(
        $LiteralPath,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

function Write-ProtectedState {
    param([string]$Text)

    $temporary =
        Join-Path $installRoot (
            'state.repair.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        )
    $discarded = $temporary + '.discarded'
    try {
        Write-Utf8NoBom -LiteralPath $temporary -Value $Text
        Set-Acl `
            -LiteralPath $temporary `
            -AclObject (Get-Acl -LiteralPath $statePath)
        [IO.File]::Replace($temporary, $statePath, $discarded, $true)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $discarded -Force -ErrorAction SilentlyContinue
    }
}

function Replace-JsonFile {
    param(
        [string]$TargetPath,
        [object]$Value,
        [string]$OperationName
    )

    $directory = Split-Path -Parent $TargetPath
    $temporary =
        Join-Path $directory (
            $OperationName + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        )
    $discarded = $temporary + '.discarded'
    try {
        Write-Utf8NoBom `
            -LiteralPath $temporary `
            -Value ($Value | ConvertTo-Json -Depth 30)
        Set-Acl `
            -LiteralPath $temporary `
            -AclObject (Get-Acl -LiteralPath $TargetPath)
        [void](Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json)
        [IO.File]::Replace($temporary, $TargetPath, $discarded, $true)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $discarded -Force -ErrorAction SilentlyContinue
    }
}

function Stop-NvidiaUserProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process `
        -Name 'NVIDIA App', 'NVIDIA Overlay', 'nvcontainer' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}


function Stop-NvidiaUiProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId

    foreach ($attempt in 1..12) {
        Get-Process `
            -Name 'NVIDIA App' `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sessionId } |
            Stop-Process -Force -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 250
    }
}
function Stop-NvidiaLocalizedConfigService {
    Stop-Service `
        -Name $nvidiaLocalSystemService `
        -Force `
        -ErrorAction Stop
    (Get-Service -Name $nvidiaLocalSystemService).WaitForStatus(
        [ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(20)
    )
}

function Start-NvidiaLocalizedConfigService {
    Start-Service `
        -Name $nvidiaLocalSystemService `
        -ErrorAction Stop

    (Get-Service -Name $nvidiaLocalSystemService).WaitForStatus(
        [ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(20)
    )

    Start-Sleep -Milliseconds 750
    Stop-NvidiaUiProcesses
}

function Wait-ForV4Health {
    param([object]$Config)

    $baseUrl = if ([int]$Config.port -eq 80) {
        "http://127.0.0.1/$($Config.token)/"
    } else {
        "http://127.0.0.1:$($Config.port)/$($Config.token)/"
    }
    $health = $null
    foreach ($attempt in 1..60) {
        try {
            $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 2
            if ($health.status -eq 'ok') {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($health.status -ne 'ok' -or [int]$health.version -ne 4) {
        throw 'The repaired v4 service did not become healthy.'
    }

    $windowsVersion = [Environment]::OSVersion.Version
    $payload = [ordered]@{
        gcV = '11.0.8.299'
        lg = '1033'
        gLg = 'en-US'
        dIDa = @(Get-PresentNvidiaDeviceIds)
        osC = "$($windowsVersion.Major).$($windowsVersion.Minor)"
        osB = [string]$windowsVersion.Build
        is6 = '1'
        GFPV = '0'
        dch = '1'
        iLp = '1'
        isB = '0'
        gIsB = '0'
        isO = '1'
        isInst = '1'
    }
    $endpoint =
        'nvidia_web_services/controller.gfeclientcontent.NG.php/' +
        'com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
    $metadata = Invoke-RestMethod `
        -Uri (
            $baseUrl +
            $endpoint +
            [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
        ) `
        -TimeoutSec 40
    $downloadUri = [Uri]$metadata.DriverAttributes.DownloadURLAdmin
    $latest =
        [string]$metadata.criteria.IsDispDriverNewer.latestDispDriverVersion
    if (
        [string]::IsNullOrWhiteSpace($latest) -or
        $downloadUri.Scheme -ne 'https' -or
        $downloadUri.Host -notmatch '(^|\.)nvidia\.com$'
    ) {
        throw 'The repaired service failed live NVIDIA metadata validation.'
    }
    return $latest
}

if (-not $ElevatedPhase) {
    if (Test-IsAdministrator) {
        throw 'Run repair as a normal user; it will request UAC itself.'
    }
    $resolvedBinary = Resolve-ServiceBinary -RequestedPath $ServiceBinary
    & $resolvedBinary --self-test
    if ($LASTEXITCODE -ne 0) {
        throw 'The replacement service failed its built-in self-test.'
    }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-ElevatedPhase',
        '-ServiceBinary', "`"$resolvedBinary`""
    )
    $process = Start-Process `
        -FilePath $systemPowerShell `
        -Verb RunAs `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        $errorLog = Join-Path $runtimeRoot 'repair-error.log'
        $detail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated repair failed before writing diagnostics.'
        }
        throw "Repair failed.`n$detail"
    }
    & (Join-Path $PSScriptRoot 'Test-NvidiaAppOculinkShim.ps1')
    Write-Output 'Repair completed. NVIDIA App may now check for driver updates.'
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated repair phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$serviceStopped = $false
$localizedServiceStopped = $false
$profileReplaced = $false
$localizedReplaced = $false
$binaryReplaced = $false
$stateReplaced = $false
$originalStateText = $null
$repairRoot = $null

try {
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        throw 'Another install, repair, or uninstall operation is running.'
    }
    $resolvedBinary = Resolve-ServiceBinary -RequestedPath $ServiceBinary
    foreach ($path in @(
        $statePath,
        $configPath,
        $serviceExePath,
        $profilePath,
        $localizedConfigPath
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required repair input is missing: $path"
        }
    }
    $originalStateText = Get-Content -LiteralPath $statePath -Raw
    $state = $originalStateText | ConvertFrom-Json
    if (
        $state.status -ne 'installed' -or
        [int]$state.proxyVersion -ne 4 -or
        [string]$state.hostKind -ne 'windows-service'
    ) {
        throw 'Repair requires an installed v4 Windows service.'
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUrl = if ([int]$config.port -eq 80) {
        "http://127.0.0.1/$($config.token)/"
    } else {
        "http://127.0.0.1:$($config.port)/$($config.token)/"
    }
    if (
        $baseUrl -ne [string]$state.localBaseUrl -or
        [string]$config.token -notmatch '^[a-f0-9]{32,128}$'
    ) {
        throw 'Protected state and helper configuration do not match.'
    }

    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $profileChanged = $false
    foreach ($name in @('grd', 'crd')) {
        $entry = @($profiles | Where-Object componentName -eq $name)
        if ($entry.Count -ne 1 -or $entry[0].updateCheckerProfiles.Count -lt 1) {
            throw "NVIDIA component '$name' has an unexpected schema."
        }
        $currentUrl =
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl
        if ($currentUrl -notin @($officialBaseUrl, $baseUrl)) {
            throw "Refusing to replace unknown '$name' endpoint: $currentUrl"
        }
        if ($currentUrl -ne $baseUrl) {
            $entry[0].updateCheckerProfiles[0].otaBaseUrl = $baseUrl
            $profileChanged = $true
        }
    }

    $localized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json
    $currentLocalizedServer =
        [string]$localized.localizedConfig.gfwsl.server
    if ($currentLocalizedServer -notin @($officialBaseUrl, $baseUrl)) {
        throw "Refusing to replace unknown localized GFWSL endpoint: $currentLocalizedServer"
    }
    $localizedChanged = $currentLocalizedServer -ne $baseUrl
    $localized.localizedConfig.gfwsl.server = $baseUrl
    $patchedTimestamp =
        [DateTimeOffset]::UtcNow.AddYears(1).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    if ($localizedChanged) {
        $localized.configTimestamp = $patchedTimestamp
    } else {
        $existingTimestamp = [DateTimeOffset]$localized.configTimestamp
        if ($existingTimestamp -lt [DateTimeOffset]::UtcNow.AddDays(30)) {
            $localized.configTimestamp = $patchedTimestamp
            $localizedChanged = $true
        } else {
            $patchedTimestamp =
                $existingTimestamp.UtcDateTime.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss'Z'",
                    [Globalization.CultureInfo]::InvariantCulture
                )
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repairRelative = Join-Path 'backup' ($timestamp + '-repair')
    $repairRoot = Join-Path $installRoot $repairRelative
    New-Item -ItemType Directory -Path $repairRoot -Force | Out-Null
    Write-Utf8NoBom `
        -LiteralPath (Join-Path $repairRoot 'state.before-repair.json') `
        -Value $originalStateText
    Copy-Item `
        -LiteralPath $serviceExePath `
        -Destination (Join-Path $repairRoot 'NvidiaAppOculinkShim.exe')
    Copy-Item `
        -LiteralPath $profilePath `
        -Destination (Join-Path $repairRoot 'component_profiles.json')
    Copy-Item `
        -LiteralPath $localizedConfigPath `
        -Destination (Join-Path $repairRoot 'LocalizedConfig.json')

    $currentProfileHash =
        (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $currentLocalizedHash =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    $profileRestoreMode = if (
        [string]::IsNullOrWhiteSpace([string]$state.patchedProfileSha256) -or
        $currentProfileHash -ne [string]$state.patchedProfileSha256
    ) {
        'selective'
    } else {
        [string]$state.profileRestoreMode
    }
    if ([string]::IsNullOrWhiteSpace($profileRestoreMode)) {
        $profileRestoreMode = 'exact'
    }
    $localizedRestoreMode = if (
        [string]::IsNullOrWhiteSpace(
            [string]$state.patchedLocalizedConfigSha256
        ) -or
        $currentLocalizedHash -ne
            [string]$state.patchedLocalizedConfigSha256
    ) {
        'selective'
    } else {
        [string]$state.localizedRestoreMode
    }
    if ([string]::IsNullOrWhiteSpace($localizedRestoreMode)) {
        $localizedRestoreMode = 'exact'
    }

    Stop-NvidiaUserProcesses
    Stop-NvidiaLocalizedConfigService
    $localizedServiceStopped = $true
    & sc.exe stop $serviceName | Out-Null
    if (
        $LASTEXITCODE -ne 0 -and
        (Get-Service -Name $serviceName).Status -ne 'Stopped'
    ) {
        throw 'SCM refused to stop the v4 service.'
    }
    foreach ($attempt in 1..80) {
        if ((Get-Service -Name $serviceName).Status -eq 'Stopped') {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ((Get-Service -Name $serviceName).Status -ne 'Stopped') {
        throw 'The v4 service did not stop within 20 seconds.'
    }
    $serviceStopped = $true

    Copy-Item `
        -LiteralPath $resolvedBinary `
        -Destination $serviceExePath `
        -Force
    $binaryReplaced = $true
    if ($profileChanged) {
        Replace-JsonFile `
            -TargetPath $profilePath `
            -Value $profiles `
            -OperationName 'component_profiles.oculink-repair'
        $profileReplaced = $true
    }
    if ($localizedChanged) {
        Replace-JsonFile `
            -TargetPath $localizedConfigPath `
            -Value $localized `
            -OperationName 'LocalizedConfig.oculink-repair'
        $localizedReplaced = $true
    }

    Start-Service -Name $serviceName
    $serviceStopped = $false
    $latestVersion = Wait-ForV4Health -Config $config
    Start-NvidiaLocalizedConfigService
    $localizedServiceStopped = $false
    Start-Sleep -Seconds 2
    $liveLocalized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json
    if (
        [string]$liveLocalized.localizedConfig.gfwsl.server -ne $baseUrl
    ) {
        throw 'NvLocalizedConfig replaced the repaired endpoint.'
    }

    $state.proxySha256 =
        (Get-FileHash -LiteralPath $serviceExePath -Algorithm SHA256).Hash
    $state.serviceBinarySha256 = $state.proxySha256
    $state.configSha256 =
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $state.patchedProfileSha256 =
        (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $state.patchedLocalizedConfigSha256 =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    $state.patchedLocalizedConfigTimestamp = $patchedTimestamp
    $state.verifiedLatestVersion = $latestVersion
    $state | Add-Member `
        -NotePropertyName detectedDeviceIds `
        -NotePropertyValue @(Get-PresentNvidiaDeviceIds) `
        -Force
    $state | Add-Member `
        -NotePropertyName profileRestoreMode `
        -NotePropertyValue $profileRestoreMode `
        -Force
    $state | Add-Member `
        -NotePropertyName localizedRestoreMode `
        -NotePropertyValue $localizedRestoreMode `
        -Force
    $state | Add-Member `
        -NotePropertyName lastRepairBackupRelative `
        -NotePropertyValue $repairRelative `
        -Force
    $state | Add-Member `
        -NotePropertyName repairedAt `
        -NotePropertyValue (Get-Date).ToString('o') `
        -Force
    Write-ProtectedState -Text ($state | ConvertTo-Json -Depth 12)
    $stateReplaced = $true
    Remove-Item `
        -LiteralPath (Join-Path $runtimeRoot 'repair-error.log') `
        -Force `
        -ErrorAction SilentlyContinue
    Install-NvidiaAppAutoRepairTask `
        -InstallRoot $installRoot

} catch {
    $failure = $_
    if ($serviceStopped -or $binaryReplaced -or $profileReplaced -or $localizedReplaced) {
        try {
            & sc.exe stop $serviceName | Out-Null
            if ($repairRoot) {
                Copy-Item `
                    -LiteralPath (Join-Path $repairRoot 'NvidiaAppOculinkShim.exe') `
                    -Destination $serviceExePath `
                    -Force
                Copy-Item `
                    -LiteralPath (Join-Path $repairRoot 'component_profiles.json') `
                    -Destination $profilePath `
                    -Force
                Copy-Item `
                    -LiteralPath (Join-Path $repairRoot 'LocalizedConfig.json') `
                    -Destination $localizedConfigPath `
                    -Force
            }
            if ($stateReplaced -and $originalStateText) {
                Write-ProtectedState -Text $originalStateText
            }
            Start-Service -Name $serviceName
            $serviceStopped = $false
        } catch {
        }
    }
    if ($localizedServiceStopped) {
        try {
            Start-NvidiaLocalizedConfigService
            $localizedServiceStopped = $false
        } catch {
        }
    }
    try {
        New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        Write-Utf8NoBom `
            -LiteralPath (Join-Path $runtimeRoot 'repair-error.log') `
            -Value ($failure | Out-String)
    } catch {
    }
    throw $failure
} finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
