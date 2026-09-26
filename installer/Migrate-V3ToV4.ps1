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
$installRoot = Join-Path $programData 'NVIDIAAppOCuLinkDriverShim'
$runtimeRoot = Join-Path $installRoot 'runtime'
$statePath = Join-Path $installRoot 'state.json'
$configPath = Join-Path $installRoot 'config.json'
$legacyProxyPath = Join-Path $installRoot 'proxy.mjs'
$serviceExePath = Join-Path $installRoot 'NvidiaAppOculinkShim.exe'
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$taskName = 'NVIDIA App OCuLink Driver Shim'
$serviceName = 'NvidiaAppOculinkShim'
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

function Write-Utf8NoBom {
    param([string]$LiteralPath, [string]$Value)
    [IO.File]::WriteAllText(
        $LiteralPath,
        $Value,
        [Text.UTF8Encoding]::new($false)
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
    throw 'The v4 service executable was not found. Build or unpack the payload first.'
}

function Assert-SecureInstallRoot {
    $item = Get-Item -LiteralPath $installRoot
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected install root must not be a reparse point.'
    }
    $acl = Get-Acl -LiteralPath $installRoot
    if (-not $acl.AreAccessRulesProtected) {
        throw 'The protected install root still inherits permissions.'
    }
    $ownerSid = (
        [Security.Principal.NTAccount]$acl.Owner
    ).Translate([Security.Principal.SecurityIdentifier]).Value
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Unexpected protected install-root owner: $($acl.Owner)"
    }
}

