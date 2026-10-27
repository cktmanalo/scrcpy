<#
.SYNOPSIS
    Mirrors one or more adb devices with the scrcpy built in this repository, keeps each window open while
    the device restarts, and records the screen on demand.

.DESCRIPTION
    One scrcpy window is opened per device with --reconnect, so the window stays open while the device
    restarts and mirroring resumes in the same window. Every scrcpy process runs without a console window.
    Closing a scrcpy window stops monitoring that device; it can be reopened from the control panel. Without
    the control panel (-NoPanel), the monitor exits once every window is closed.

    Recording runs in a separate hidden scrcpy process that can be started and stopped at any time with the
    record button in the top-right corner of each scrcpy window (or Alt+E), the control panel, the tray icon
    or -Command. A device restart while recording continues the recording in a new part, and the parts are
    joined into one MP4 with ffmpeg when the recording stops:
        <RecordDir>\<Device Name>\Screen_Recording_<Device Name>_<yyyyMMdd_HHmmss>.mp4
    If the device cannot run a second hardware video encoder, the recorder switches to a software encoder.

    The recordings folder is -RecordDir if given, else the folder chosen in the control panel, else the
    default. When scrcpy.exe is next to this script (portable package), scrcpy, adb and ffmpeg are used from
    this folder.

    A portable package built with package-portable.ps1 checks its GitHub repository for a newer release at
    startup (unless -NoUpdateCheck) and from "Check for updates" in the control panel, then updates itself
    and restarts.

    Run scrcpy-monitor.vbs to start the monitor without any visible console window.

.EXAMPLE
    .\scrcpy-monitor.ps1 -List
.EXAMPLE
    .\scrcpy-monitor.ps1
.EXAMPLE
    .\scrcpy-monitor.ps1 -Serial 192.168.68.100:5555,R58M123ABC -Record --max-size=1024 --stay-awake
.EXAMPLE
    .\scrcpy-monitor.ps1 -Command StartRecording -Serial 192.168.68.100:5555
.EXAMPLE
    .\scrcpy-monitor.ps1 -Command StopRecording
#>
[CmdletBinding()]
param(
    [string[]]$Serial,
    [string]$BuildDir = 'x',
    [string]$AdbPath,
    [string]$MsysBin,
    [switch]$Record,
    [string]$RecordDir,
    [string]$RecordEncoder = 'auto',
    [string[]]$RecordArgs,
    [switch]$KeepParts,
    [ValidateSet('StartRecording', 'StopRecording', 'ShowPanel', 'Exit')]
    [string]$Command,
    [switch]$List,
    [switch]$NoTray,
    [switch]$NoPanel,
    [switch]$NoUpdateCheck,
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 2,
    [Parameter(DontShow)]
    [int]$SendCtrlC,
    [Parameter(DontShow)]
    [string]$ApplyUpdate,
    [Parameter(DontShow)]
    [string]$UpdateTarget,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScrcpyArgs
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($SendCtrlC) {
    Add-Type -Namespace ScrcpyMonitor -Name Console -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint processId);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(System.IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
'@
    [void][ScrcpyMonitor.Console]::FreeConsole()
    if (-not [ScrcpyMonitor.Console]::AttachConsole([uint32]$SendCtrlC)) { exit 2 }
    [void][ScrcpyMonitor.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    $sent = [ScrcpyMonitor.Console]::GenerateConsoleCtrlEvent(0, 0)
    [void][ScrcpyMonitor.Console]::FreeConsole()
    if ($sent) { exit 0 }
    exit 3
}

$script:StateDir = Join-Path $env:TEMP 'scrcpy-monitor'
$script:RequestDir = Join-Path $script:StateDir 'requests'
$script:ControlDir = Join-Path $script:StateDir 'control'
$script:LogDir = Join-Path $script:StateDir 'logs'
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'scrcpy-monitor\settings.json'
$script:LogPath = Join-Path $script:StateDir 'scrcpy-monitor.log'
$script:EncoderCachePath = Join-Path $script:StateDir 'encoders.json'
$mutexName = 'Local\scrcpy-monitor'

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
    try { Write-Host $line } catch { }
}

function Show-Error([string]$Message) {
    Write-Log "ERROR: $Message"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Message, 'scrcpy monitor', 'OK', 'Error')
    } catch { }
}

[void](New-Item -ItemType Directory -Force -Path $script:RequestDir, $script:ControlDir, $script:LogDir)

$Serial = @($Serial | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ScrcpyArgs = @($ScrcpyArgs | Where-Object { $_ -and $_ -ne '--' })
$RecordArgs = @($RecordArgs | Where-Object { $_ })

function Send-MonitorRequest([string]$RequestCommand, [string[]]$Serials) {
    $name = '{0:yyyyMMddHHmmssfff}-{1}' -f (Get-Date), [guid]::NewGuid().ToString('N')
    $temp = Join-Path $script:RequestDir "$name.tmp"
    @{ Command = $RequestCommand; Serial = $Serials } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination (Join-Path $script:RequestDir "$name.json")
}

function Test-MonitorRunning {
    $existing = $null
    if (-not [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$existing)) { return $false }
    $existing.Dispose()
    $true
}

function Get-ProcessesIn([string]$Name, [string]$Folder) {
    $prefix = $Folder.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -Filter "Name='$Name'" | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-ProcessesExit([string]$Name, [string]$Folder, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (@(Get-ProcessesIn $Name $Folder).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    foreach ($process in (Get-ProcessesIn $Name $Folder)) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { }
    }
}

if ($ApplyUpdate) {
    $updateDir = Join-Path $script:StateDir 'update'
    $monitorStopped = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        if (Test-Path -LiteralPath $updateDir) { Remove-Item -LiteralPath $updateDir -Recurse -Force }
        [void](New-Item -ItemType Directory -Force -Path $updateDir)
        $zip = Join-Path $updateDir 'update.zip'
        $extractDir = Join-Path $updateDir 'files'
        Write-Log "Update: downloading $ApplyUpdate"
        Invoke-WebRequest -Uri $ApplyUpdate -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'scrcpy-monitor' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extractDir)
        $source = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'scrcpy-monitor.ps1' | Select-Object -First 1
        if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source.DirectoryName 'scrcpy.exe'))) { throw 'The downloaded update is not a scrcpy monitor package.' }

        Write-Log 'Update: stopping the monitor.'
        if (Test-MonitorRunning) { Send-MonitorRequest 'Exit' @() }
        $monitorStopped = $true
        $deadline = (Get-Date).AddMinutes(15)
        while ((Test-MonitorRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        if (Test-MonitorRunning) { throw 'The monitor did not stop.' }

        Wait-ProcessesExit 'scrcpy.exe' $UpdateTarget 20
        $adb = Join-Path $UpdateTarget 'adb.exe'
        if (@(Get-ProcessesIn 'adb.exe' $UpdateTarget).Count -gt 0) {
            try { & $adb kill-server 2>&1 | Out-Null } catch { }
            Wait-ProcessesExit 'adb.exe' $UpdateTarget 10
        }

        Write-Log "Update: copying files to $UpdateTarget"
        $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        & $robocopy $source.DirectoryName $UpdateTarget /E /R:10 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying the update failed (robocopy exit code $LASTEXITCODE)." }
        Write-Log 'Update: installed.'
    } catch {
        Show-Error "Update failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $updateDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($monitorStopped) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList "`"$(Join-Path $UpdateTarget 'scrcpy-monitor.vbs')`""
        }
    }
    exit 0
}

