Set-StrictMode -Version 2

function Get-PresentNvidiaDeviceIds {
    $instanceIds = @()
    try {
        $instanceIds = @(
            Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
                Where-Object Status -eq 'OK' |
                Select-Object -ExpandProperty InstanceId
        )
    } catch {
        $instanceIds = @(
            Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
                Where-Object {
                    $_.PNPClass -eq 'Display' -and
                    $_.Status -eq 'OK' -and
                    $_.PNPDeviceID -like 'PCI\VEN_10DE*'
                } |
                Select-Object -ExpandProperty PNPDeviceID
        )
    }

    $deviceIds = foreach ($instanceId in $instanceIds) {
        if (
            [string]$instanceId -match
            'PCI\\VEN_10DE&DEV_([A-Fa-f0-9]{4})&SUBSYS_([A-Fa-f0-9]{4})([A-Fa-f0-9]{4})'
        ) {
            (
                $Matches[1] + '_10DE_' +
                $Matches[2] + '_' +
                $Matches[3] + '_1'
            ).ToUpperInvariant()
        }
    }
    $deviceIds = @($deviceIds | Sort-Object -Unique)
    if ($deviceIds.Count -lt 1) {
        throw 'No active NVIDIA display adapter with a PCI subsystem ID was found.'
    }
    return $deviceIds
}

function Install-NvidiaAppAutoRepairTask {
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $taskName = 'NVIDIA App eGPU Update Bridge Auto Repair'
    $sourcePath =
        Join-Path $PSScriptRoot 'AutoRepair-NvidiaAppOculinkShim.ps1'
    $installedPath =
        Join-Path $InstallRoot 'AutoRepair-NvidiaAppOculinkShim.ps1'

    if (-not (
        Test-Path -LiteralPath $sourcePath -PathType Leaf
    )) {
        throw "Auto-repair script was not found: $sourcePath"
    }

    $previousTaskXml = $null
    $previousScriptBackup = $null
    $previousScriptAcl = $null
    $previousScriptHash = $null
    $taskRegistrationAttempted = $false
    $scriptWriteAttempted = $false
    $rollbackSucceeded = $true

    try {
        $existingTask =
            Get-ScheduledTask `
                -TaskName $taskName `
                -ErrorAction SilentlyContinue

        if ($existingTask) {
            $previousTaskXml =
                Export-ScheduledTask `
                    -TaskName $taskName `
                    -ErrorAction Stop
        }

        if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
            $previousScriptAcl = Get-Acl -LiteralPath $installedPath
            $previousScriptHash =
                (Get-FileHash `
                    -LiteralPath $installedPath `
                    -Algorithm SHA256).Hash
            $previousScriptBackup =
                Join-Path $InstallRoot (
                    'AutoRepair-NvidiaAppOculinkShim.' +
                    [Guid]::NewGuid().ToString('N') +
                    '.rollback'
                )
            Copy-Item `
                -LiteralPath $installedPath `
                -Destination $previousScriptBackup
        }

        $scriptWriteAttempted = $true
        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $installedPath `
            -Force

        if ($previousScriptAcl) {
            Set-Acl `
                -LiteralPath $installedPath `
                -AclObject $previousScriptAcl
        }

        if (
            (
                Get-FileHash `
                    -LiteralPath $installedPath `
                    -Algorithm SHA256
            ).Hash -ne
            (
                Get-FileHash `
                    -LiteralPath $sourcePath `
                    -Algorithm SHA256
            ).Hash
        ) {
            throw 'The installed auto-repair script failed SHA-256 verification.'
        }

        $windowsDirectory =
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::Windows
            )

        $powerShellPath =
            Join-Path $windowsDirectory (
                'System32\WindowsPowerShell\v1.0\powershell.exe'
            )

        if (-not (
            Test-Path -LiteralPath $powerShellPath -PathType Leaf
        )) {
            throw 'The fixed System32 Windows PowerShell executable is missing.'
        }

        $arguments =
            '-NoLogo -NoProfile -NonInteractive ' +
            '-ExecutionPolicy Bypass -File "' +
            $installedPath +
            '"'

        $action = New-ScheduledTaskAction `
            -Execute $powerShellPath `
            -Argument $arguments

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

        $taskRegistrationAttempted = $true
        Register-ScheduledTask `
            -TaskName $taskName `
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
            -Force `
            -ErrorAction Stop |
            Out-Null

        $task =
            Get-ScheduledTask `
                -TaskName $taskName `
                -ErrorAction Stop

        $actions = @($task.Actions)
        if (
            [string]$task.Principal.UserId -notin @(
                'SYSTEM',
                'S-1-5-18'
            ) -or
            [string]$task.Principal.LogonType -ne 'ServiceAccount' -or
            [string]$task.Principal.RunLevel -ne 'Highest' -or
            $actions.Count -ne 1 -or
            [IO.Path]::GetFullPath([string]$actions[0].Execute) -ne
                [IO.Path]::GetFullPath($powerShellPath) -or
            [string]$actions[0].Arguments -ne $arguments
        ) {
            throw 'The auto-repair scheduled task has an unexpected definition.'
        }
    }
    catch {
        $failure = $_

        if ($taskRegistrationAttempted) {
            try {
                if ($previousTaskXml) {
                    Register-ScheduledTask `
                        -TaskName $taskName `
                        -Xml $previousTaskXml `
                        -Force `
                        -ErrorAction Stop |
                        Out-Null
                } else {
                    Unregister-ScheduledTask `
                        -TaskName $taskName `
                        -Confirm:$false `
                        -ErrorAction SilentlyContinue
                }
            }
            catch {
                $rollbackSucceeded = $false
            }
        }

        if ($scriptWriteAttempted) {
            try {
                if (
                    $previousScriptBackup -and
                    (Test-Path -LiteralPath $previousScriptBackup)
                ) {
                    Copy-Item `
                        -LiteralPath $previousScriptBackup `
                        -Destination $installedPath `
                        -Force

                    if ($previousScriptAcl) {
                        Set-Acl `
                            -LiteralPath $installedPath `
                            -AclObject $previousScriptAcl
                    }

                    if (
                        $previousScriptHash -and
                        (
                            Get-FileHash `
                                -LiteralPath $installedPath `
                                -Algorithm SHA256
                        ).Hash -ne $previousScriptHash
                    ) {
                        throw 'The previous auto-repair script was not restored exactly.'
                    }
                } else {
                    Remove-Item `
                        -LiteralPath $installedPath `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }
            catch {
                $rollbackSucceeded = $false
            }
        }

        if (-not $rollbackSucceeded) {
            throw (
                'Auto-repair task installation failed and rollback was incomplete: ' +
                $failure.Exception.Message
            )
        }

        throw $failure
    }
    finally {
        if ($previousScriptBackup) {
            Remove-Item `
                -LiteralPath $previousScriptBackup `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @(
    'Get-PresentNvidiaDeviceIds',
    'Install-NvidiaAppAutoRepairTask'
)
