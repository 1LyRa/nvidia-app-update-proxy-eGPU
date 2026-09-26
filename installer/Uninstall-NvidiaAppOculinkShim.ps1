[CmdletBinding()]
param(
    [switch]$ElevatedPhase
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
$proxyPath = Join-Path $installRoot 'proxy.mjs'
$serviceExePath = Join-Path $installRoot 'NvidiaAppOculinkShim.exe'
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$taskName = 'NVIDIA App OCuLink Driver Shim'
$autoRepairTaskName = 'NVIDIA App eGPU Update Bridge Auto Repair'
$serviceName = 'NvidiaAppOculinkShim'
$nvidiaLocalSystemService = 'NvContainerLocalSystem'
$officialBaseUrl = 'https://gfwsl.geforce.com/'
$mutexName = 'Global\NVIDIAAppOCuLinkDriverShim-Install'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param([string]$LiteralPath, [string]$Value)
    [IO.File]::WriteAllText($LiteralPath, $Value, [Text.UTF8Encoding]::new($false))
}

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

function Assert-SecureInstallRoot {
    $item = Get-Item -LiteralPath $installRoot
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected install directory is a reparse point.'
    }

    $acl = Get-Acl -LiteralPath $installRoot
    if (-not $acl.AreAccessRulesProtected) {
        throw 'The protected install directory unexpectedly inherits permissions.'
    }
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Unexpected install directory owner: $($acl.Owner)"
    }

    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544')
    $writeMask =
        (
            [int][Security.AccessControl.FileSystemRights]::Write -band
            (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)
        ) -bor
        [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        $ruleSid = $rule.IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if (
            $ruleSid -notin $allowedWriters -and
            (([int]$rule.FileSystemRights -band $writeMask) -ne 0)
        ) {
            throw "Unexpected write permission on the protected install directory: $ruleSid"
        }
    }
}

function Assert-ProtectedFile {
    param([string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected file is a reparse point: $LiteralPath"
    }
    $acl = Get-Acl -LiteralPath $LiteralPath
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Unexpected protected file owner: $LiteralPath"
    }
    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544')
    $writeMask =
        (
            [int][Security.AccessControl.FileSystemRights]::Write -band
            (-bnot [int][Security.AccessControl.FileSystemRights]::Synchronize)
        ) -bor
        [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        $ruleSid = $rule.IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if (
            $ruleSid -notin $allowedWriters -and
            (([int]$rule.FileSystemRights -band $writeMask) -ne 0)
        ) {
            throw "Unexpected write permission on protected file '$LiteralPath': $ruleSid"
        }
    }
}

function Assert-RegularTargetFile {
    param([string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "NVIDIA target file is a reparse point: $LiteralPath"
    }
}

function Get-ProtectedBackupPath {
    param(
        [string]$RelativePath,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "The protected $Description backup path is missing."
    }
    $rootFull = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $installRoot $RelativePath))
    if (
        -not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate)
    ) {
        throw "The protected $Description backup path is invalid."
    }
    Assert-ProtectedFile -LiteralPath $candidate
    return $candidate
}

function Write-ProtectedTextAtomically {
    param(
        [string]$TargetPath,
        [string]$Value,
        [string]$OperationName
    )

    $directory = Split-Path -Parent $TargetPath
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory "$OperationName.$operationId.tmp"
    $replaceBackup = Join-Path $directory "$OperationName.$operationId.rollback"
    try {
        Write-Utf8NoBom -LiteralPath $temporaryPath -Value $Value
        $targetAcl = Get-Acl -LiteralPath $TargetPath
        Set-Acl -LiteralPath $temporaryPath -AclObject $targetAcl
        Assert-ProtectedFile -LiteralPath $temporaryPath
        $expectedHash =
            (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
        [IO.File]::Replace($temporaryPath, $TargetPath, $replaceBackup, $true)
        Assert-ProtectedFile -LiteralPath $TargetPath
        if (
            (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash -ne
            $expectedHash
        ) {
            Copy-Item -LiteralPath $replaceBackup -Destination $TargetPath -Force
            throw "Atomic write verification failed for $TargetPath"
        }
        Remove-Item -LiteralPath $replaceBackup -Force
        $replaceBackup = $null
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
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
    $service = Get-Service -Name $nvidiaLocalSystemService -ErrorAction Stop
    if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $nvidiaLocalSystemService -Force -ErrorAction Stop
        $service = Get-Service -Name $nvidiaLocalSystemService
        $service.WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30)
        )
    }
}