if ($Command) {
    $existing = $null
    if (-not [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$existing)) {
        Write-Host 'scrcpy monitor is not running.'
        exit 1
    }
    $existing.Dispose()
    Send-MonitorRequest $Command $Serial
    Write-Host "Sent $Command to the running scrcpy monitor."
    exit 0
}

function ConvertTo-ArgumentString([string[]]$Arguments) {
    $quoted = foreach ($arg in $Arguments) {
        if ($arg -eq '') { '""' }
        elseif ($arg -notmatch '[\s"&|<>^()]') { $arg }
        else { '"' + (($arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    $quoted -join ' '
}

function Resolve-Tool([string]$Explicit, [string[]]$Candidates, [string]$CommandName) {
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return (Resolve-Path -LiteralPath $Explicit).Path }
        return $null
    }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    $cmd = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    return $null
}

function New-HiddenStartInfo([string]$FileName, [string]$Arguments, [switch]$ScrcpyEnvironment) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($ScrcpyEnvironment) {
        $psi.EnvironmentVariables['ADB'] = $script:Adb
        $psi.EnvironmentVariables['SCRCPY_SERVER_PATH'] = $script:Server
        $psi.EnvironmentVariables['SCRCPY_ICON_DIR'] = $script:IconDir
        if ($script:MsysBinPath) {
            $psi.EnvironmentVariables['PATH'] = $script:MsysBinPath + ';' + $psi.EnvironmentVariables['PATH']
        }
    }
    $psi
}

function Invoke-Hidden([string]$FileName, [string[]]$Arguments, [int]$TimeoutMs = 10000, [switch]$ScrcpyEnvironment, [switch]$IncludeStdErr) {
    $psi = New-HiddenStartInfo $FileName (ConvertTo-ArgumentString $Arguments) -ScrcpyEnvironment:$ScrcpyEnvironment
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { }
            return ''
        }
        if (-not $stdout.Wait(2000)) { return '' }
        if ($IncludeStdErr -and $stderr.Wait(2000)) { return $stdout.Result + "`n" + $stderr.Result }
        return $stdout.Result
    } catch {
        Write-Log "$FileName $($psi.Arguments) failed: $($_.Exception.Message)"
        return ''
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Invoke-Adb([string[]]$Arguments, [int]$TimeoutMs = 10000) {
    Invoke-Hidden $script:Adb $Arguments $TimeoutMs
}

function Get-AdbDevices {
    $devices = @{}
    foreach ($line in ((Invoke-Adb @('devices')) -split "`r?`n")) {
        if ($line -match '^(\S+)\s+(device|offline|unauthorized|recovery|sideload|bootloader|authorizing|connecting|no permissions.*)$') {
            $devices[$Matches[1]] = $Matches[2]
        }
    }
    $devices
}

function Get-DeviceProp([string]$DeviceSerial, [string]$Name) {
    (Invoke-Adb @('-s', $DeviceSerial, 'shell', 'getprop', $Name) 5000).Trim()
}

function ConvertTo-SafeName([string]$Name) {
    $invalid = [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars())
    (($Name -replace "[$invalid]", '_') -replace '\s+', '_').Trim('_. ')
}

function Start-ScrcpyProcess([string[]]$Arguments, [string]$LogFile) {
    $commandLine = '/d /s /c ""{0}" {1} > "{2}" 2>&1"' -f $script:Scrcpy, (ConvertTo-ArgumentString $Arguments), $LogFile
    $psi = New-HiddenStartInfo $env:ComSpec $commandLine -ScrcpyEnvironment
    [System.Diagnostics.Process]::Start($psi)
}

function Stop-OrphanServers([string]$DeviceSerial) {
    $pattern = '"-s" "' + [regex]::Escape($DeviceSerial) + '" "shell" .*app_process.*scid=([0-9a-f]+)'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='adb.exe'" -ErrorAction SilentlyContinue)) {
        if ($process.CommandLine -notmatch $pattern) { continue }
        $scid = $Matches[1]
        if (Get-Process -Id $process.ParentProcessId -ErrorAction SilentlyContinue) { continue }
        Write-Log "[$DeviceSerial] Killing orphaned scrcpy server (adb pid $($process.ProcessId))."
        Stop-ProcessTree $process.ProcessId
        foreach ($line in ((Invoke-Adb @('forward', '--list') 5000) -split "`r?`n")) {
            if ($line -match "^\S+\s+(tcp:\d+)\s+localabstract:scrcpy_$scid$") {
                [void](Invoke-Adb @('-s', $DeviceSerial, 'forward', '--remove', $Matches[1]) 5000)
            }
        }
    }
}

function Stop-ProcessTree([int]$ProcessId) {
    [void](Invoke-Hidden (Join-Path $env:SystemRoot 'System32\taskkill.exe') @('/PID', "$ProcessId", '/T', '/F') 10000)
}

function Send-CtrlC([System.Diagnostics.Process]$Process) {
    try {
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SendCtrlC {1}' -f $PSCommandPath, $Process.Id
        return [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:PowerShellExe $arguments))
    } catch {
        Write-Log "Could not send Ctrl+C to process $($Process.Id): $($_.Exception.Message)"
        return $null
    }
}

function Stop-ScrcpyProcess([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 15000) {
    if ($Process.HasExited) { return $true }
    $helper = Send-CtrlC $Process
    if ($helper) {
        [void]$helper.WaitForExit(15000)
        $helper.Dispose()
    }
    if ($Process.WaitForExit($TimeoutMs)) { return $true }
    Write-Log "Process $($Process.Id) did not stop gracefully; killing it."
    Stop-ProcessTree $Process.Id
    [void]$Process.WaitForExit(5000)
    return $false
}

function Test-VideoFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1024) { return $false }
    if (-not $script:Ffprobe) { return $true }
    $duration = (Invoke-Hidden $script:Ffprobe @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $Path) 30000).Trim()
    $value = 0.0
    [double]::TryParse($duration, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and $value -gt 0
}

function Get-SoftwareEncoder([string]$DeviceSerial) {
    $codec = Get-RecordCodec
    $output = Invoke-Hidden $script:Scrcpy @('-s', $DeviceSerial, '--list-encoders') 30000 -ScrcpyEnvironment -IncludeStdErr
    $fallback = $null
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -notmatch "--video-codec=$([regex]::Escape($codec))\s+--video-encoder=(\S+)" -or $line -match '\(alias') { continue }
        $encoder = $Matches[1]
        if ($line -match '\(sw\)') { return $encoder }
        if (-not $fallback -and $line -notmatch '\(hw\)' -and $encoder -match '^(OMX\.google\.|c2\.android\.)') { $fallback = $encoder }
    }
    if ($fallback) { return $fallback }

    $tail = (($output -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 5) -join ' | '
    Write-Log "[$DeviceSerial] Could not list encoders: $tail"
    $known = @{ h264 = @('c2.android.avc.encoder', 'OMX.google.h264.encoder'); h265 = @('c2.android.hevc.encoder', $null) }
    if (-not $known.ContainsKey($codec)) { return $null }
    $sdk = 0
    [void][int]::TryParse((Get-DeviceProp $DeviceSerial 'ro.build.version.sdk'), [ref]$sdk)
    if ($sdk -eq 0) { return $null }
    if ($sdk -ge 29) { return $known[$codec][0] }
    $known[$codec][1]
}

function Get-RecordCodec {
    $codec = 'h264'
    foreach ($arg in $RecordArgs) { if ($arg -match '^--video-codec=(\S+)$') { $codec = $Matches[1] } }
    $codec
}

