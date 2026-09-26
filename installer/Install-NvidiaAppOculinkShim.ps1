[CmdletBinding()]
param(
    [int]$Port = 80,
    [switch]$ElevatedPhase,
    [string]$ServiceBinary
)

$ErrorActionPreference = 'Stop'

$appExe = 'C:\Program Files\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe'
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
$pidPath = Join-Path $runtimeRoot 'shim.pid'
$taskName = 'NVIDIA App OCuLink Driver Shim'
$autoRepairTaskName = 'NVIDIA App eGPU Update Bridge Auto Repair'
$autoRepairSourcePath = Join-Path $PSScriptRoot 'AutoRepair-NvidiaAppOculinkShim.ps1'
$autoRepairScriptPath = Join-Path $installRoot 'AutoRepair-NvidiaAppOculinkShim.ps1'
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
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8NoBom {
    param([string]$LiteralPath, [string]$Value)
    [IO.File]::WriteAllText($LiteralPath, $Value, [Text.UTF8Encoding]::new($false))
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

function ConvertTo-HexString {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-StrictUtcTimestampText {
    param([AllowNull()][object]$Value, [string]$Description)

    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [DateTime]) {
        $dateValue = [DateTime]$Value
        if ($dateValue.Kind -ne [DateTimeKind]::Utc) {
            throw "$Description is not UTC."
        }
        return $dateValue.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if (
        -not [DateTimeOffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        ) -or
        $parsed.Offset -ne [TimeSpan]::Zero
    ) {
        throw "$Description is not a valid UTC timestamp."
    }
    return $parsed.UtcDateTime.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Test-SecureInstallRoot {
    param([string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }

    $acl = Get-Acl -LiteralPath $LiteralPath
    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }

    try {
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        return $false
    }
    if ($ownerSid -notin @('S-1-5-18', 'S-1-5-32-544')) {
        return $false
    }

    $allowedWriters = @('S-1-5-18', 'S-1-5-32-544')
    # ReadAndExecute and Write both include Synchronize. Exclude that shared
    # bit so a read-only rule is not misclassified as writable.
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
        try {
            $ruleSid = $rule.IdentityReference.Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        } catch {
            return $false
        }
        if (
            $ruleSid -notin $allowedWriters -and
            (([int]$rule.FileSystemRights -band $writeMask) -ne 0)
        ) {
            return $false
        }
    }

    return $true
}

function Set-SecureInstallRoot {
    param([string]$LiteralPath)

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $acl.SetOwner($administrators)
    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    foreach ($sid in @($localService, $users)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    Set-Acl -LiteralPath $LiteralPath -AclObject $acl
}

function Protect-InstallTree {
    param([string]$LiteralPath)

    Set-SecureInstallRoot -LiteralPath $LiteralPath
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force |
        Where-Object {
            -not $_.FullName.StartsWith(
                ($runtimeRoot.TrimEnd('\') + '\'),
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not [string]::Equals(
                $_.FullName,
                $runtimeRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        ForEach-Object {
        $itemAcl = Get-Acl -LiteralPath $_.FullName
        $itemAcl.SetAccessRuleProtection($false, $true)
        $itemAcl.SetOwner($administrators)
        Set-Acl -LiteralPath $_.FullName -AclObject $itemAcl
    }
}

function Set-SecureRuntimeRoot {
    param([string]$LiteralPath)

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl.SetOwner($administrators)

    foreach ($sid in @($system, $administrators)) {
        $acl.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
        )
    }
    $acl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $localService,
            [Security.AccessControl.FileSystemRights]::Modify,
            $inheritance,
            $propagation,
            $allow
        )
    )
    $acl.AddAccessRule(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $users,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow
        )
    )
    Set-Acl -LiteralPath $LiteralPath -AclObject $acl
}

function Register-AutoRepairTask {
    $powerShellPath = Join-Path $env:SystemRoot (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )

    if (-not (
        Test-Path -LiteralPath $powerShellPath -PathType Leaf
    )) {
        throw "Windows PowerShell was not found: $powerShellPath"
    }

    $action = New-ScheduledTaskAction `
        -Execute $powerShellPath `
        -Argument (
            '-NoLogo -NoProfile -NonInteractive ' +
            '-ExecutionPolicy Bypass -File "' +
            $autoRepairScriptPath +
            '"'
        )

    $startupTrigger =
        New-ScheduledTaskTrigger -AtStartup

    $intervalTrigger =
        New-ScheduledTaskTrigger `
            -Once `
            -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 15) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

    $principal =
        New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

    $settings =
        New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask `
        -TaskName $autoRepairTaskName `
        -Action $action `
        -Trigger @(
            $startupTrigger,
            $intervalTrigger
        ) `
        -Principal $principal `
        -Settings $settings `
        -Description (
            'Restores the NVIDIA App metadata redirect ' +
            'after NVIDIA App updates.'
        ) `
        -ErrorAction Stop |
        Out-Null
}

function Stop-V4ServiceAndProcess {
    try {
        & sc.exe stop $serviceName | Out-Null
        foreach ($attempt in 1..60) {
            $service = Get-Service `
                -Name $serviceName `
                -ErrorAction SilentlyContinue
            if (-not $service -or $service.Status -eq 'Stopped') {
                break
            }
            Start-Sleep -Milliseconds 250
        }
    } catch {
        # The service may already be stopped.
    }

    if (Test-Path -LiteralPath $pidPath) {
        $pidText = [string](Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue)
        $shimPid = 0
        if ([int]::TryParse($pidText.Trim(), [ref]$shimPid)) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$shimPid" -ErrorAction SilentlyContinue
            if (
                $processInfo -and
                [string]::Equals(
                    [IO.Path]::GetFullPath([string]$processInfo.ExecutablePath),
                    [IO.Path]::GetFullPath($serviceExePath),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                ([string]$processInfo.CommandLine).Contains($configPath)
            ) {
                Stop-Process -Id $shimPid -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
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
    throw "127.0.0.1:$ListenerPort is already used by $description."
}

function Remove-V4Service {
    Stop-V4ServiceAndProcess
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        & sc.exe delete $serviceName | Out-Null
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

function Get-ShimMetadata {
    param([string]$BaseUrl, [string[]]$DeviceIds)

    $windowsVersion = [Environment]::OSVersion.Version
    $payload = [ordered]@{
        gcV = '11.0.8.299'
        lg = '1033'
        gLg = 'en-US'
        dIDa = $DeviceIds
        osC = "$($windowsVersion.Major).$($windowsVersion.Minor)"
        osB = [string]$windowsVersion.Build
        is6 = '1'
        GFPV = '0'
        dch = '1'
        iLp = '1'
        isB = '0'
        gIsB = '0'
        isO = '1'
        prvMd = '0'
        IsQ = '0'
        upCRD = '0'
        isCRD = '0'
        isInst = '1'
    }
    $encoded = [Uri]::EscapeDataString(($payload | ConvertTo-Json -Compress))
    $endpoint = 'nvidia_web_services/controller.gfeclientcontent.NG.php/com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/'
    return Invoke-RestMethod -Uri ($BaseUrl + $endpoint + $encoded) -TimeoutSec 40
}

function Stop-CurrentSessionNvidiaProcesses {
    $sessionId = (Get-Process -Id $PID).SessionId
    Get-Process -Name 'NVIDIA App', 'NVIDIA Overlay', 'nvcontainer' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Port -ne 80 -and ($Port -lt 1024 -or $Port -gt 65535)) {
    throw 'Port must be 80 or between 1024 and 65535.'
}

if (-not $ElevatedPhase) {
    if (Test-IsAdministrator) {
        throw 'Run this installer from a normal, non-administrator PowerShell window. It will request only the elevation it needs.'
    }

    $resolvedBinary = Resolve-ServiceBinary -RequestedPath $ServiceBinary
    & $resolvedBinary --self-test
    if ($LASTEXITCODE -ne 0) {
        throw 'The v4 service binary failed its built-in self-test.'
    }
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Port', $Port,
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
        $errorLog = Join-Path $runtimeRoot 'install-error.log'
        $detail = if (Test-Path -LiteralPath $errorLog) {
            Get-Content -LiteralPath $errorLog -Raw
        } else {
            'The elevated phase failed before writing an error log.'
        }
        throw "Installation failed in the elevated phase.`n$detail"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $baseUrl =
        Get-LoopbackBaseUrl `
            -Port ([int]$config.port) `
            -Token ([string]$config.token)
    $health = Invoke-RestMethod -Uri ($baseUrl + 'health') -TimeoutSec 5
    if ($health.status -ne 'ok' -or [int]$health.version -ne 4) {
        throw 'The installed helper is not healthy.'
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Write-Output 'Installed the NVIDIA App OCuLink Update Bridge service.'
    Write-Output "NVIDIA metadata check returned: $($state.verifiedLatestVersion)"
    Write-Output "Protected backup: $(Join-Path $installRoot $state.profileBackupRelative)"
    Write-Output "Runtime log: $(Join-Path $runtimeRoot 'shim.log')"
    Write-Output 'No graphics driver was downloaded or installed.'
    return
}

if (-not (Test-IsAdministrator)) {
    throw 'The elevated phase requires administrator rights.'
}

$mutex = [Threading.Mutex]::new($false, $mutexName)
$lockAcquired = $false
$serviceRegistered = $false
$autoRepairTaskRegistered = $false
$profileReplaced = $false
$temporaryProfile = $null
$profileAtomicBackup = $null
$profileBackup = $null
$originalProfileHash = $null
$localizedConfigReplaced = $false
$temporaryLocalizedConfig = $null
$localizedAtomicBackup = $null
$localizedBackup = $null
$originalLocalizedHash = $null
$localizedServiceStopped = $false
$state = $null
$resolvedServiceBinary = $null
$installRootTrusted = $false

try {
    $lockAcquired = $mutex.WaitOne(0)
    if (-not $lockAcquired) {
        throw 'Another install or uninstall operation is already running.'
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "NVIDIA App update profile was not found: $profilePath"
    }
    if (-not (Test-Path -LiteralPath $localizedConfigPath)) {
        throw "NVIDIA App localized configuration was not found: $localizedConfigPath"
    }
    if (-not (Test-Path -LiteralPath $appExe)) {
        throw "NVIDIA App executable was not found: $appExe"
    }

    if (-not (
        Test-Path -LiteralPath $autoRepairSourcePath -PathType Leaf
    )) {
        throw "Auto-repair script was not found: $autoRepairSourcePath"
    }
    $resolvedServiceBinary =
        Resolve-ServiceBinary -RequestedPath $ServiceBinary

    if (Test-Path -LiteralPath $installRoot) {
        if (-not (Test-SecureInstallRoot -LiteralPath $installRoot)) {
            throw "The existing install directory is not trusted: $installRoot"
        }
        $installRootTrusted = $true
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw 'The protected install directory exists without state; review it before reinstalling.'
        }
        $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($existingState.status -ne 'uninstalled') {
            throw "The shim state is '$($existingState.status)'. Run the uninstaller before reinstalling."
        }
    } else {
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        Set-SecureInstallRoot -LiteralPath $installRoot
        $installRootTrusted = $true
    }

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "The legacy scheduled task '$taskName' still exists."
    }
    if (
        Get-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue
    ) {
        throw "The auto-repair scheduled task '$autoRepairTaskName' already exists."
    }
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "The Windows service '$serviceName' already exists."
    }
    Assert-ListenerPortAvailable -ListenerPort $Port

    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
    Remove-Item -LiteralPath (Join-Path $runtimeRoot 'install-error.log') -Force -ErrorAction SilentlyContinue

    Copy-Item `
        -LiteralPath $resolvedServiceBinary `
        -Destination $serviceExePath `
        -Force

    Copy-Item `
        -LiteralPath $autoRepairSourcePath `
        -Destination $autoRepairScriptPath `
        -Force

    if (
        (
            Get-FileHash `
                -LiteralPath $autoRepairScriptPath `
                -Algorithm SHA256
        ).Hash -ne
        (
            Get-FileHash `
                -LiteralPath $autoRepairSourcePath `
                -Algorithm SHA256
        ).Hash
    ) {
        throw 'The installed auto-repair script failed SHA-256 verification.'
    }

    $tokenBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($tokenBytes)
    } finally {
        $rng.Dispose()
    }
    $token = ConvertTo-HexString -Bytes $tokenBytes
    $localBaseUrl = Get-LoopbackBaseUrl -Port $Port -Token $token
    $config = [ordered]@{
        port = $Port
        token = $token
        runtimeDirectory = $runtimeRoot
    }
    Write-Utf8NoBom -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 4)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot

    Register-V4Service
    $serviceRegistered = $true
    Start-Service -Name $serviceName

    $health = $null
    foreach ($attempt in 1..40) {
        try {
            $health = Invoke-RestMethod -Uri ($localBaseUrl + 'health') -TimeoutSec 2
            if ($health.status -eq 'ok') {
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $health -or $health.status -ne 'ok') {
        throw 'The limited-token loopback v4 service did not become healthy.'
    }
    $helperProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($health.pid)" -ErrorAction Stop
    $helperOwner = Invoke-CimMethod -InputObject $helperProcessInfo -MethodName GetOwnerSid
    if (
        $helperOwner.ReturnValue -ne 0 -or
        [string]$helperOwner.Sid -ne 'S-1-5-19' -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$helperProcessInfo.ExecutablePath),
            [IO.Path]::GetFullPath($serviceExePath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([string]$helperProcessInfo.CommandLine).Contains($configPath)
    ) {
        throw 'The helper process identity did not match the protected LocalService service.'
    }

    $detectedDeviceIds = @(Get-PresentNvidiaDeviceIds)
    $metadata =
        Get-ShimMetadata `
            -BaseUrl $localBaseUrl `
            -DeviceIds $detectedDeviceIds
    $supported = ([string]$metadata.criteria.IsSupported.state).ToLowerInvariant()
    $latestText = [string]$metadata.criteria.IsDispDriverNewer.latestDispDriverVersion
    $downloadUri = [Uri]$metadata.DriverAttributes.DownloadURLAdmin
    if ($supported -notin @('1', 'true')) {
        throw 'The NVIDIA metadata endpoint did not mark this GPU as supported.'
    }
    $parsedLatest = [version]'0.0'
    if (-not [version]::TryParse($latestText, [ref]$parsedLatest)) {
        throw "The NVIDIA metadata preflight returned an invalid version: $latestText"
    }
    if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notmatch '(^|\.)nvidia\.com$') {
        throw "The NVIDIA metadata preflight returned an unexpected download host: $downloadUri"
    }

    Stop-CurrentSessionNvidiaProcesses
    Stop-NvidiaLocalizedConfigService
    $localizedServiceStopped = $true

    # Windows PowerShell 5.1 emits a top-level JSON array as one pipeline item.
    # Assign directly so foreach receives the actual profile elements.
    $profiles = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $changedComponents = @()
    foreach ($profile in $profiles) {
        if ($profile.componentName -in @('grd', 'crd')) {
            if (-not $profile.updateCheckerProfiles -or $profile.updateCheckerProfiles.Count -lt 1) {
                throw "NVIDIA component '$($profile.componentName)' has no update checker profile."
            }
            $currentBase = [string]$profile.updateCheckerProfiles[0].otaBaseUrl
            if ($currentBase -ne $officialBaseUrl) {
                throw "Unexpected NVIDIA OTA base URL for '$($profile.componentName)': $currentBase"
            }
            $profile.updateCheckerProfiles[0].otaBaseUrl = $localBaseUrl
            $changedComponents += $profile.componentName
        }
    }
    if (@($changedComponents | Sort-Object -Unique).Count -ne 2) {
        throw 'Expected exactly one grd and one crd component profile.'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRelative = Join-Path (Join-Path 'backup' $timestamp) 'component_profiles.json'
    $profileBackup = Join-Path $installRoot $backupRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $profileBackup) -Force | Out-Null
    Copy-Item -LiteralPath $profilePath -Destination $profileBackup
    $originalProfileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $profileBackup -Algorithm SHA256).Hash -ne $originalProfileHash) {
        throw 'The protected NVIDIA profile backup failed verification.'
    }

    $localizedConfig =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json
    if (
        [string]$localizedConfig.localizedConfig.gfwsl.server -ne
        $officialBaseUrl
    ) {
        throw "Unexpected NVIDIA GFWSL server: $($localizedConfig.localizedConfig.gfwsl.server)"
    }
    $originalLocalizedTimestamp =
        ConvertTo-StrictUtcTimestampText `
            -Value $localizedConfig.configTimestamp `
            -Description 'The original localized configTimestamp'
    $localizedBackupRelative =
        Join-Path (Join-Path 'backup' $timestamp) 'LocalizedConfig.json'
    $localizedBackup = Join-Path $installRoot $localizedBackupRelative
    Copy-Item `
        -LiteralPath $localizedConfigPath `
        -Destination $localizedBackup
    $originalLocalizedHash =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    if (
        (Get-FileHash -LiteralPath $localizedBackup -Algorithm SHA256).Hash -ne
        $originalLocalizedHash
    ) {
        throw 'The protected LocalizedConfig backup failed verification.'
    }
    $patchedLocalizedTimestamp =
        [DateTimeOffset]::UtcNow.AddYears(1).ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    $localizedConfig.localizedConfig.gfwsl.server = $localBaseUrl
    $localizedConfig.configTimestamp = $patchedLocalizedTimestamp

    $state = [ordered]@{
        status = 'installing'
        installedAt = (Get-Date).ToString('o')
        profileBackupRelative = $backupRelative
        originalProfileSha256 = $originalProfileHash
        patchedProfileSha256 = $null
        profileRestoreMode = 'exact'
        localBaseUrl = $localBaseUrl
        verifiedLatestVersion = $latestText
        detectedDeviceIds = $detectedDeviceIds
        productVersion = '4.0.0'
        proxyVersion = 4
        proxySha256 = (Get-FileHash -LiteralPath $serviceExePath -Algorithm SHA256).Hash
        hostKind = 'windows-service'
        serviceName = $serviceName
        serviceBinaryRelative = 'NvidiaAppOculinkShim.exe'
        serviceBinarySha256 = (Get-FileHash -LiteralPath $serviceExePath -Algorithm SHA256).Hash
        configSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
        listenerPort = $Port
        endpointCompatibility = if ($Port -eq 80) {
            'implicit-http-default-port'
        } else {
            'explicit-port-legacy'
        }
        helperAccount = 'LocalService'
        taskName = $taskName
        uiRedirectStatus = 'installing'
        localizedConfigBackupRelative = $localizedBackupRelative
        originalLocalizedConfigSha256 = $originalLocalizedHash
        originalLocalizedGfwslServer = $officialBaseUrl
        originalLocalizedConfigTimestamp = $originalLocalizedTimestamp
        patchedLocalizedConfigTimestamp = $patchedLocalizedTimestamp
        patchedLocalizedConfigSha256 = $null
        localizedRestoreMode = 'exact'
    }
    Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 6)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot

    $profileDirectory = Split-Path -Parent $profilePath
    $operationId = [Guid]::NewGuid().ToString('N')
    $temporaryProfile = Join-Path $profileDirectory "component_profiles.oculink-shim.$operationId.tmp"
    $profileAtomicBackup = Join-Path $profileDirectory "component_profiles.oculink-shim.$operationId.rollback"
    Write-Utf8NoBom -LiteralPath $temporaryProfile -Value ($profiles | ConvertTo-Json -Depth 30)

    $verification = Get-Content -LiteralPath $temporaryProfile -Raw | ConvertFrom-Json
    foreach ($name in @('grd', 'crd')) {
        $entry = @($verification | Where-Object componentName -eq $name)
        if ($entry.Count -ne 1 -or $entry[0].updateCheckerProfiles[0].otaBaseUrl -ne $localBaseUrl) {
            throw "Verification failed for NVIDIA component '$name'."
        }
    }

    [IO.File]::Replace(
        $temporaryProfile,
        $profilePath,
        $profileAtomicBackup,
        $true
    )
    $profileReplaced = $true

    $localizedDirectory = Split-Path -Parent $localizedConfigPath
    $temporaryLocalizedConfig =
        Join-Path $localizedDirectory "LocalizedConfig.oculink-shim.$operationId.tmp"
    $localizedAtomicBackup =
        Join-Path $localizedDirectory "LocalizedConfig.oculink-shim.$operationId.rollback"
    Write-Utf8NoBom `
        -LiteralPath $temporaryLocalizedConfig `
        -Value ($localizedConfig | ConvertTo-Json -Depth 30)
    $localizedAcl = Get-Acl -LiteralPath $localizedConfigPath
    Set-Acl `
        -LiteralPath $temporaryLocalizedConfig `
        -AclObject $localizedAcl
    $stagedLocalized =
        Get-Content -LiteralPath $temporaryLocalizedConfig -Raw |
        ConvertFrom-Json
    if (
        [string]$stagedLocalized.localizedConfig.gfwsl.server -ne
            $localBaseUrl -or
        (
            ConvertTo-StrictUtcTimestampText `
                -Value $stagedLocalized.configTimestamp `
                -Description 'The staged localized configTimestamp'
        ) -ne $patchedLocalizedTimestamp
    ) {
        throw 'Staged LocalizedConfig verification failed.'
    }
    [IO.File]::Replace(
        $temporaryLocalizedConfig,
        $localizedConfigPath,
        $localizedAtomicBackup,
        $true
    )
    $localizedConfigReplaced = $true

    Start-NvidiaLocalizedConfigService
    $localizedServiceStopped = $false
    Start-Sleep -Seconds 2
    $liveLocalized =
        Get-Content -LiteralPath $localizedConfigPath -Raw |
        ConvertFrom-Json
    if (
        [string]$liveLocalized.localizedConfig.gfwsl.server -ne $localBaseUrl -or
        (
            ConvertTo-StrictUtcTimestampText `
                -Value $liveLocalized.configTimestamp `
                -Description 'The live localized configTimestamp'
        ) -ne $patchedLocalizedTimestamp
    ) {
        throw 'NvLocalizedConfig replaced the installed loopback redirect.'
    }

    $patchedProfileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $patchedLocalizedHash =
        (Get-FileHash -LiteralPath $localizedConfigPath -Algorithm SHA256).Hash
    $state.status = 'installed'
    $state.patchedProfileSha256 = $patchedProfileHash
    $state.uiRedirectStatus = 'installed'
    $state.patchedLocalizedConfigSha256 = $patchedLocalizedHash
    $state.uiRedirectInstalledAt = (Get-Date).ToString('o')
    Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 10)
    Protect-InstallTree -LiteralPath $installRoot
    Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
    Remove-Item -LiteralPath $profileAtomicBackup -Force
    $profileAtomicBackup = $null
    Remove-Item -LiteralPath $localizedAtomicBackup -Force
    $localizedAtomicBackup = $null

    Register-AutoRepairTask
    $autoRepairTaskRegistered = $true
} catch {
    $failure = $_

    if ($autoRepairTaskRegistered) {
        Stop-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -ErrorAction SilentlyContinue

        Unregister-ScheduledTask `
            -TaskName $autoRepairTaskName `
            -Confirm:$false `
            -ErrorAction SilentlyContinue

        $autoRepairTaskRegistered = $false
    }
    $localizedRestored = -not $localizedConfigReplaced
    if (
        $localizedConfigReplaced -and
        $localizedBackup -and
        (Test-Path -LiteralPath $localizedBackup)
    ) {
        try {
            if (-not $localizedServiceStopped) {
                Stop-NvidiaLocalizedConfigService
                $localizedServiceStopped = $true
            }
            Copy-Item `
                -LiteralPath $localizedBackup `
                -Destination $localizedConfigPath `
                -Force
            $localizedRestored = (
                (
                    Get-FileHash `
                        -LiteralPath $localizedConfigPath `
                        -Algorithm SHA256
                ).Hash -eq $originalLocalizedHash
            )
        } catch {
            $localizedRestored = $false
        }
    }
    $profileRestored = -not $profileReplaced
    if ($profileReplaced -and $profileBackup -and (Test-Path -LiteralPath $profileBackup)) {
        try {
            Copy-Item -LiteralPath $profileBackup -Destination $profilePath -Force
            $profileRestored = (
                (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash -eq
                $originalProfileHash
            )
        } catch {
            $profileRestored = $false
        }
    }

    if ($localizedServiceStopped) {
        try {
            Start-NvidiaLocalizedConfigService
            $localizedServiceStopped = $false
        } catch {
            $localizedRestored = $false
        }
    }
    if ($serviceRegistered) {
        Remove-V4Service
    }
    if ($temporaryProfile) {
        Remove-Item -LiteralPath $temporaryProfile -Force -ErrorAction SilentlyContinue
    }
    if ($profileAtomicBackup) {
        Remove-Item -LiteralPath $profileAtomicBackup -Force -ErrorAction SilentlyContinue
    }
    if ($temporaryLocalizedConfig) {
        Remove-Item `
            -LiteralPath $temporaryLocalizedConfig `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ($localizedAtomicBackup) {
        Remove-Item `
            -LiteralPath $localizedAtomicBackup `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if (
        $profileRestored -and
        $localizedRestored -and
        $installRootTrusted -and
        (Test-Path -LiteralPath $installRoot)
    ) {
        if (-not $state) {
            $state = [ordered]@{
                status = 'uninstalled'
                failedAt = (Get-Date).ToString('o')
                profileBackupRelative = $null
                originalProfileSha256 = $null
                patchedProfileSha256 = $null
                localBaseUrl = $null
                verifiedLatestVersion = $null
                helperAccount = 'LocalService'
                taskName = $taskName
                hostKind = 'windows-service'
                serviceName = $serviceName
            }
        } else {
            $state.status = 'uninstalled'
            $state.uninstalledAt = (Get-Date).ToString('o')
        }
        try {
            Write-Utf8NoBom -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 6)
            Protect-InstallTree -LiteralPath $installRoot
            if (Test-Path -LiteralPath $runtimeRoot) {
                Set-SecureRuntimeRoot -LiteralPath $runtimeRoot
            }
        } catch {
            # Preserve the original failure.
        }
    }

    New-Item -ItemType Directory -Path $runtimeRoot -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        Write-Utf8NoBom -LiteralPath (Join-Path $runtimeRoot 'install-error.log') -Value ($failure | Out-String)
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
