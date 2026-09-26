[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'

$nvidiaLocalSystemService = 'NvContainerLocalSystem'
$officialBaseUrl = 'https://gfwsl.geforce.com/'
$mutexName = 'Global\NVIDIAAppOCuLinkDriverShim-Install'

function Write-Utf8NoBom {
    param(
        [string]$LiteralPath,
        [string]$Value
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Value,
        [Text.UTF8Encoding]::new($false)
    )
}

function Replace-JsonFile {
    param(
        [string]$TargetPath,
        [object]$Value,
        [string]$OperationName
    )

    $directory = Split-Path -Parent $TargetPath
    $temporary = Join-Path $directory (
        $OperationName + '.' +
        [Guid]::NewGuid().ToString('N') +
        '.tmp'
    )
    $discarded = $temporary + '.discarded'

    try {
        Write-Utf8NoBom `
            -LiteralPath $temporary `
            -Value ($Value | ConvertTo-Json -Depth 30)

        Set-Acl `
            -LiteralPath $temporary `
            -AclObject (Get-Acl -LiteralPath $TargetPath)

        [void](
            Get-Content -LiteralPath $temporary -Raw |
            ConvertFrom-Json
        )

        [IO.File]::Replace(
            $temporary,
            $TargetPath,
            $discarded,
            $true
        )
    }
    finally {
        Remove-Item `
            -LiteralPath $temporary `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -LiteralPath $discarded `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'Auto repair requires an elevated service account.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$profileReplaced = $false
$localizedReplaced = $false
$localizedServiceWasRunning = $false
$localizedServiceStopped = $false
$profileBackup = $null
$localizedBackup = $null

try {
    $lockAcquired = $mutex.WaitOne(0)

    if (-not $lockAcquired) {
        return
    }

    foreach ($requiredPath in @(
        $statePath,
        $configPath,
        $profilePath,
        $localizedConfigPath
    )) {
        if (-not (
            Test-Path -LiteralPath $requiredPath -PathType Leaf
        )) {
            throw "Required auto-repair input is missing: $requiredPath"
        }
    }

    $originalStateText = Get-Content -LiteralPath $statePath -Raw
    $state = $originalStateText | ConvertFrom-Json

    if (
        $state.status -ne 'installed' -or
        [int]$state.proxyVersion -ne 4 -or
        [string]$state.hostKind -ne 'windows-service'
    ) {
        throw 'Auto repair requires an installed v4 Windows service.'
    }

    $config =
        Get-Content -LiteralPath $configPath -Raw |
        ConvertFrom-Json

    $baseUrl = if ([int]$config.port -eq 80) {
        "http://127.0.0.1/$($config.token)/"
    }
    else {
        "http://127.0.0.1:$($config.port)/$($config.token)/"
    }

    if (
        $baseUrl -ne [string]$state.localBaseUrl -or
        [string]$config.token -notmatch '^[a-f0-9]{32,128}$'
    ) {
        throw 'Protected state and helper configuration do not match.'
    }

    $currentProfileHash =
        (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $currentLocalizedHash =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash

    $profileRestoreMode = [string]$state.profileRestoreMode
    if ([string]::IsNullOrWhiteSpace($profileRestoreMode)) {
        $profileRestoreMode = 'exact'
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$state.patchedProfileSha256) -or
        $currentProfileHash -ne [string]$state.patchedProfileSha256
    ) {
        $profileRestoreMode = 'selective'
    }

    $localizedRestoreMode = [string]$state.localizedRestoreMode
    if ([string]::IsNullOrWhiteSpace($localizedRestoreMode)) {
        $localizedRestoreMode = 'exact'
    }
    if (
        [string]::IsNullOrWhiteSpace(
            [string]$state.patchedLocalizedConfigSha256
        ) -or
        $currentLocalizedHash -ne
            [string]$state.patchedLocalizedConfigSha256
    ) {
        $localizedRestoreMode = 'selective'
    }
    $profiles =
        Get-Content -LiteralPath $profilePath -Raw |
        ConvertFrom-Json

    $profileChanged = $false

    foreach ($name in @('grd', 'crd')) {
        $entry = @(
            $profiles |
            Where-Object componentName -eq $name
        )

        if (
            $entry.Count -ne 1 -or
            $entry[0].updateCheckerProfiles.Count -ne 1
        ) {
            throw "NVIDIA component '$name' has an unexpected schema."
        }

        $currentUrl =
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl

        if ($currentUrl -notin @(
            $officialBaseUrl,
            $baseUrl
        )) {
            throw "Refusing to replace unknown '$name' endpoint: $currentUrl"
        }

        if ($currentUrl -eq $officialBaseUrl) {
            $entry[0].updateCheckerProfiles[0].otaBaseUrl =
                $baseUrl

            $profileChanged = $true
        }
    }

    $localized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json

    $currentLocalizedServer =
        [string]$localized.localizedConfig.gfwsl.server

    if ($currentLocalizedServer -notin @(
        $officialBaseUrl,
        $baseUrl
    )) {
        throw (
            'Refusing to replace unknown localized GFWSL endpoint: ' +
            $currentLocalizedServer
        )
    }

    $localizedChanged =
        $currentLocalizedServer -eq $officialBaseUrl

    $existingTimestamp =
        [DateTimeOffset]$localized.configTimestamp

    $patchedTimestamp = [string]$localized.configTimestamp

    if (
        $localizedChanged -or
        $existingTimestamp -lt [DateTimeOffset]::UtcNow.AddDays(30)
    ) {
        $localized.localizedConfig.gfwsl.server =
            $baseUrl

        $patchedTimestamp =
            [DateTimeOffset]::UtcNow.AddYears(1).ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                [Globalization.CultureInfo]::InvariantCulture
            )

        $localized.configTimestamp = $patchedTimestamp
        $localizedChanged = $true
    }

    $stateChanged = (
        [string]$state.profileRestoreMode -ne $profileRestoreMode -or
        [string]$state.localizedRestoreMode -ne $localizedRestoreMode
    )

    if (
        -not $profileChanged -and
        -not $localizedChanged -and
        -not $stateChanged
    ) {
        Remove-Item `
            -LiteralPath (
                Join-Path $runtimeRoot 'auto-repair-error.log'
            ) `
            -Force `
            -ErrorAction SilentlyContinue
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    $backupRoot = Join-Path $installRoot (
        Join-Path 'backup' (
            $timestamp + '-auto-repair'
        )
    )

    New-Item `
        -ItemType Directory `
        -Path $backupRoot `
        -Force |
        Out-Null

    if ($profileChanged) {
        $profileBackup =
            Join-Path $backupRoot 'component_profiles.json'

        Copy-Item `
            -LiteralPath $profilePath `
            -Destination $profileBackup
    }

    if ($localizedChanged) {
        $localizedBackup =
            Join-Path $backupRoot 'LocalizedConfig.json'

        Copy-Item `
            -LiteralPath $localizedConfigPath `
            -Destination $localizedBackup

        $localizedService =
            Get-Service `
                -Name $nvidiaLocalSystemService `
                -ErrorAction Stop

        $localizedServiceWasRunning =
            $localizedService.Status -eq
            [ServiceProcess.ServiceControllerStatus]::Running

        if ($localizedServiceWasRunning) {
            Stop-Service `
                -Name $nvidiaLocalSystemService `
                -Force `
                -ErrorAction Stop

            $localizedServiceStopped = $true

            (Get-Service -Name $nvidiaLocalSystemService).
                WaitForStatus(
                    [ServiceProcess.ServiceControllerStatus]::Stopped,
                    [TimeSpan]::FromSeconds(20)
                )
        }
    }

    if ($profileChanged) {
        Replace-JsonFile `
            -TargetPath $profilePath `
            -Value $profiles `
            -OperationName 'component_profiles.egpu-auto-repair'

        $profileReplaced = $true
    }

    if ($localizedChanged) {
        Replace-JsonFile `
            -TargetPath $localizedConfigPath `
            -Value $localized `
            -OperationName 'LocalizedConfig.egpu-auto-repair'

        $localizedReplaced = $true
    }

    if ($localizedServiceWasRunning) {
        Start-Service `
            -Name $nvidiaLocalSystemService `
            -ErrorAction Stop

        (Get-Service -Name $nvidiaLocalSystemService).
            WaitForStatus(
                [ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(20)
            )



# Suppress NVIDIA App UI respawn after service restart.


foreach ($attempt in 1..12) {


    Get-Process `


        -Name 'NVIDIA App' `


        -ErrorAction SilentlyContinue |


        Where-Object { $_.SessionId -ne 0 } |


        Stop-Process -Force -ErrorAction SilentlyContinue



    Start-Sleep -Milliseconds 250


}

        $localizedServiceStopped = $false
        Start-Sleep -Seconds 2
    }

    $verifyProfiles =
        Get-Content -LiteralPath $profilePath -Raw |
        ConvertFrom-Json

    foreach ($name in @('grd', 'crd')) {
        $entry = @(
            $verifyProfiles |
            Where-Object componentName -eq $name
        )

        if (
            $entry.Count -ne 1 -or
            $entry[0].updateCheckerProfiles.Count -ne 1 -or
            [string]$entry[0].
                updateCheckerProfiles[0].
                otaBaseUrl -ne $baseUrl
        ) {
            throw "Auto-repair verification failed for '$name'."
        }
    }

    $verifyLocalized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json

    if (
        [string]$verifyLocalized.
            localizedConfig.gfwsl.server -ne $baseUrl
    ) {
        throw 'Auto-repair verification failed for LocalizedConfig.'
    }

    if (
        $localizedChanged -and
        [string]$verifyLocalized.configTimestamp -ne $patchedTimestamp
    ) {
        throw 'Auto-repair verification failed for configTimestamp.'
    }

    New-Item `
        -ItemType Directory `
        -Path $runtimeRoot `
        -Force |
        Out-Null

    Add-Content `
        -LiteralPath (
            Join-Path $runtimeRoot 'auto-repair.log'
        ) `
        -Value (
            (Get-Date).ToString('o') +
            " repaired profile=$profileChanged" +
            " localized=$localizedChanged"
        )

    $state.profileRestoreMode = $profileRestoreMode
    $state.localizedRestoreMode = $localizedRestoreMode
    $state.patchedProfileSha256 =
        (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $state.patchedLocalizedConfigSha256 =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    $state.patchedLocalizedConfigTimestamp = $patchedTimestamp
    $state.uiRedirectStatus = 'installed'
    $state.uiRedirectInstalledAt = (Get-Date).ToString('o')

    Replace-JsonFile `
        -TargetPath $statePath `
        -Value $state `
        -OperationName 'state.egpu-auto-repair'

    Remove-Item `
        -LiteralPath (
            Join-Path $runtimeRoot 'auto-repair-error.log'
        ) `
        -Force `
        -ErrorAction SilentlyContinue
}
catch {
    $failure = $_
    $rollbackSucceeded = $true

    if (
        $localizedReplaced -and
        $localizedBackup -and
        (Test-Path -LiteralPath $localizedBackup)
    ) {
        try {
            $service =
                Get-Service `
                    -Name $nvidiaLocalSystemService `
                    -ErrorAction Stop

            if (
                $service.Status -ne
                [ServiceProcess.ServiceControllerStatus]::Stopped
            ) {
                Stop-Service `
                    -Name $nvidiaLocalSystemService `
                    -Force `
                    -ErrorAction Stop

                $localizedServiceStopped = $true

                (Get-Service -Name $nvidiaLocalSystemService).
                    WaitForStatus(
                        [ServiceProcess.ServiceControllerStatus]::Stopped,
                        [TimeSpan]::FromSeconds(20)
                    )
            }

            Copy-Item `
                -LiteralPath $localizedBackup `
                -Destination $localizedConfigPath `
                -Force
        }
        catch {
            $rollbackSucceeded = $false
        }
    }

    if (
        $profileReplaced -and
        $profileBackup -and
        (Test-Path -LiteralPath $profileBackup)
    ) {
        try {
            Copy-Item `
                -LiteralPath $profileBackup `
                -Destination $profilePath `
                -Force
        }
        catch {
            $rollbackSucceeded = $false
        }
    }

    if (
        $localizedServiceWasRunning -and
        $localizedServiceStopped
    ) {
        try {
            Start-Service `
                -Name $nvidiaLocalSystemService `
                -ErrorAction Stop

            (Get-Service -Name $nvidiaLocalSystemService).
                WaitForStatus(
                    [ServiceProcess.ServiceControllerStatus]::Running,
                    [TimeSpan]::FromSeconds(20)
                )



# Suppress NVIDIA App UI respawn after service restart.


foreach ($attempt in 1..12) {


    Get-Process `


        -Name 'NVIDIA App' `


        -ErrorAction SilentlyContinue |


        Where-Object { $_.SessionId -ne 0 } |


        Stop-Process -Force -ErrorAction SilentlyContinue



    Start-Sleep -Milliseconds 250


}

            $localizedServiceStopped = $false
        }
        catch {
            $rollbackSucceeded = $false
        }
    }

    try {
        New-Item `
            -ItemType Directory `
            -Path $runtimeRoot `
            -Force |
            Out-Null

        Write-Utf8NoBom `
            -LiteralPath (
                Join-Path $runtimeRoot 'auto-repair-error.log'
            ) `
            -Value ($failure | Out-String)
    }
    catch {
    }

    if (-not $rollbackSucceeded) {
        throw (
            'Auto repair failed and rollback did not complete: ' +
            $failure.Exception.Message
        )
    }

    throw $failure
}
finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }

    $mutex.Dispose()
}