function Get-CachedEncoder([string]$DeviceSerial) {
    try {
        $cache = Get-Content -LiteralPath $script:EncoderCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $value = $cache.PSObject.Properties["$DeviceSerial|$(Get-RecordCodec)"]
        if ($value) { return [string]$value.Value }
    } catch { }
    return $null
}

function Set-CachedEncoder([string]$DeviceSerial, [string]$Encoder) {
    $cache = @{}
    try {
        $json = Get-Content -LiteralPath $script:EncoderCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($property in $json.PSObject.Properties) { $cache[$property.Name] = $property.Value }
    } catch { }
    $key = "$DeviceSerial|$(Get-RecordCodec)"
    if ($Encoder) { $cache[$key] = $Encoder } else { $cache.Remove($key) }
    try { $cache | ConvertTo-Json | Set-Content -LiteralPath $script:EncoderCachePath -Encoding UTF8 } catch { }
}

function Show-Notification([string]$Message, [string]$Icon = 'Info') {
    Write-Log $Message
    if ($script:Tray) {
        try { $script:Tray.ShowBalloonTip(4000, 'scrcpy monitor', $Message, $Icon) } catch { }
    }
}

function New-Session([string]$DeviceSerial) {
    $session = [pscustomobject]@{
        Serial             = $DeviceSerial
        SafeSerial         = ConvertTo-SafeName $DeviceSerial
        Name               = $null
        Title              = $DeviceSerial
        LastState          = $null
        BootedAt           = $null
        NextConnect        = Get-Date
        Connector          = $null
        UserClosed         = $false
        Display            = $null
        DisplayStartedAt   = $null
        DisplayFailures    = 0
        NextDisplayAttempt = Get-Date
        Recording          = $false
        RecordingStartedAt = $null
        RecordingBase      = $null
        Parts              = New-Object System.Collections.ArrayList
        Recorder           = $null
        RecorderStartedAt  = $null
        RecorderPart       = $null
        RecorderLog        = $null
        RecorderFailures   = 0
        NextRecordAttempt  = Get-Date
        SoftwareEncoder    = $(if ($RecordEncoder -eq 'auto') { Get-CachedEncoder $DeviceSerial } else { $null })
        ControlPath        = Join-Path $script:ControlDir "$(ConvertTo-SafeName $DeviceSerial).state"
        Stopping           = $false
    }
    $script:Sessions[$DeviceSerial] = $session
    Set-RecordState $session
    if ($script:RecordOnStart) { Start-Recording $session }
    $session
}

function Set-RecordState($Session) {
    $state = if ($Session.Recording) { '1' } else { '0' }
    try { [System.IO.File]::WriteAllText($Session.ControlPath, $state) } catch { Write-Log "[$($Session.Serial)] Could not write $($Session.ControlPath): $($_.Exception.Message)" }
}

function Invoke-ControlRequests {
    foreach ($session in @($script:Sessions.Values)) {
        $requestPath = "$($session.ControlPath).request"
        if (-not [System.IO.File]::Exists($requestPath)) { continue }
        $request = ''
        try {
            $request = [System.IO.File]::ReadAllText($requestPath).Trim()
            [System.IO.File]::Delete($requestPath)
        } catch {
            continue
        }
        Write-Log "[$($session.Serial)] Record button: $request"
        switch ($request) {
            'start' { Start-Recording $session }
            'stop' { Stop-Recording $session }
        }
        Set-RecordState $session
        Update-TrayText
    }
}

function Test-DeviceReady($Session, $Devices) {
    if (-not $Devices.ContainsKey($Session.Serial) -or $Devices[$Session.Serial] -ne 'device') { return $false }
    if ((Get-DeviceProp $Session.Serial 'sys.boot_completed') -ne '1') { return $false }
    if (-not $Session.BootedAt) { $Session.BootedAt = Get-Date }
    if (-not $Session.Name) {
        $model = Get-DeviceProp $Session.Serial 'ro.product.model'
        $Session.Name = if ($model) { $model } else { $Session.Serial }
        $Session.Title = if ($model) { "$model ($($Session.Serial))" } else { $Session.Serial }
    }
    return $true
}

function Start-Display($Session) {
    $arguments = @('-s', $Session.Serial, '--reconnect', "--record-control=$($Session.ControlPath)")
    if (-not ($ScrcpyArgs | Where-Object { $_ -like '--window-title*' })) { $arguments += "--window-title=$($Session.Title)" }
    $arguments += $ScrcpyArgs
    $log = Join-Path $script:LogDir "$($Session.SafeSerial)-display.log"
    Stop-OrphanServers $Session.Serial
    Write-Log "[$($Session.Serial)] Starting scrcpy window: $(ConvertTo-ArgumentString $arguments)"
    $Session.Display = Start-ScrcpyProcess $arguments $log
    $Session.DisplayStartedAt = Get-Date
}

function Update-Display($Session, $Devices, [ref]$Ready) {
    $now = Get-Date
    if ($Session.Display) {
        if (-not $Session.Display.HasExited) { return }

        $exitCode = $Session.Display.ExitCode
        $ranSeconds = ($now - $Session.DisplayStartedAt).TotalSeconds
        $Session.Display.Dispose()
        $Session.Display = $null

        if ($exitCode -eq 0) {
            $Session.UserClosed = $true
            Write-Log "[$($Session.Serial)] scrcpy window closed by user; no longer monitoring."
            Stop-Recording $Session
            return
        }

        if ($ranSeconds -ge 30) { $Session.DisplayFailures = 0 }
        $Session.DisplayFailures++
        $delay = if ($exitCode -eq 2) { 2 } else { [Math]::Min(5 * $Session.DisplayFailures, 30) }
        $Session.NextDisplayAttempt = $now.AddSeconds($delay)
        Write-Log "[$($Session.Serial)] scrcpy window exited with code $exitCode; retrying in ${delay}s (log: $(Join-Path $script:LogDir "$($Session.SafeSerial)-display.log"))."
    }

    if ($now -lt $Session.NextDisplayAttempt) { return }
    if ($null -eq $Ready.Value) { $Ready.Value = Test-DeviceReady $Session $Devices }
    if (-not $Ready.Value) { return }

    try {
        Start-Display $Session
    } catch {
        $Session.DisplayFailures++
        $Session.NextDisplayAttempt = $now.AddSeconds([Math]::Min(5 * $Session.DisplayFailures, 30))
        Write-Log "[$($Session.Serial)] Failed to start scrcpy: $($_.Exception.Message)"
    }
}

function Start-Recording($Session) {
    if ($Session.Recording -or $Session.UserClosed) { return }
    $Session.Recording = $true
    $Session.RecordingStartedAt = Get-Date
    $Session.RecordingBase = $null
    $Session.Parts.Clear()
    $Session.RecorderFailures = 0
    $Session.NextRecordAttempt = Get-Date
    Set-RecordState $Session
    Get-ChildItem -LiteralPath $script:LogDir -Filter "$($Session.SafeSerial)-record*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Show-Notification "Recording requested for $($Session.Title)."
}