function Assert-ProtectedFile {
    param([string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Required protected file was not found: $LiteralPath"
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected file must not be a reparse point: $LiteralPath"
    }
    $resolved = (Resolve-Path -LiteralPath $LiteralPath).Path
    if (-not $resolved.StartsWith(
        ($installRoot.TrimEnd('\') + '\'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Protected file escaped the install root: $resolved"
    }
}

function Get-LegacyTaskInfo {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $principalText = [string]$task.Principal.UserId
    $principalSid = if ($principalText -match '^S-\d(?:-\d+)+$') {
        [Security.Principal.SecurityIdentifier]::new($principalText).Value
    } else {
        (
            [Security.Principal.NTAccount]$principalText
        ).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if (
        $principalSid -ne 'S-1-5-19' -or
        [string]$task.Principal.LogonType -ne 'ServiceAccount' -or
        @($task.Actions).Count -ne 1
    ) {
        throw 'The v3 task identity or action count is unexpected.'
    }
    $nodePath = [Environment]::ExpandEnvironmentVariables(
        [string]$task.Actions[0].Execute
    )
    $expectedArguments = "`"$legacyProxyPath`" `"$configPath`""
    if (
        [IO.Path]::GetFileName($nodePath) -ne 'node.exe' -or
        -not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or
        [string]$task.Actions[0].Arguments -ne $expectedArguments
    ) {
        throw 'The v3 task does not reference the protected proxy/config.'
    }
    return [pscustomobject]@{
        Task = $task
        NodePath = $nodePath
        Xml = Export-ScheduledTask -TaskName $taskName
    }
}

function Stop-LegacyHelper {
    param([string]$NodePath)

    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return
    }
    $shimPid = 0
    $pidText = [string](
        Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue
    )
    if ([int]::TryParse($pidText.Trim(), [ref]$shimPid)) {
        $process = Get-CimInstance Win32_Process `
            -Filter "ProcessId=$shimPid" `
            -ErrorAction SilentlyContinue
        if (
            $process -and
            [string]::Equals(
                [IO.Path]::GetFullPath([string]$process.ExecutablePath),
                [IO.Path]::GetFullPath($NodePath),
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            ([string]$process.CommandLine).Contains($legacyProxyPath) -and
            ([string]$process.CommandLine).Contains($configPath)
        ) {
            Stop-Process -Id $shimPid -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Remove-V4Service {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }
    & sc.exe stop $serviceName | Out-Null
    try {
        $service.WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(15)
        )
    } catch {
    }
    & sc.exe delete $serviceName | Out-Null
    foreach ($attempt in 1..40) {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'The temporary v4 service could not be removed.'
}

function Register-V4Service {
    $binaryPath =
        '"' + $serviceExePath + '" --service --config "' + $configPath + '"'
    & sc.exe create $serviceName `
        binPath= $binaryPath `
        start= delayed-auto `
        obj= 'NT AUTHORITY\LocalService' `
        DisplayName= 'NVIDIA App OCuLink Update Bridge' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows service registration failed.'
    }
    & sc.exe description $serviceName `
        'Loopback-only NVIDIA driver metadata normalizer for OCuLink desktop GPUs.' |
        Out-Null
    & sc.exe failure $serviceName `
        reset= 86400 `
        actions= 'restart/5000/restart/15000/restart/60000' | Out-Null
    & sc.exe failureflag $serviceName 1 | Out-Null
}

function Assert-ListenerPortAvailable {
    param([int]$ListenerPort)

    $listener = Get-NetTCPConnection `
        -LocalAddress '127.0.0.1' `
        -LocalPort $ListenerPort `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        return
    }
    $owner = Get-Process `
        -Id ([int]$listener.OwningProcess) `
        -ErrorAction SilentlyContinue
    $description = if ($owner) {
        "$($owner.ProcessName) (PID $($owner.Id))"
    } else {
        "PID $($listener.OwningProcess)"
    }
    throw "127.0.0.1:$ListenerPort is still used by $description."
}

function Start-And-TestV4Service {
    param([object]$Config)

    Start-Service -Name $serviceName
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
        throw 'The v4 Windows service did not become healthy.'
    }

    $process = Get-CimInstance Win32_Process `
        -Filter "ProcessId=$($health.pid)" `
        -ErrorAction Stop
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
    if (
        $owner.ReturnValue -ne 0 -or
        [string]$owner.Sid -ne 'S-1-5-19' -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$process.ExecutablePath),
            [IO.Path]::GetFullPath($serviceExePath),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'The v4 helper identity or executable path is unexpected.'
    }

    $payload = [ordered]@{
        gcV = '11.0.8.299'
        lg = '1033'
        gLg = 'en-US'
        dIDa = @(Get-PresentNvidiaDeviceIds)
        osC = '10.0.26200'
        osB = '8973'
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
    $encoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
    $metadata = Invoke-RestMethod `
        -Uri ($baseUrl + $endpoint + $encoded) `
        -TimeoutSec 40
    $downloadUri = [Uri]$metadata.DriverAttributes.DownloadURLAdmin
    $latestVersion =
        [string]$metadata.criteria.IsDispDriverNewer.latestDispDriverVersion
    if (
        [string]::IsNullOrWhiteSpace($latestVersion) -or
        $downloadUri.Scheme -ne 'https' -or
        $downloadUri.Host -notmatch '(^|\.)nvidia\.com$'
    ) {
        throw 'The live NVIDIA metadata validation failed.'
    }
    return [pscustomobject]@{
        BaseUrl = $baseUrl
        LatestVersion = $latestVersion
        Pid = [int]$health.pid
    }
}

function Write-StateAtomically {
    param([string]$Text)

    $temporary = Join-Path $installRoot (
        'state.v4-migration.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $discarded = $temporary + '.discarded'
    try {
        Write-Utf8NoBom -LiteralPath $temporary -Value $Text
        $acl = Get-Acl -LiteralPath $statePath
        Set-Acl -LiteralPath $temporary -AclObject $acl
        [IO.File]::Replace($temporary, $statePath, $discarded, $true)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $discarded -Force -ErrorAction SilentlyContinue
    }
}

if (-not $ElevatedPhase) {
    $resolvedBinary = Resolve-ServiceBinary -RequestedPath $ServiceBinary
    if (Test-IsAdministrator) {
        throw 'Run migration from a normal user window; it will request UAC itself.'
    }
    & $resolvedBinary --self-test
    if ($LASTEXITCODE -ne 0) {
        throw 'The v4 service binary failed its built-in self-test.'
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
        $errorLog = Join-Path $runtimeRoot 'migration-error.log'
        $detail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated migration failed before writing its diagnostic log.'
        }
        throw "Migration failed.`n$detail"
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if (
        $state.status -ne 'installed' -or
        [int]$state.proxyVersion -ne 4 -or
        [string]$state.hostKind -ne 'windows-service'
    ) {
        throw 'Post-migration protected state validation failed.'
    }
    Write-Output 'Migrated the NVIDIA App OCuLink bridge to the v4 Windows service.'
    Write-Output "NVIDIA currently recommends driver $($state.verifiedLatestVersion)."
    Write-Output 'The original protected NVIDIA configuration backups were preserved.'
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated migration phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$legacyTask = $null
$legacyTaskRemoved = $false
$legacyStopped = $false
$serviceRegistered = $false
$serviceStarted = $false
$stateWriteAttempted = $false
$originalStateText = $null
$migrationRoot = $null
$serviceBinaryBackup = $null
$resolvedServiceBinary = $null
$rollbackSucceeded = $true

try {
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        throw 'Another install, migration, or uninstall operation is running.'
    }
    $resolvedServiceBinary =
        Resolve-ServiceBinary -RequestedPath $ServiceBinary
    if (
        -not (Test-Path -LiteralPath $installRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $statePath -PathType Leaf)
    ) {
        throw 'An installed v3 protected state was not found.'
    }
    Assert-SecureInstallRoot
    foreach ($path in @($statePath, $configPath, $legacyProxyPath)) {
        Assert-ProtectedFile -LiteralPath $path
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "The v4 service already exists: $serviceName"
    }

    $originalStateText = Get-Content -LiteralPath $statePath -Raw
    $state = $originalStateText | ConvertFrom-Json
    if (
        $state.status -ne 'installed' -or
        [int]$state.proxyVersion -ne 3 -or
        [int]$state.listenerPort -ne 80 -or
        [string]$state.uiRedirectStatus -ne 'installed'
    ) {
        throw 'Only a healthy installed v3 UI redirect can be migrated automatically.'
    }
    if (
        (Get-FileHash -LiteralPath $legacyProxyPath -Algorithm SHA256).Hash -ne
            [string]$state.proxySha256 -or
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne
            [string]$state.configSha256
    ) {
        throw 'The installed v3 helper/config hash no longer matches protected state.'
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (
        [int]$config.port -ne 80 -or
        [string]$config.token -notmatch '^[a-f0-9]{32,128}$' -or
        [IO.Path]::GetFullPath([string]$config.runtimeDirectory) -ne
            [IO.Path]::GetFullPath($runtimeRoot)
    ) {
        throw 'The installed v3 helper configuration is invalid.'
    }
    $legacyTask = Get-LegacyTaskInfo

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $migrationRelative = Join-Path 'backup' ($timestamp + '-v4-migration')
    $migrationRoot = Join-Path $installRoot $migrationRelative
    New-Item -ItemType Directory -Path $migrationRoot -Force | Out-Null
    Write-Utf8NoBom `
        -LiteralPath (Join-Path $migrationRoot 'scheduled-task.xml') `
        -Value ([string]$legacyTask.Xml)
    Write-Utf8NoBom `
        -LiteralPath (Join-Path $migrationRoot 'state.before-v4.json') `
        -Value $originalStateText
    Copy-Item `
        -LiteralPath $legacyProxyPath `
        -Destination (Join-Path $migrationRoot 'proxy.v3.mjs')
    if (Test-Path -LiteralPath $serviceExePath) {
        $serviceBinaryBackup = Join-Path $migrationRoot 'NvidiaAppOculinkShim.previous.exe'
        Copy-Item -LiteralPath $serviceExePath -Destination $serviceBinaryBackup
    }

    Stop-LegacyHelper -NodePath $legacyTask.NodePath
    $legacyStopped = $true
    Assert-ListenerPortAvailable -ListenerPort ([int]$config.port)
    Copy-Item `
        -LiteralPath $resolvedServiceBinary `
        -Destination $serviceExePath `
        -Force
    $serviceHash =
        (Get-FileHash -LiteralPath $serviceExePath -Algorithm SHA256).Hash
    if (
        $serviceHash -ne
        (Get-FileHash -LiteralPath $resolvedServiceBinary -Algorithm SHA256).Hash
    ) {
        throw 'The installed v4 service executable failed SHA-256 verification.'
    }

    Register-V4Service
    $serviceRegistered = $true
    $verification = Start-And-TestV4Service -Config $config
    $serviceStarted = $true

    Unregister-ScheduledTask `
        -TaskName $taskName `
        -Confirm:$false `
        -ErrorAction Stop
    $legacyTaskRemoved = $true
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw 'The retired v3 scheduled task could not be removed.'
    }

    $state.status = 'installed'
    $state.proxyVersion = 4
    $state.verifiedLatestVersion = $verification.LatestVersion
    $state | Add-Member `
        -NotePropertyName detectedDeviceIds `
        -NotePropertyValue @(Get-PresentNvidiaDeviceIds) `
        -Force
    $state.proxySha256 = $serviceHash
    $state | Add-Member `
        -NotePropertyName productVersion `
        -NotePropertyValue '4.0.0' `
        -Force
    $state | Add-Member `
        -NotePropertyName hostKind `
        -NotePropertyValue 'windows-service' `
        -Force
    $state | Add-Member `
        -NotePropertyName serviceName `
        -NotePropertyValue $serviceName `
        -Force
    $state | Add-Member `
        -NotePropertyName serviceBinaryRelative `
        -NotePropertyValue 'NvidiaAppOculinkShim.exe' `
        -Force
    $state | Add-Member `
        -NotePropertyName serviceBinarySha256 `
        -NotePropertyValue $serviceHash `
        -Force
    $state | Add-Member `
        -NotePropertyName migratedFrom `
        -NotePropertyValue 'v3-scheduled-task' `
        -Force
    $state | Add-Member `
        -NotePropertyName migrationBackupRelative `
        -NotePropertyValue $migrationRelative `
        -Force
    $state | Add-Member `
        -NotePropertyName migratedAt `
        -NotePropertyValue (Get-Date).ToString('o') `
        -Force
    $stateWriteAttempted = $true
    Write-StateAtomically -Text ($state | ConvertTo-Json -Depth 12)
    Remove-Item `
        -LiteralPath (Join-Path $runtimeRoot 'migration-error.log') `
        -Force `
        -ErrorAction SilentlyContinue
    Install-NvidiaAppAutoRepairTask `
        -InstallRoot $installRoot

} catch {
    $failure = $_
    if ($serviceRegistered) {
        try {
            Remove-V4Service
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($stateWriteAttempted -and $originalStateText) {
        try {
            Write-StateAtomically -Text $originalStateText
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($legacyTaskRemoved -and $legacyTask) {
        try {
            Register-ScheduledTask `
                -TaskName $taskName `
                -Xml ([string]$legacyTask.Xml) `
                -Force | Out-Null
        } catch {
            $rollbackSucceeded = $false
        }
    }
    if ($legacyStopped -and $legacyTask) {
        try {
            Start-ScheduledTask -TaskName $taskName
        } catch {
            $rollbackSucceeded = $false
        }
    }
    try {
        if ($serviceBinaryBackup) {
            Copy-Item `
                -LiteralPath $serviceBinaryBackup `
                -Destination $serviceExePath `
                -Force
        } else {
            Remove-Item `
                -LiteralPath $serviceExePath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    } catch {
        $rollbackSucceeded = $false
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $failureText = $failure | Out-String
    if (-not $rollbackSucceeded) {
        $failureText +=
            "`r`nAutomatic rollback was incomplete. Do not retry before inspection."
    }
    try {
        Write-Utf8NoBom `
            -LiteralPath (Join-Path $runtimeRoot 'migration-error.log') `
            -Value $failureText
    } catch {
    }
    throw $failure
} finally {
    if ($lockAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