function Start-NvidiaLocalizedConfigService {
    $service = Get-Service `
        -Name $nvidiaLocalSystemService `
        -ErrorAction Stop

    if (
        $service.Status -ne
        [ServiceProcess.ServiceControllerStatus]::Running
    ) {
        Start-Service `
            -Name $nvidiaLocalSystemService `
            -ErrorAction Stop
    }

    $service = Get-Service `
        -Name $nvidiaLocalSystemService `
        -ErrorAction Stop

    $service.WaitForStatus(
        [ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(30)
    )

    Start-Sleep -Milliseconds 750
    Stop-NvidiaUiProcesses
}

function Restart-NvidiaLocalizedConfigService {
    Stop-NvidiaLocalizedConfigService
    Start-NvidiaLocalizedConfigService
}

function Restore-RollbackFile {
    param(
        [string]$TargetPath,
        [string]$RollbackPath,
        [string]$OperationName
    )

    $directory = Split-Path -Parent $TargetPath
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory "$OperationName.$operationId.tmp"
    $discardedPath = Join-Path $directory "$OperationName.$operationId.discarded"
    try {
        Copy-Item -LiteralPath $RollbackPath -Destination $temporaryPath -Force
        $targetAcl = Get-Acl -LiteralPath $TargetPath
        Set-Acl -LiteralPath $temporaryPath -AclObject $targetAcl
        [IO.File]::Replace($temporaryPath, $TargetPath, $discardedPath, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $discardedPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ShimHost {
    param([switch]$AllowMissing)

    $service = Get-CimInstance Win32_Service `
        -Filter "Name='$serviceName'" `
        -ErrorAction SilentlyContinue
    if ($service) {
        if (
            [string]$service.StartName -notin @(
                'NT AUTHORITY\LocalService',
                'NT AUTHORITY\LOCAL SERVICE'
            )
        ) {
            throw "Unexpected shim service account: $($service.StartName)"
        }
        $expectedQuotedPath =
            '"' + $serviceExePath + '" --service --config "' + $configPath + '"'
        $expectedUnquotedPath =
            $serviceExePath + ' --service --config ' + $configPath
        if (
            -not [string]::Equals(
                [string]$service.PathName,
                $expectedQuotedPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not [string]::Equals(
                [string]$service.PathName,
                $expectedUnquotedPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "The shim service has an unexpected command line: $($service.PathName)"
        }
        return [pscustomobject]@{
            Kind = 'service'
            ExecutablePath = $serviceExePath
        }
    }

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        if ($AllowMissing) {
            return $null
        }
        throw "The installed shim task was not found: $taskName"
    }
    try {
        $principalText = [string]$task.Principal.UserId
        if ($principalText -match '^S-\d(?:-\d+)+$') {
            $principalSid = (
                [Security.Principal.SecurityIdentifier]::new($principalText)
            ).Value
        } else {
            $principalSid = (
                [Security.Principal.NTAccount]$principalText
            ).Translate([Security.Principal.SecurityIdentifier]).Value
        }
    } catch {
        throw "Unable to validate the shim task account: $($task.Principal.UserId)"
    }
    if (
        $principalSid -ne 'S-1-5-19' -or
        [string]$task.Principal.LogonType -ne 'ServiceAccount'
    ) {
        throw "Unexpected shim task account: $($task.Principal.UserId)"
    }
    if (@($task.Actions).Count -ne 1) {
        throw 'The shim task has an unexpected number of actions.'
    }
    $nodePath = [Environment]::ExpandEnvironmentVariables(
        [string]$task.Actions[0].Execute
    )
    if (
        -not (Test-Path -LiteralPath $nodePath) -or
        [IO.Path]::GetFileName($nodePath) -ne 'node.exe'
    ) {
        throw "The shim task has an unexpected executable: $nodePath"
    }
    $arguments = [string]$task.Actions[0].Arguments
    $expectedArguments = "`"$proxyPath`" `"$configPath`""
    if ($arguments -ne $expectedArguments) {
        throw 'The shim task action does not reference the protected proxy and config.'
    }
    return [pscustomobject]@{
        Kind = 'task'
        ExecutablePath = $nodePath
    }
}

function Stop-ShimHostAndProcess {
    param([AllowNull()][object]$HostInfo)

    if ($HostInfo -and $HostInfo.Kind -eq 'service') {
        & sc.exe stop $serviceName | Out-Null
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $service.WaitForStatus(
                [ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(15)
            )
        }
    } else {
        try {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } catch {
            # The task may already be stopped.
        }
    }

    if (Test-Path -LiteralPath $pidPath) {
        $pidText = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
        $shimPid = 0
        if ([int]::TryParse($pidText.Trim(), [ref]$shimPid)) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
            $executableMatches = $false
            if ($processInfo) {
                if ($HostInfo -and $HostInfo.ExecutablePath) {
                    $executableMatches = [string]::Equals(
                        [IO.Path]::GetFullPath([string]$processInfo.ExecutablePath),
                        [IO.Path]::GetFullPath([string]$HostInfo.ExecutablePath),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } else {
                    $executableMatches = (
                        [IO.Path]::GetFileName(
                            [string]$processInfo.ExecutablePath
                        ) -in @('node.exe', 'NvidiaAppOculinkShim.exe')
                    )
                }
            }
            if (
                $processInfo -and
                $executableMatches -and
                ([string]$processInfo.CommandLine).Contains($configPath)
            ) {
                Stop-Process -Id $shimPid -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-CurrentSessionNvidiaProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process -Name 'NVIDIA App', 'NVIDIA Overlay', 'nvcontainer' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

if (-not $ElevatedPhase) {
    if (Test-IsAdministrator) {
        throw 'Run this uninstaller from a normal, non-administrator PowerShell window. It will request only the elevation it needs.'
    }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-ElevatedPhase'
    )
    $process = Start-Process `
        -FilePath $systemPowerShell `
        -Verb RunAs `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        $errorLog = Join-Path $runtimeRoot 'uninstall-error.log'
        $detail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated phase failed before writing an error log.'
        }
        throw "Uninstallation failed in the elevated phase.`n$detail"
    }
    Write-Output 'Removed the NVIDIA App OCuLink metadata redirection.'
    Write-Output "The protected backup remains at $installRoot."
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$temporaryProfile = $null
$profileAtomicBackup = $null
$profileReplaced = $false
$temporaryLocalizedConfig = $null
$localizedConfigAtomicBackup = $null
$localizedConfigReplaced = $false
$localizedServiceRestartAttempted = $false
$localizedServiceStopped = $false
$shimStopped = $false
$originalStateText = $null
$stateWriteAttempted = $false
$rollbackSucceeded = $true
$shimHost = $null
$autoRepairTaskWasPresent = $false
$autoRepairTaskWasEnabled = $false
$autoRepairTaskDisabled = $false

try {
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        throw 'Another install or uninstall operation is already running.'
    }
    if (-not (Test-Path -LiteralPath $installRoot) -or -not (Test-Path -LiteralPath $statePath)) {
        throw 'The protected shim state was not found.'
    }
    Assert-SecureInstallRoot
    Assert-ProtectedFile -LiteralPath $statePath
    $originalStateText = Get-Content -LiteralPath $statePath -Raw
    $state = $originalStateText | ConvertFrom-Json
    if ($state.status -eq 'uninstalled') {
        $shimHost = Get-ShimHost -AllowMissing
        Stop-ShimHostAndProcess -HostInfo $shimHost
        Stop-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue
        Unregister-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        & sc.exe delete $serviceName | Out-Null
        return
    }
    if ($state.status -notin @('installed', 'installing', 'upgrading')) {
        throw "The shim state is '$($state.status)' and cannot be automatically uninstalled."
    }
    $autoRepairTask =
        Get-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue

    if ($autoRepairTask) {
        $autoRepairTaskWasPresent = $true
        $autoRepairTaskWasEnabled =
            [string]$autoRepairTask.State -ne 'Disabled'

        if ($autoRepairTaskWasEnabled) {
            Disable-ScheduledTask `
                -TaskName $autoRepairTaskName `
                -ErrorAction Stop |
                Out-Null

            $autoRepairTaskDisabled = $true
        }

        Stop-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue
    }

    $localBaseUrl = [string]$state.localBaseUrl
    if (
        $localBaseUrl -notmatch
        '^http://127\.0\.0\.1(?::[0-9]{4,5})?/[a-f0-9]{32,128}/$'
    ) {
        throw 'The protected state contains an invalid loopback URL.'
    }
    $shimHost = Get-ShimHost

    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "The NVIDIA component profile was not found: $profilePath"
    }
    Assert-RegularTargetFile -LiteralPath $profilePath
    $profileBackup = Get-ProtectedBackupPath `
        -RelativePath ([string]$state.profileBackupRelative) `
        -Description 'NVIDIA profile'
    $backupHash = (Get-FileHash -LiteralPath $profileBackup -Algorithm SHA256).Hash
    if ($backupHash -ne [string]$state.originalProfileSha256) {
        throw 'The protected NVIDIA profile backup failed its SHA-256 check.'
    }

    $backupProfiles = Get-Content -LiteralPath $profileBackup -Raw | ConvertFrom-Json
    foreach ($name in @('grd', 'crd')) {
        $entry = @($backupProfiles | Where-Object componentName -eq $name)
        if (
            $entry.Count -ne 1 -or
            [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $officialBaseUrl
        ) {
            throw "The protected backup has an unexpected '$name' endpoint."
        }
    }

    $statePropertyNames = @($state.PSObject.Properties.Name)
    $hasUiRedirectState = (
        $statePropertyNames -contains 'localizedConfigBackupRelative' -or
        $statePropertyNames -contains 'originalLocalizedConfigSha256' -or
        $statePropertyNames -contains 'patchedLocalizedConfigSha256' -or
        $statePropertyNames -contains 'originalLocalizedConfigTimestamp' -or
        $statePropertyNames -contains 'patchedLocalizedConfigTimestamp' -or
        $statePropertyNames -contains 'uiRedirectStatus'
    )
    $localizedRestoreMode = 'none'
    $localizedConfigBackup = $null
    $restoredLocalizedConfig = $null
    $expectedRestoredLocalizedTimestamp = $null
    $reloadLocalizedService = $false
    if ($hasUiRedirectState) {
        if (-not (Test-Path -LiteralPath $localizedConfigPath)) {
            throw "The NVIDIA localized configuration was not found: $localizedConfigPath"
        }
        Assert-RegularTargetFile -LiteralPath $localizedConfigPath
        $localizedConfigBackup = Get-ProtectedBackupPath `
            -RelativePath ([string]$state.localizedConfigBackupRelative) `
            -Description 'localized-config'
        $localizedBackupHash =
            (Get-FileHash -LiteralPath $localizedConfigBackup -Algorithm SHA256).Hash
        if (
            [string]::IsNullOrWhiteSpace([string]$state.originalLocalizedConfigSha256) -or
            $localizedBackupHash -ne [string]$state.originalLocalizedConfigSha256
        ) {
            throw 'The protected localized-config backup failed its SHA-256 check.'
        }
        if (
            $statePropertyNames -contains 'originalLocalizedGfwslServer' -and
            -not [string]::IsNullOrWhiteSpace([string]$state.originalLocalizedGfwslServer) -and
            [string]$state.originalLocalizedGfwslServer -ne $officialBaseUrl
        ) {
            throw 'The protected state contains an unexpected original GFWSL endpoint.'
        }

        $backupLocalizedConfig =
            Get-Content -LiteralPath $localizedConfigBackup -Raw |
            ConvertFrom-Json
        if (
            [string]$backupLocalizedConfig.localizedConfig.gfwsl.server -ne
            $officialBaseUrl
        ) {
            throw 'The protected localized-config backup is not an official configuration.'
        }
        $backupLocalizedTimestamp =
            ConvertTo-StrictUtcTimestampText `
                -Value $backupLocalizedConfig.configTimestamp `
                -Description 'The protected localized-config backup configTimestamp'
        if ($statePropertyNames -contains 'originalLocalizedConfigTimestamp') {
            $stateOriginalLocalizedTimestamp =
                ConvertTo-StrictUtcTimestampText `
                    -Value $state.originalLocalizedConfigTimestamp `
                    -Description 'The protected original localized configTimestamp'
            if ($stateOriginalLocalizedTimestamp -ne $backupLocalizedTimestamp) {
                throw 'The protected state and localized-config backup contain different original timestamps.'
            }
        }

        $patchedLocalizedTimestamp = $null
        if ($statePropertyNames -contains 'patchedLocalizedConfigTimestamp') {
            $patchedLocalizedTimestamp =
                ConvertTo-StrictUtcTimestampText `
                    -Value $state.patchedLocalizedConfigTimestamp `
                    -Description 'The protected patched localized configTimestamp'
        }

        Stop-CurrentSessionNvidiaProcesses
        $localizedServiceStopped = $true
        Stop-NvidiaLocalizedConfigService

        $currentLocalizedHash =
            (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
        if (
            [string]$state.localizedRestoreMode -ne 'selective' -and
            -not [string]::IsNullOrWhiteSpace([string]$state.patchedLocalizedConfigSha256) -and
            $currentLocalizedHash -eq [string]$state.patchedLocalizedConfigSha256
        ) {
            $localizedRestoreMode = 'exact'
            $restoredLocalizedConfig = $backupLocalizedConfig
            $expectedRestoredLocalizedTimestamp = $backupLocalizedTimestamp
        } else {
            $restoredLocalizedConfig =
                Get-Content -LiteralPath $localizedConfigPath -Raw |
                ConvertFrom-Json
            $localizedNeedsSurgicalRestore = $false
            $currentLocalizedServer =
                [string]$restoredLocalizedConfig.localizedConfig.gfwsl.server
            if ($currentLocalizedServer -eq $localBaseUrl) {
                $restoredLocalizedConfig.localizedConfig.gfwsl.server =
                    $officialBaseUrl
                $localizedNeedsSurgicalRestore = $true
            } elseif ($currentLocalizedServer -ne $officialBaseUrl) {
                throw "The current localized GFWSL endpoint changed unexpectedly: $currentLocalizedServer"
            }

            $currentLocalizedTimestamp =
                ConvertTo-StrictUtcTimestampText `
                    -Value $restoredLocalizedConfig.configTimestamp `
                    -Description 'The current localized configTimestamp'
            if (
                -not [string]::IsNullOrWhiteSpace($patchedLocalizedTimestamp) -and
                $currentLocalizedTimestamp -eq $patchedLocalizedTimestamp
            ) {
                $restoredLocalizedConfig.configTimestamp =
                    $backupLocalizedTimestamp
                $currentLocalizedTimestamp = $backupLocalizedTimestamp
                $localizedNeedsSurgicalRestore = $true
            }
            $expectedRestoredLocalizedTimestamp = $currentLocalizedTimestamp
            if ($localizedNeedsSurgicalRestore) {
                $localizedRestoreMode = 'surgical'
            }
        }
        # NvLocalizedConfig may still hold the loopback URL even if the file was
        # independently restored, so reload the owning service in every UI-aware uninstall.
        $reloadLocalizedService = $true
    }

    $currentHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $restoreMode = 'surgical'
    if (
        [string]$state.profileRestoreMode -ne 'selective' -and
        $state.patchedProfileSha256 -and
        $currentHash -eq [string]$state.patchedProfileSha256
    ) {
        $restoreMode = 'exact'
        $restoredProfiles = $backupProfiles
    } else {
        $restoredProfiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $needsChange = $false
        foreach ($name in @('grd', 'crd')) {
            $entry = @($restoredProfiles | Where-Object componentName -eq $name)
            if ($entry.Count -ne 1) {
                throw "The current NVIDIA profile does not contain exactly one '$name' entry."
            }
            $currentBase = [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl
            if ($currentBase -eq $localBaseUrl) {
                $entry[0].updateCheckerProfiles[0].otaBaseUrl = $officialBaseUrl
                $needsChange = $true
            } elseif ($currentBase -ne $officialBaseUrl) {
                throw "The current '$name' endpoint changed unexpectedly: $currentBase"
            }
        }
        if (-not $needsChange) {
            $restoreMode = 'none'
        }
    }

    Stop-CurrentSessionNvidiaProcesses

    if ($restoreMode -ne 'none') {
        $profileDirectory = Split-Path -Parent $profilePath
        $operationId = [Guid]::NewGuid().ToString('N')
        $temporaryProfile = Join-Path $profileDirectory "component_profiles.oculink-uninstall.$operationId.tmp"
        $profileAtomicBackup = Join-Path $profileDirectory "component_profiles.oculink-uninstall.$operationId.rollback"
        if ($restoreMode -eq 'exact') {
            Copy-Item -LiteralPath $profileBackup -Destination $temporaryProfile
        } else {
            Write-Utf8NoBom -LiteralPath $temporaryProfile -Value ($restoredProfiles | ConvertTo-Json -Depth 30)
        }
        $profileAcl = Get-Acl -LiteralPath $profilePath
        Set-Acl -LiteralPath $temporaryProfile -AclObject $profileAcl

        $verification = Get-Content -LiteralPath $temporaryProfile -Raw | ConvertFrom-Json
        foreach ($name in @('grd', 'crd')) {
            $entry = @($verification | Where-Object componentName -eq $name)
            if (
                $entry.Count -ne 1 -or
                [string]$entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $officialBaseUrl
            ) {
                throw "Restore verification failed for '$name'."
            }
        }

        [IO.File]::Replace(
            $temporaryProfile,
            $profilePath,
            $profileAtomicBackup,
            $true
        )
        $profileReplaced = $true
        $postProfiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        foreach ($name in @('grd', 'crd')) {
            $entry = @($postProfiles | Where-Object componentName -eq $name)
            if ($entry.Count -ne 1 -or $entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $officialBaseUrl) {
                throw "Post-restore verification failed for '$name'."
            }
        }
    }

    if ($localizedRestoreMode -ne 'none') {
        $localizedDirectory = Split-Path -Parent $localizedConfigPath
        $operationId = [Guid]::NewGuid().ToString('N')
        $temporaryLocalizedConfig =
            Join-Path $localizedDirectory "LocalizedConfig.oculink-uninstall.$operationId.tmp"
        $localizedConfigAtomicBackup =
            Join-Path $localizedDirectory "LocalizedConfig.oculink-uninstall.$operationId.rollback"
        if ($localizedRestoreMode -eq 'exact') {
            Copy-Item `
                -LiteralPath $localizedConfigBackup `
                -Destination $temporaryLocalizedConfig
        } else {
            Write-Utf8NoBom `
                -LiteralPath $temporaryLocalizedConfig `
                -Value ($restoredLocalizedConfig | ConvertTo-Json -Depth 20)
        }
        $localizedAcl = Get-Acl -LiteralPath $localizedConfigPath
        Set-Acl -LiteralPath $temporaryLocalizedConfig -AclObject $localizedAcl

        $localizedVerification =
            Get-Content -LiteralPath $temporaryLocalizedConfig -Raw |
            ConvertFrom-Json
        if (
            [string]$localizedVerification.localizedConfig.gfwsl.server -ne
                $officialBaseUrl -or
            (
                ConvertTo-StrictUtcTimestampText `
                    -Value $localizedVerification.configTimestamp `
                    -Description 'The staged restored configTimestamp'
            ) -ne
                $expectedRestoredLocalizedTimestamp
        ) {
            throw 'LocalizedConfig restore verification failed.'
        }

        [IO.File]::Replace(
            $temporaryLocalizedConfig,
            $localizedConfigPath,
            $localizedConfigAtomicBackup,
            $true
        )
        $localizedConfigReplaced = $true
        $postLocalizedConfig =
            Get-Content -LiteralPath $localizedConfigPath -Raw |
            ConvertFrom-Json
        if (
            [string]$postLocalizedConfig.localizedConfig.gfwsl.server -ne
                $officialBaseUrl -or
            (
                ConvertTo-StrictUtcTimestampText `
                    -Value $postLocalizedConfig.configTimestamp `
                    -Description 'The restored live configTimestamp'
            ) -ne
                $expectedRestoredLocalizedTimestamp
        ) {
            throw 'Post-restore verification failed for LocalizedConfig.'
        }
    }

    if ($reloadLocalizedService) {
        $localizedServiceRestartAttempted = $true
        Start-NvidiaLocalizedConfigService
        $localizedServiceStopped = $false
        Start-Sleep -Seconds 2
        $liveLocalizedConfig =
            Get-Content -LiteralPath $localizedConfigPath -Raw |
            ConvertFrom-Json
        if (
            [string]$liveLocalizedConfig.localizedConfig.gfwsl.server -ne
            $officialBaseUrl
        ) {
            throw 'NvLocalizedConfig replaced the official endpoint during service startup.'
        }
    }

    Stop-ShimHostAndProcess -HostInfo $shimHost
    $shimStopped = $true

    $state.status = 'uninstalled'
    if ($hasUiRedirectState) {
        $state | Add-Member `
            -NotePropertyName uiRedirectStatus `
            -NotePropertyValue 'uninstalled' `
            -Force
        $state | Add-Member `
            -NotePropertyName uiRedirectUninstalledAt `
            -NotePropertyValue (Get-Date).ToString('o') `
            -Force
    }
    $state | Add-Member -NotePropertyName uninstalledAt -NotePropertyValue (Get-Date).ToString('o') -Force
    $stateWriteAttempted = $true
    Write-ProtectedTextAtomically `
        -TargetPath $statePath `
        -Value ($state | ConvertTo-Json -Depth 10) `
        -OperationName 'state.oculink-uninstalled'

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw 'The shim scheduled task could not be removed.'
    }
    & sc.exe delete $serviceName | Out-Null
    foreach ($attempt in 1..40) {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw 'The shim Windows service could not be removed.'
    }
    if ($profileAtomicBackup) {
        Remove-Item -LiteralPath $profileAtomicBackup -Force -ErrorAction SilentlyContinue
        $profileAtomicBackup = $null
    }
    if ($localizedConfigAtomicBackup) {
        Remove-Item -LiteralPath $localizedConfigAtomicBackup -Force -ErrorAction SilentlyContinue
        $localizedConfigAtomicBackup = $null
    }
    Stop-ScheduledTask `
        -TaskName $autoRepairTaskName `
        -ErrorAction SilentlyContinue

    Unregister-ScheduledTask `
        -TaskName $autoRepairTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

    if (
        Get-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue
    ) {
        throw 'The auto-repair scheduled task could not be removed.'
    }

    Remove-Item -LiteralPath (Join-Path $runtimeRoot 'uninstall-error.log') -Force -ErrorAction SilentlyContinue
} catch {
    $failure = $_
    if (
        $localizedConfigReplaced -and
        $localizedConfigAtomicBackup -and
        (Test-Path -LiteralPath $localizedConfigAtomicBackup)
    ) {
        try {
            if (-not $localizedServiceStopped) {
                $localizedServiceStopped = $true
                Stop-NvidiaLocalizedConfigService
            }
            Restore-RollbackFile `
                -TargetPath $localizedConfigPath `
                -RollbackPath $localizedConfigAtomicBackup `
                -OperationName 'LocalizedConfig.oculink-uninstall-rollback'
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if (
        $profileReplaced -and
        $profileAtomicBackup -and
        (Test-Path -LiteralPath $profileAtomicBackup)
    ) {
        try {
            Restore-RollbackFile `
                -TargetPath $profilePath `
                -RollbackPath $profileAtomicBackup `
                -OperationName 'component_profiles.oculink-uninstall-rollback'
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($stateWriteAttempted -and $originalStateText) {
        try {
            Write-ProtectedTextAtomically `
                -TargetPath $statePath `
                -Value $originalStateText `
                -OperationName 'state.oculink-uninstall-rollback'
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if (
        $autoRepairTaskWasPresent -and
        $autoRepairTaskWasEnabled -and
        $autoRepairTaskDisabled
    ) {
        try {
            if (
                Get-ScheduledTask `
                    -TaskName $autoRepairTaskName `
                    -ErrorAction SilentlyContinue
            ) {
                Enable-ScheduledTask `
                    -TaskName $autoRepairTaskName `
                    -ErrorAction Stop |
                    Out-Null
            }
        }
        catch {
            $rollbackSucceeded = $false
        }
    }
    if ($shimStopped) {
        try {
            if ($shimHost.Kind -eq 'service') {
                Start-Service -Name $serviceName -ErrorAction Stop
            } else {
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            }
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($localizedServiceStopped -or $localizedServiceRestartAttempted) {
        try {
            Start-NvidiaLocalizedConfigService
            $localizedServiceStopped = $false
        } catch {
            $rollbackSucceeded = $false
        }
    }

    foreach ($cleanupPath in @(
        $temporaryProfile,
        $profileAtomicBackup,
        $temporaryLocalizedConfig,
        $localizedConfigAtomicBackup
    )) {
        if ($cleanupPath) {
            Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        $failureText = ($failure | Out-String)
        if (-not $rollbackSucceeded) {
            $failureText += "`r`nAutomatic rollback was incomplete; do not retry until the protected state and NVIDIA configuration have been inspected."
        }
        Write-Utf8NoBom `
            -LiteralPath (Join-Path $runtimeRoot 'uninstall-error.log') `
            -Value $failureText
    } catch {
        # The parent process will still receive a non-zero exit code.
    }
    throw $failure
} finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