function Start-RecorderPart($Session) {
    if (-not $Session.RecordingBase) {
        $deviceName = ConvertTo-SafeName $Session.Name
        if (-not $deviceName) { $deviceName = $Session.SafeSerial }
        $folder = Join-Path $RecordDir $deviceName
        [void](New-Item -ItemType Directory -Force -Path $folder)
        $stem = 'Screen_Recording_{0}_{1:yyyyMMdd_HHmmss}' -f $deviceName, $Session.RecordingStartedAt
        $base = Join-Path $folder $stem
        $suffix = 2
        while ((Test-Path -LiteralPath "$base.mp4") -or (Test-Path -LiteralPath "${base}_part01.mp4") -or
               ($script:Sessions.Values | Where-Object { $_ -ne $Session -and $_.RecordingBase -eq $base })) {
            $base = Join-Path $folder "${stem}_$suffix"
            $suffix++
        }
        $Session.RecordingBase = $base
    }

    $part = '{0}_part{1:D2}.mp4' -f $Session.RecordingBase, ($Session.Parts.Count + 1)
    $arguments = @('-s', $Session.Serial, '--no-playback', '--no-control', "--record=$part", '--record-format=mp4')
    if ($RecordEncoder -ne 'auto') { $arguments += "--video-encoder=$RecordEncoder" }
    elseif ($Session.SoftwareEncoder) { $arguments += "--video-encoder=$($Session.SoftwareEncoder)" }
    $arguments += $RecordArgs

    $Session.RecorderLog = Join-Path $script:LogDir ('{0}-record-part{1:D2}.log' -f $Session.SafeSerial, ($Session.Parts.Count + 1))
    Stop-OrphanServers $Session.Serial
    Write-Log "[$($Session.Serial)] Starting recorder: $(ConvertTo-ArgumentString $arguments)"
    $Session.Recorder = Start-ScrcpyProcess $arguments $Session.RecorderLog
    $Session.RecorderStartedAt = Get-Date
    $Session.RecorderPart = $part
    [void]$Session.Parts.Add($part)
}

function Test-EncoderFailure($Session) {
    if ($RecordEncoder -ne 'auto' -or $Session.SoftwareEncoder) { return $false }
    if (((Get-Date) - $Session.RecorderStartedAt).TotalSeconds -gt 60) { return $false }
    try {
        $content = Get-Content -LiteralPath $Session.RecorderLog -Raw -ErrorAction Stop
        return ($content -and $content -match 'CodecException')
    } catch {
        return $false
    }
}

function Remove-RecorderPart($Session) {
    $Session.Parts.Remove($Session.RecorderPart)
    Remove-Item -LiteralPath $Session.RecorderPart -Force -ErrorAction SilentlyContinue
}

function Update-Recorder($Session, $Devices, [ref]$Ready) {
    $now = Get-Date
    if ($Session.Recorder) {
        $encoderFailed = Test-EncoderFailure $Session
        $stalled = -not $encoderFailed -and -not $Session.Recorder.HasExited -and
                   ($now - $Session.RecorderStartedAt).TotalSeconds -gt 20 -and -not (Test-Path -LiteralPath $Session.RecorderPart)
        if (-not $Session.Recorder.HasExited -and -not $encoderFailed -and -not $stalled) { return }

        if (-not $Session.Recorder.HasExited) { Stop-ProcessTree $Session.Recorder.Id; [void]$Session.Recorder.WaitForExit(5000) }
        $exitCode = if ($Session.Recorder.HasExited) { $Session.Recorder.ExitCode } else { -1 }
        $ranSeconds = ($now - $Session.RecorderStartedAt).TotalSeconds
        $Session.Recorder.Dispose()
        $Session.Recorder = $null

        if ($stalled) {
            Remove-RecorderPart $Session
            $Session.RecorderFailures++
            $Session.NextRecordAttempt = $now.AddSeconds([Math]::Min(3 * $Session.RecorderFailures, 30))
            Write-Log "[$($Session.Serial)] Recorder did not start recording within 20s; retrying."
        } elseif ($encoderFailed) {
            Remove-RecorderPart $Session
            $encoder = Get-SoftwareEncoder $Session.Serial
            if ($encoder) {
                $Session.SoftwareEncoder = $encoder
                Set-CachedEncoder $Session.Serial $encoder
                $Session.NextRecordAttempt = $now
                Write-Log "[$($Session.Serial)] Hardware encoder busy; recording with software encoder $encoder."
            } else {
                $Session.RecorderFailures++
                $Session.NextRecordAttempt = $now.AddSeconds([Math]::Min(5 * $Session.RecorderFailures, 30))
                Write-Log "[$($Session.Serial)] Hardware encoder busy and no software encoder found yet; retrying."
            }
        } elseif ($exitCode -eq 1) {
            if ($ranSeconds -ge 30) { $Session.RecorderFailures = 0 }
            $Session.RecorderFailures++
            if ($Session.RecorderFailures -eq 5) {
                if ($Session.SoftwareEncoder) {
                    $Session.SoftwareEncoder = $null
                    Set-CachedEncoder $Session.Serial $null
                }
                Show-Notification "Recording for $($Session.Title) keeps failing; still retrying (log: $($Session.RecorderLog))." 'Warning'
            }
            $Session.NextRecordAttempt = $now.AddSeconds([Math]::Min(3 * $Session.RecorderFailures, 30))
            Write-Log "[$($Session.Serial)] Recorder failed (code $exitCode); retrying."
        } else {
            $Session.BootedAt = $null
            $Session.NextRecordAttempt = $now
            Write-Log "[$($Session.Serial)] Recorder exited with code $exitCode; recording resumes in a new part when the device is ready."
        }
    }

    if (-not $Session.Recording -or $Session.Stopping -or $now -lt $Session.NextRecordAttempt) { return }
    if (-not $Session.Display -or ($now - $Session.DisplayStartedAt).TotalSeconds -lt 5) { return }
    if ($null -eq $Ready.Value) { $Ready.Value = Test-DeviceReady $Session $Devices }
    if (-not $Ready.Value) { return }
    if (($now - $Session.BootedAt).TotalSeconds -lt 4) { return }

    try {
        Start-RecorderPart $Session
    } catch {
        $Session.RecorderFailures++
        $Session.NextRecordAttempt = $now.AddSeconds(5 * $Session.RecorderFailures)
        Write-Log "[$($Session.Serial)] Failed to start recorder: $($_.Exception.Message)"
    }
}

function Stop-Recording($Session) {
    if (-not $Session.Recording) { return }
    $Session.Recording = $false
    Set-RecordState $Session
    $stop = [pscustomobject]@{
        Session  = $Session
        Recorder = $Session.Recorder
        Helper   = $null
        Deadline = (Get-Date).AddSeconds(30)
        Killed   = $false
        Title    = $Session.Title
        Base     = $Session.RecordingBase
        Parts    = @($Session.Parts)
    }
    $Session.Recorder = $null
    $Session.Parts.Clear()
    $Session.Stopping = $true
    if ($stop.Recorder -and -not $stop.Recorder.HasExited) { $stop.Helper = Send-CtrlC $stop.Recorder }
    [void]$script:Stops.Add($stop)
    Update-Stops
}

function Update-Stops([int]$TimeoutMs = 0) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        foreach ($stop in @($script:Stops)) {
            $now = Get-Date
            if ($stop.Helper -and $stop.Helper.HasExited) { $stop.Helper.Dispose(); $stop.Helper = $null }
            if ($stop.Recorder -and -not $stop.Recorder.HasExited) {
                if ($now -lt $stop.Deadline) { continue }
                if (-not $stop.Killed) {
                    Write-Log "Process $($stop.Recorder.Id) did not stop gracefully; killing it."
                    Stop-ProcessTree $stop.Recorder.Id
                    $stop.Killed = $true
                    $stop.Deadline = $now.AddSeconds(5)
                    continue
                }
            }
            if ($stop.Recorder) { $stop.Recorder.Dispose(); $stop.Recorder = $null }
            if ($stop.Helper) { $stop.Helper.Dispose(); $stop.Helper = $null }
            $script:Stops.Remove($stop)
            if (-not @($script:Stops | Where-Object { $_.Session -eq $stop.Session }).Count) { $stop.Session.Stopping = $false }
            Complete-Recording $stop.Title $stop.Base $stop.Parts
        }
        if ($script:Stops.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 200
    } while ($true)
}

function Complete-Recording([string]$Title, [string]$Base, [string[]]$AllParts) {
    $parts = @($AllParts | Where-Object { $_ -and (Test-VideoFile $_) })
    foreach ($part in @($AllParts | Where-Object { $_ -and $parts -notcontains $_ })) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    if (-not $Base -or $parts.Count -eq 0) {
        Show-Notification "Recording stopped for $Title; nothing was recorded."
        return
    }

    $output = "$Base.mp4"
    if ($parts.Count -eq 1) {
        Move-Item -LiteralPath $parts[0] -Destination $output
        Show-Notification "Recording saved: $output"
        return
    }
    if (-not $script:Ffmpeg) {
        Show-Notification "Recording saved in $($parts.Count) parts next to $output (ffmpeg not found to join them)."
        return
    }

    $steps = New-Object System.Collections.ArrayList
    $temps = foreach ($part in $parts) {
        $temp = $part -replace '\.mp4$', '_fixed.mp4'
        [void]$steps.Add(@('-hide_banner', '-loglevel', 'error', '-y', '-i', $part, '-map', '0:v?', '-map', '0:a?', '-c', 'copy', $temp))
        $temp
    }
    $listFile = Join-Path $script:StateDir ("concat-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $lines = foreach ($temp in $temps) { "file '" + ($temp -replace "'", "'\''") + "'" }
    [System.IO.File]::WriteAllLines($listFile, [string[]]$lines)
    [void]$steps.Add(@('-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', $listFile, '-c', 'copy', '-movflags', '+faststart', $output))

    $merge = [pscustomobject]@{ Process = $null; Steps = $steps; Parts = $parts; Temps = @($temps); Output = $output; ListFile = $listFile }
    try {
        $merge.Process = Start-MergeStep $merge
    } catch {
        Write-Log "Failed to start ffmpeg: $($_.Exception.Message)"
    }
    [void]$script:Merges.Add($merge)
    Write-Log "Joining $($parts.Count) parts into $output"
}

function Start-MergeStep($Merge) {
    $arguments = $Merge.Steps[0]
    $Merge.Steps.RemoveAt(0)
    [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:Ffmpeg (ConvertTo-ArgumentString $arguments)))
}

function Update-Merges([int]$TimeoutMs = 0) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    foreach ($merge in @($script:Merges)) {
        $exitCode = -1
        while ($merge.Process) {
            $wait = [int][math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            if (-not $merge.Process.WaitForExit($wait)) { break }
            $exitCode = $merge.Process.ExitCode
            $merge.Process.Dispose()
            $merge.Process = $null
            if ($exitCode -ne 0 -or $merge.Steps.Count -eq 0) { break }
            try {
                $merge.Process = Start-MergeStep $merge
            } catch {
                $exitCode = -1
                Write-Log "Failed to start ffmpeg: $($_.Exception.Message)"
            }
        }
        if ($merge.Process) { continue }
        $script:Merges.Remove($merge)
        Remove-Item -LiteralPath $merge.ListFile -Force -ErrorAction SilentlyContinue
        foreach ($temp in $merge.Temps) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if ($exitCode -eq 0 -and $merge.Steps.Count -eq 0 -and (Test-VideoFile $merge.Output)) {
            if (-not $KeepParts) {
                foreach ($part in $merge.Parts) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
            }
            Show-Notification "Recording saved: $($merge.Output)"
        } else {
            Remove-Item -LiteralPath $merge.Output -Force -ErrorAction SilentlyContinue
            Show-Notification "Could not join recording parts (ffmpeg exit code $exitCode); the parts were kept next to $($merge.Output)." 'Warning'
        }
    }
}

function Get-TargetSessions([string[]]$Serials) {
    $all = @($script:Sessions.Values | Where-Object { -not $_.UserClosed })
    if (-not $Serials -or $Serials.Count -eq 0) { return $all }
    @($all | Where-Object { $Serials -contains $_.Serial })
}

function Invoke-Requests {
    foreach ($file in @(Get-ChildItem -LiteralPath $script:RequestDir -Filter '*.json' -File | Sort-Object Name)) {
        $request = $null
        try { $request = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { Write-Log "Ignoring invalid request $($file.Name)" }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        if (-not $request) { continue }
        $serials = @($request.Serial | Where-Object { $_ })
        switch ($request.Command) {
            'StartRecording' { foreach ($session in (Get-TargetSessions $serials)) { Start-Recording $session } }
            'StopRecording' { foreach ($session in (Get-TargetSessions $serials)) { Stop-Recording $session } }
            'ShowPanel' {
                if ($script:Panel) { Show-Panel }
                else { Show-Notification 'scrcpy monitor is already running (see the tray icon).' }
            }
            'Exit' { Stop-Monitor; return }
        }
    }
}

function Invoke-Tick {
    Invoke-Requests
    if ($script:Exiting) { return }
    Update-Merges

    $now = Get-Date
    $devices = Get-AdbDevices
    $targets = if ($Serial.Count) { $Serial } else { @($devices.Keys | Where-Object { $devices[$_] -eq 'device' }) + @($script:Sessions.Keys) | Select-Object -Unique }

    foreach ($deviceSerial in $targets) {
        $session = if ($script:Sessions.ContainsKey($deviceSerial)) { $script:Sessions[$deviceSerial] } else { New-Session $deviceSerial }
        if ($session.UserClosed) { continue }

        $state = if ($devices.ContainsKey($deviceSerial)) { $devices[$deviceSerial] } else { 'missing' }
        if ($state -ne $session.LastState) {
            Write-Log "[$deviceSerial] adb state: $state"
            $session.LastState = $state
        }
        if ($state -ne 'device') { $session.BootedAt = $null }
        if ($session.Connector -and $session.Connector.HasExited) {
            $session.Connector.Dispose()
            $session.Connector = $null
            $session.NextConnect = $now.AddSeconds(5)
        }
        if ($state -ne 'device' -and -not $session.Connector -and $deviceSerial -match '^[^\s:]+:\d+$' -and $now -ge $session.NextConnect) {
            if ($state -eq 'offline') { [void](Invoke-Adb @('disconnect', $deviceSerial) 5000) }
            $session.Connector = [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:Adb (ConvertTo-ArgumentString @('connect', $deviceSerial))))
        }

        $ready = $null
        Update-Display $session $devices ([ref]$ready)
        if (-not $session.UserClosed) { Update-Recorder $session $devices ([ref]$ready) }
    }

    $tracked = @($script:Sessions.Values)
    if (-not $script:Panel -and $tracked.Count -gt 0 -and -not ($tracked | Where-Object { -not $_.UserClosed })) {
        Write-Log 'All scrcpy windows were closed.'
        Stop-Monitor
        return
    }
    Update-TrayText
}

function Update-TrayText {
    if (-not $script:Tray) { return }
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $text = if ($recording) { "scrcpy monitor - recording $recording device(s)" } else { 'scrcpy monitor' }
    $script:Tray.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
}

function Update-TrayMenu {
    $menu = $script:Tray.ContextMenuStrip
    $menu.Items.Clear()

    if ($script:Panel) {
        $showPanel = $menu.Items.Add('Show control panel')
        $showPanel.Font = New-Object System.Drawing.Font($showPanel.Font, [System.Drawing.FontStyle]::Bold)
        $showPanel.add_Click({ Invoke-Safely { Show-Panel } })
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    $sessions = @($script:Sessions.Values | Where-Object { -not $_.UserClosed } | Sort-Object Title)
    if ($sessions.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem 'No device'
        $empty.Enabled = $false
        [void]$menu.Items.Add($empty)
    }
    foreach ($session in $sessions) {
        $label = if ($session.Recording) { "$($session.Title)  [REC]" } else { $session.Title }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
        $toggle = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($session.Recording) { 'Stop recording' } else { 'Start recording' })
        $toggle.Tag = $session.Serial
        $toggle.add_Click({
            param($sender, $e)
            Invoke-Safely {
                $target = $script:Sessions[$sender.Tag]
                if ($target.Recording) { Stop-Recording $target } else { Start-Recording $target }
                Update-TrayText
            }
        })
        [void]$item.DropDownItems.Add($toggle)
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $startAll = $menu.Items.Add('Start recording on all devices')
    $startAll.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s }; Update-TrayText } })
    $stopAll = $menu.Items.Add('Stop recording on all devices')
    $stopAll.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s }; Update-TrayText } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $openFolder = $menu.Items.Add('Open recordings folder')
    $openFolder.add_Click({ Invoke-Safely { Open-RecordFolder } })
    $openLog = $menu.Items.Add('Open log')
    $openLog.add_Click({ Invoke-Safely { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$script:LogPath`"" } })
    if ($script:UpdateConfig) {
        $checkUpdate = $menu.Items.Add('Check for updates')
        $checkUpdate.add_Click({ Invoke-Safely { Start-UpdateCheck $true } })
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exit = $menu.Items.Add('Exit')
    $exit.add_Click({ Invoke-Safely { Stop-Monitor } })
}

function Open-RecordFolder {
    [void](New-Item -ItemType Directory -Force -Path $RecordDir)
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$RecordDir`""
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action } catch { Write-Log "ERROR: $($_.Exception.Message)" }
}

function Stop-Monitor {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    $script:Timer.Stop()
    Write-Log 'Stopping monitor.'
    if ($script:Panel -and $script:Panel.Visible) {
        Invoke-Safely {
            $script:PanelStatus.Text = 'Stopping: finishing recordings and closing windows...'
            $script:Panel.UseWaitCursor = $true
            $script:Panel.Refresh()
        }
    }
    try {
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-Recording $session } }
        Invoke-Safely { Update-Stops 45000 }
        foreach ($session in @($script:Sessions.Values)) {
            Invoke-Safely {
                if ($session.Connector) {
                    if (-not $session.Connector.HasExited) { $session.Connector.Kill() }
                    $session.Connector.Dispose()
                    $session.Connector = $null
                }
                if ($session.Display) {
                    [void](Stop-ScrcpyProcess $session.Display 10000)
                    $session.Display.Dispose()
                    $session.Display = $null
                }
            }
        }
        Invoke-Safely { Update-Merges 600000 }
    } finally {
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
        if ($script:Panel) { $script:Panel.Dispose() }
        $script:AppContext.ExitThread()
    }
}

function Open-Window([string[]]$Serials) {
    foreach ($serial in $Serials) {
        $session = $script:Sessions[$serial]
        if (-not $session -or -not $session.UserClosed) { continue }
        $session.UserClosed = $false
        $session.DisplayFailures = 0
        $session.NextDisplayAttempt = Get-Date
        Write-Log "[$serial] Reopening scrcpy window."
    }
    $script:Timer.Stop()
    $script:Timer.Interval = 100
    $script:Timer.Start()
}

function Get-SettingsRecordDir {
    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($settings.RecordDir) { return [string]$settings.RecordDir }
    } catch { }
    return $null
}

function Select-RecordFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = 'Choose the folder where recordings are saved'
        if (Test-Path -LiteralPath $RecordDir) { $dialog.SelectedPath = $RecordDir }
        if ($dialog.ShowDialog($script:Panel) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:RecordDir = $dialog.SelectedPath
    } finally {
        $dialog.Dispose()
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SettingsPath))
    @{ RecordDir = $RecordDir } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    Write-Log "Recordings folder changed to $RecordDir"
    Update-Panel
}

function Get-UpdateConfig {
    if (-not $portable) { return $null }
    try {
        $config = Get-Content -LiteralPath (Join-Path $RepoRoot 'update.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($config.Repo -and $config.Version) {
            $built = $null
            if ($config.PSObject.Properties['Built']) {
                $parsed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$config.Built, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $built = $parsed }
            }
            return @{ Repo = [string]$config.Repo; Version = [string]$config.Version; Built = $built }
        }
    } catch { }
    $null
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
    if ($owner) { return [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'scrcpy monitor', $Buttons, $Icon) }
    [System.Windows.Forms.MessageBox]::Show($Text, 'scrcpy monitor', $Buttons, $Icon)
}

function Start-UpdateCheck([bool]$Manual) {
    if (-not $script:UpdateConfig -or $script:UpdateCheck -or $script:Updating) { return }
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript({
        param($Repo)
        $ErrorActionPreference = 'Stop'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'scrcpy-monitor'; Accept = 'application/vnd.github+json' }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return }
            throw
        }
    }).AddArgument($script:UpdateConfig.Repo)
    $script:UpdateCheck = @{ Shell = $shell; Handle = $shell.BeginInvoke(); Manual = $Manual }
    if ($Manual) { $script:UpdateStatus = 'Checking for updates...' }
}

function Complete-UpdateCheck {
    $check = $script:UpdateCheck
    if (-not $check -or -not $check.Handle.IsCompleted) { return }
    $script:UpdateCheck = $null
    $script:UpdateStatus = ''
    try {
        $release = @($check.Shell.EndInvoke($check.Handle)) | Select-Object -First 1
    } catch {
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Write-Log "Update check failed: $message"
        if ($check.Manual) { [void](Show-Message "Could not check for updates:`n$message" 'OK' 'Warning') }
        return
    } finally {
        $check.Shell.Dispose()
    }

    $current = $script:UpdateConfig.Version
    $asset = $null
    if ($release -and $release.PSObject.Properties['assets']) {
        $asset = @($release.assets | Where-Object { $_.name -like 'scrcpy-monitor-portable-*.zip' }) | Select-Object -First 1
    }
    $newer = $true
    if ($asset -and $script:UpdateConfig.Built -and $release.PSObject.Properties['published_at']) {
        $published = [DateTimeOffset]::MinValue
        $publishedText = if ($release.published_at -is [DateTime]) { $release.published_at.ToUniversalTime().ToString('o') } else { [string]$release.published_at }
        if ([DateTimeOffset]::TryParse($publishedText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$published)) {
            $newer = $published -gt $script:UpdateConfig.Built
        }
    }
    if (-not $asset -or $release.tag_name -eq $current -or -not $newer) {
        Write-Log "Update check: $current is up to date."
        if ($check.Manual) { [void](Show-Message "You have the latest version ($current).") }
        return
    }

    $tag = [string]$release.tag_name
    $script:AvailableUpdate = @{ Tag = $tag; Url = [string]$asset.browser_download_url }
    Write-Log "Update available: $tag (current: $current)"
    $notes = if ($release.body) { [string]$release.body } else { '' }
    if ($notes.Length -gt 600) { $notes = $notes.Substring(0, 600) + '...' }
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $text = "scrcpy monitor $tag is available (you have $current)."
    if ($notes) { $text += "`n`n$notes" }
    $text += "`n`nUpdate now? The monitor restarts"
    $text += if ($recording) { " and the $recording recording(s) in progress are stopped and saved." } else { '.' }
    if ((Show-Message $text 'YesNo' 'Question') -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Update
    } else {
        $script:UpdateStatus = "Update $tag available"
    }
}

function Start-Update {
    $update = $script:AvailableUpdate
    if ($script:Updating -or -not $update) { return }
    $updater = Join-Path $script:StateDir 'scrcpy-monitor-updater.ps1'
    Copy-Item -LiteralPath $script:ScriptPath -Destination $updater -Force
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $updater, '-ApplyUpdate', $update.Url, '-UpdateTarget', $RepoRoot)
    $script:Updater = Start-Process -FilePath $script:PowerShellExe -ArgumentList (ConvertTo-ArgumentString $arguments) -WindowStyle Hidden -PassThru
    $script:Updating = $true
    $script:UpdateStatus = "Downloading update $($update.Tag)... the monitor restarts when it is ready."
    Write-Log "Updating to $($update.Tag)"
}

function Update-UpdaterState {
    if (-not $script:Updater -or -not $script:Updater.HasExited) { return }
    $script:Updater.Dispose()
    $script:Updater = $null
    $script:Updating = $false
    $script:UpdateStatus = ''
    Write-Log 'Update was not installed.'
}

function Get-SessionStatus($Session) {
    if ($Session.UserClosed) { return 'Window closed' }
    if ($Session.LastState -ne 'device') {
        $state = if ($Session.LastState) { $Session.LastState } else { 'missing' }
        return "Waiting for device ($state)"
    }
    if ($Session.Display) { return 'Mirroring' }
    'Opening window'
}

function Get-SessionRecordingText($Session) {
    if (-not $Session.Recording) { return $(if ($Session.Stopping) { 'Saving...' } else { '' }) }
    $text = 'REC {0:hh\:mm\:ss}' -f ((Get-Date) - $Session.RecordingStartedAt)
    if ($Session.Stopping) { $text += ' (saving previous)' }
    elseif (-not $Session.Recorder) { $text += ' (waiting for device)' }
    elseif ($Session.Parts.Count -gt 1) { $text += " (part $($Session.Parts.Count))" }
    $text
}

function Get-SelectedSessions {
    @($script:PanelList.SelectedItems | ForEach-Object { $script:Sessions[$_.Name] } | Where-Object { $_ })
}

function Update-PanelButtons {
    $selected = Get-SelectedSessions
    $open = @($selected | Where-Object { -not $_.UserClosed })
    $toStart = @($open | Where-Object { -not $_.Recording })
    $script:PanelToggle.Text = if ($toStart.Count -gt 0 -or $open.Count -eq 0) { 'Start recording' } else { 'Stop recording' }
    $script:PanelToggle.Enabled = $open.Count -gt 0
    $script:PanelOpen.Enabled = @($selected | Where-Object { $_.UserClosed }).Count -gt 0
}

function Update-Panel {
    if (-not $script:Panel -or $script:Panel.IsDisposed -or -not $script:Panel.Visible) { return }
    $list = $script:PanelList
    $list.BeginUpdate()
    try {
        foreach ($session in @($script:Sessions.Values)) {
            $index = $list.Items.IndexOfKey($session.Serial)
            if ($index -lt 0) {
                $item = $list.Items.Add($session.Serial, $session.Title, -1)
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
            } else {
                $item = $list.Items[$index]
            }
            $texts = @($session.Title, (Get-SessionStatus $session), (Get-SessionRecordingText $session))
            for ($i = 0; $i -lt $texts.Count; $i++) {
                if ($item.SubItems[$i].Text -ne $texts[$i]) { $item.SubItems[$i].Text = $texts[$i] }
            }
            $color = if ($session.Recording) { [System.Drawing.Color]::Firebrick } elseif ($session.UserClosed) { [System.Drawing.SystemColors]::GrayText } else { [System.Drawing.SystemColors]::WindowText }
            if ($item.ForeColor -ne $color) { $item.ForeColor = $color }
        }
    } finally {
        $list.EndUpdate()
    }
    $status = "Recordings: $RecordDir"
    if ($script:Merges.Count -gt 0) { $status = "Joining $($script:Merges.Count) recording(s)...  $status" }
    if ($script:UpdateStatus) { $status = "$($script:UpdateStatus)  |  $status" }
    if ($script:PanelStatus.Text -ne $status) { $script:PanelStatus.Text = $status }
    Update-PanelButtons
}

function Show-Panel {
    if (-not $script:Panel -or $script:Panel.IsDisposed) { return }
    $script:Panel.Show()
    [void][ScrcpyMonitor.Window]::ShowWindow($script:Panel.Handle, 5)
    if ($script:Panel.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:Panel.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $script:Panel.Activate()
    Update-Panel
}

function New-PanelButton([System.Windows.Forms.Control]$Parent, [string]$Text, [scriptblock]$OnClick) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.Tag = $OnClick
    $button.add_Click({
        param($sender, $e)
        Invoke-Safely { & $sender.Tag; Update-TrayText; Update-Panel }
    })
    $Parent.Controls.Add($button)
    $button
}

function New-Panel {
    Add-Type -Namespace ScrcpyMonitor -Name Window -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);'
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($script:UpdateConfig) { "scrcpy monitor $($script:UpdateConfig.Version)" } else { 'scrcpy monitor' }
    $form.Size = New-Object System.Drawing.Size(720, 380)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 260)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    if ($script:Icon) { $form.Icon = $script:Icon }

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.Sorting = [System.Windows.Forms.SortOrder]::Ascending
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    [void]$list.Columns.Add('Device', 270)
    [void]$list.Columns.Add('Status', 190)
    [void]$list.Columns.Add('Recording', 190)
    $list.add_SelectedIndexChanged({ Invoke-Safely { Update-PanelButtons } })
    $form.Controls.Add($list)

    $deviceButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $deviceButtons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $deviceButtons.AutoSize = $true
    $deviceButtons.Padding = New-Object System.Windows.Forms.Padding(4)
    $form.Controls.Add($deviceButtons)

    $globalButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $globalButtons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $globalButtons.AutoSize = $true
    $globalButtons.Padding = New-Object System.Windows.Forms.Padding(4)
    $form.Controls.Add($globalButtons)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.SizingGrip = $false
    $status = New-Object System.Windows.Forms.ToolStripStatusLabel
    $status.Spring = $true
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    [void]$statusStrip.Items.Add($status)
    $form.Controls.Add($statusStrip)

    $script:PanelList = $list
    $script:PanelStatus = $status
    $script:PanelToggle = New-PanelButton $deviceButtons 'Start recording' {
        $selected = Get-SelectedSessions | Where-Object { -not $_.UserClosed }
        $toStart = @($selected | Where-Object { -not $_.Recording })
        if ($toStart.Count -gt 0) { foreach ($s in $toStart) { Start-Recording $s } }
        else { foreach ($s in $selected) { Stop-Recording $s } }
    }
    $script:PanelOpen = New-PanelButton $deviceButtons 'Open window' { Open-Window @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $list.add_DoubleClick({ Invoke-Safely { $script:PanelToggle.PerformClick() } })

    [void](New-PanelButton $globalButtons 'Start all' { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s } })
    [void](New-PanelButton $globalButtons 'Stop all' { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s } })
    [void](New-PanelButton $globalButtons 'Open recordings folder' { Open-RecordFolder })
    [void](New-PanelButton $globalButtons 'Change folder...' { Select-RecordFolder })
    [void](New-PanelButton $globalButtons 'Open log' { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$script:LogPath`"" })
    if ($script:UpdateConfig) { [void](New-PanelButton $globalButtons 'Check for updates' { Start-UpdateCheck $true }) }
    [void](New-PanelButton $globalButtons 'Exit' { $script:ExitRequested = $true })

    $form.add_FormClosing({
        param($sender, $e)
        if ($script:Exiting) { return }
        $e.Cancel = $true
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and $script:Tray) {
            $sender.Hide()
            if (-not $script:PanelHiddenOnce) {
                $script:PanelHiddenOnce = $true
                Show-Notification 'scrcpy monitor keeps running in the tray. Double-click the tray icon to show the control panel.'
            }
        } else {
            $script:ExitRequested = $true
        }
    })
    $form.add_Shown({ Invoke-Safely { Update-Panel } })
    $form
}

$RepoRoot = $PSScriptRoot
$script:ScriptPath = $PSCommandPath
$portable = -not $PSBoundParameters.ContainsKey('BuildDir') -and (Test-Path -LiteralPath (Join-Path $RepoRoot 'scrcpy.exe') -PathType Leaf)
if ($portable) {
    $script:Scrcpy = Join-Path $RepoRoot 'scrcpy.exe'
    $script:Server = Join-Path $RepoRoot 'scrcpy-server'
    $script:IconDir = $RepoRoot
} else {
    $buildPath = if ([System.IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $RepoRoot $BuildDir }
    $script:Scrcpy = Join-Path $buildPath 'app\scrcpy.exe'
    $script:Server = Join-Path $buildPath 'server\scrcpy-server'
    $script:IconDir = Join-Path $RepoRoot 'app\data'
}
$script:PowerShellExe = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $script:Scrcpy -PathType Leaf) -or -not (Test-Path -LiteralPath $script:Server -PathType Leaf)) {
    if ($portable) { Show-Error "scrcpy-server is missing from '$RepoRoot'. Extract the whole package again." }
    else { Show-Error "scrcpy is not built in '$buildPath'. Build it first (meson setup $BuildDir ... then ninja -C $BuildDir) or pass -BuildDir." }
    exit 1
}

$msysCandidates = if ($MsysBin) { @($MsysBin) } elseif ($portable) { @($RepoRoot) } else { @('D:\msys64\mingw64\bin', 'C:\msys64\mingw64\bin') }
$script:MsysBinPath = $msysCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'SDL3.dll') } | Select-Object -First 1
if (-not $script:MsysBinPath) { Write-Log 'WARNING: MSYS2 mingw64\bin with SDL3.dll not found; scrcpy needs its DLLs in PATH.' }

$adbCandidates = @($(if ($portable) { Join-Path $RepoRoot 'adb.exe' }), $env:ADB, (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
$script:Adb = Resolve-Tool $AdbPath $adbCandidates 'adb.exe'
if (-not $script:Adb) {
    Show-Error 'adb.exe not found. Add platform-tools to PATH or pass -AdbPath.'
    exit 1
}

$toolDir = if ($script:MsysBinPath) { $script:MsysBinPath } else { '' }
$script:Ffmpeg = Resolve-Tool $null @($(if ($toolDir) { Join-Path $toolDir 'ffmpeg.exe' })) 'ffmpeg.exe'
$script:Ffprobe = Resolve-Tool $null @($(if ($toolDir) { Join-Path $toolDir 'ffprobe.exe' })) 'ffprobe.exe'

if ($ScrcpyArgs | Where-Object { $_ -match '^(--record(=|$)|-r)' }) {
    Show-Error 'Use -Record (or the record button) to record instead of passing --record to scrcpy.'
    exit 1
}

if (-not $RecordDir) {
    $RecordDir = Get-SettingsRecordDir
    if (-not $RecordDir) {
        $RecordDir = if ($portable) { Join-Path ([Environment]::GetFolderPath('MyVideos')) 'scrcpy Recordings' } else { 'D:\Charles Manalo\Recordings' }
    }
}

[void](Invoke-Hidden $script:Adb @('start-server') 15000)

if ($List) {
    $devices = Get-AdbDevices
    if ($devices.Count -eq 0) { Write-Host 'No devices found.' }
    foreach ($key in ($devices.Keys | Sort-Object)) {
        $model = if ($devices[$key] -eq 'device') { Get-DeviceProp $key 'ro.product.model' } else { '' }
        Write-Host ('{0,-30} {1,-14} {2}' -f $key, $devices[$key], $model)
    }
    exit 0
}

$createdMutex = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdMutex)
if (-not $createdMutex) {
    if ($NoPanel) {
        Show-Error 'scrcpy monitor is already running. Use -Command StartRecording, StopRecording, ShowPanel or Exit to control it.'
        exit 1
    }
    Send-MonitorRequest 'ShowPanel' @()
    exit 0
}

Get-ChildItem -LiteralPath $script:RequestDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $script:ControlDir -File | Remove-Item -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Sessions = @{}
$script:Merges = New-Object System.Collections.ArrayList
$script:Stops = New-Object System.Collections.ArrayList
$script:Exiting = $false
$script:ExitRequested = $false
$script:RecordOnStart = [bool]$Record
$script:Tray = $null
$script:Panel = $null
$script:PanelHiddenOnce = $false
$script:UpdateConfig = Get-UpdateConfig
$script:UpdateCheck = $null
$script:UpdateStatus = ''
$script:AvailableUpdate = $null
$script:Updating = $false
$script:Updater = $null
$iconPath = Join-Path $script:IconDir 'icon.ico'
$script:Icon = if (Test-Path -LiteralPath $iconPath) { New-Object System.Drawing.Icon $iconPath } else { $null }

Write-Log "Monitor started (scrcpy: $script:Scrcpy, adb: $script:Adb, devices: $(if ($Serial.Count) { $Serial -join ', ' } else { 'all connected' }), recordings: $RecordDir)"

if (-not $NoPanel) { $script:Panel = New-Panel }

if (-not $NoTray) {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = if ($script:Icon) { $script:Icon } else { [System.Drawing.SystemIcons]::Application }
    $script:Tray.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
    $script:Tray.ContextMenuStrip.add_Opening({ Invoke-Safely { Update-TrayMenu } })
    $script:Tray.add_DoubleClick({ Invoke-Safely { if ($script:Panel) { Show-Panel } else { Open-RecordFolder } } })
    $script:Tray.Text = 'scrcpy monitor'
    $script:Tray.Visible = $true
}

$script:AppContext = New-Object System.Windows.Forms.ApplicationContext
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 100
$script:Timer.add_Tick({
    $script:Timer.Stop()
    Invoke-Safely { Invoke-Tick }
    if (-not $script:Exiting) {
        $script:Timer.Interval = $PollSeconds * 1000
        $script:Timer.Start()
    }
})
$script:Timer.Start()

$script:FastTimer = New-Object System.Windows.Forms.Timer
$script:FastTimer.Interval = 300
$script:FastTimerTicks = 0
$script:FastTimer.add_Tick({
    if ($script:Exiting) { $script:FastTimer.Stop(); return }
    if ($script:ExitRequested) { Invoke-Safely { Stop-Monitor }; return }
    Invoke-Safely { Invoke-ControlRequests }
    Invoke-Safely { Update-Stops }
    Invoke-Safely { Complete-UpdateCheck }
    Invoke-Safely { Update-UpdaterState }
    $script:FastTimerTicks++
    if ($script:FastTimerTicks % 3 -eq 0) { Invoke-Safely { Update-Panel } }
})
$script:FastTimer.Start()

if ($script:Panel) { Show-Panel }
if (-not $NoUpdateCheck) { Invoke-Safely { Start-UpdateCheck $false } }

try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
} finally {
    $script:Timer.Dispose()
    $script:FastTimer.Dispose()
    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
    Write-Log 'Monitor stopped.'
}
