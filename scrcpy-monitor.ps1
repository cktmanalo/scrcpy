<#
.SYNOPSIS
    Mirrors one or more adb devices with the scrcpy built in this repository, keeps each window open while
    the device restarts, arranges the windows without overlapping, and records the screen on demand.

.DESCRIPTION
    One scrcpy window is opened per device with --reconnect, so the window stays open while the device
    restarts and mirroring resumes in the same window. Every scrcpy process runs without a console window.
    A restarting device stays in the list as "Device restarting"; a device that is turned off, unplugged or
    closed is removed from the list. Closing a scrcpy window, or "Stop and close", stops that device;
    "Refresh" in the control panel or tray icon, or running the monitor again, shows it again. Once every
    window is closed, the monitor exits unless the control panel is open. The control panel opens when the
    first device window starts; closing it keeps the monitor in the tray. Global actions are in its File,
    Recording, Logs, Window and Help menus, and a column header click sorts the device list. Ctrl+Alt+M
    opens the tray menu at the mouse pointer from any application.

    Device windows are arranged on the screen of the control panel: one device is centered, several are
    placed around the center without overlapping, each at 100% when it fits and scaled down only to fit.
    They are arranged again when a device window opens or closes, and from Window > "Arrange windows" or
    "Arrange device windows" in the tray icon. Any of --window-x, --window-y, --window-width,
    --window-height or --fullscreen turns automatic arranging off.

    Recording runs in a separate hidden scrcpy process that can be started and stopped at any time with the
    record button in the top-right corner of each scrcpy window (or Alt+E), the control panel, the tray icon
    or -Command. A device restart while recording continues the recording in a new part, and the parts are
    joined into one MP4 with ffmpeg when the recording stops. With ffmpeg, the device name is added as a
    header above the screen in every saved recording:
        <RecordDir>\<Device Name>\Screen_Recording_<Device Name>_<yyyyMMdd_HHmmss>.mp4
    If the device cannot run a second hardware video encoder, the recorder switches to a software encoder.

    "Record combined" in the control panel records the selected devices as usual and, once all of them have
    stopped, also joins their recordings into one video laid out like the arranged device windows, with
    each device name above its screen (no audio, synchronized to about one second, at most 2560x1440).
    Every screen is scaled by the same factor, so a smaller device keeps its real size and proportions:
        <RecordDir>\Combined\Screen_Recording_Combined_<yyyyMMdd_HHmmss>.mp4

    Recording > "Screen recording" in the control panel or the tray icon records the desktop instead of a
    device: a rectangle on screen that is moved and resized by its frame, a selected area, one screen or all
    screens, a window (a device window or any other window, followed when it moves) or the area around the
    mouse. Its toolbar starts and stops the recording, pauses it, takes a screenshot and opens the folder;
    F12 starts or stops, Shift+F12 pauses or resumes and F11 takes a screenshot from any application. The
    frame and toolbar are not recorded. A pause or a window resize starts a new part, and the parts are joined
    into one MP4 when the recording stops:
        <RecordDir>\Screen Recordings\Screen_Capture_<yyyyMMdd_HHmmss>.mp4
        <RecordDir>\Screen Recordings\Screenshot_<yyyyMMdd_HHmmss_fff>.png

    Print Screen, Recording > "Snip" in the control panel, the tray icon or -Command Snip works like the
    Snipping Tool at any time: it freezes the screen and snips an area, a window, one screen or all screens.
    The snip is copied to the clipboard, saved as PNG or JPEG (Snip > "Save snips as ...") and opened in a
    markup editor (pen, highlighter, rectangle, arrow, eraser, crop, undo and redo, copy, save, save as)
    unless Snip > "Open markup editor after snipping" is turned off. Snip > "Use Print Screen to snip" turns
    the Print Screen key on or off:
        <RecordDir>\Screenshots\Snip_<yyyyMMdd_HHmmss_fff>.png

    The recordings folder is -RecordDir if given, else the folder chosen from the tray icon, else the
    default. When scrcpy.exe is next to this script (portable package), scrcpy, adb and ffmpeg are used from
    this folder.

    The status bar of the control panel shows the free space on the drive of the recordings folder (click
    it to change the folder). Below 2 GB free, starting a recording asks whether to choose another folder
    and a running recording shows one warning; below 500 MB, recording does not start, and every device
    and screen recording is stopped and saved.

    "Start device logs" in the control panel, its Logs menu, the tray icon or -Command StartLogs saves the
    adb logcat of a device to a text file in the Android Studio Logcat format (date, time, PID-TID, tag,
    package, level, message) while the device is mirrored. The capture stays connected while the device
    restarts or reconnects, and the file shows where the device restarted. It is written as it runs and
    saved when the logs are stopped, the device is closed or disconnected, or the monitor exits:
        <DeviceLogDir>\<Device Name>\logs_<Device Name>_<Device Serial>_<yyyyMMdd_HHmmss>.txt
    The lines of the apps checked in Logs > "Choose apps for per-app logs..." (which lists PA and PIA first,
    then every app open, running or installed on the connected devices, none checked by default, like the
    Logcat package filter) are also saved to a file with the same name in a subfolder named after the app
    package; with no app checked, only the full device log is saved:
        <DeviceLogDir>\<Device Name>\<App Package>\logs_<Device Name>_<Device Serial>_<yyyyMMdd_HHmmss>.txt
    The device logs folder is chosen from Logs > "Change device logs folder...". The Device logs column
    shows the elapsed time and size of each log.
    APP STATUS lines record whether PA, PIA and the checked apps are running (with the pid) when logging
    starts and after every restart or reconnection, and APP STARTED, APP STOPPED, APP CRASHED and APP NOT
    RESPONDING lines record those events as they happen.

    Wi-Fi devices that advertise adb on the network (mDNS, for example after "adb tcpip 5555") are found and
    connected automatically unless -NoDiscovery or -Serial is given. "Connect Wi-Fi device..." in the control
    panel or tray icon connects a device by IP address, and "Disconnect" saves any recording, closes the
    window and ends the adb connection of a Wi-Fi device until it is reconnected.

    At startup (unless -NoUpdateCheck is given or Help > "Check for updates automatically" is turned off)
    and from "Check for updates" in the control panel or tray icon, the monitor checks its GitHub
    repository for a newer release. A portable package built with
    package-portable.ps1 then updates itself and restarts; a git checkout (repository of the origin remote)
    only offers to open the release page.

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
.EXAMPLE
    .\scrcpy-monitor.ps1 -Command StartLogs -Serial 192.168.68.100:5555
.EXAMPLE
    .\scrcpy-monitor.ps1 -Command Snip
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
    [ValidateSet('StartRecording', 'StopRecording', 'StartLogs', 'StopLogs', 'ShowPanel', 'Snip', 'Exit')]
    [string]$Command,
    [switch]$List,
    [switch]$NoTray,
    [switch]$NoPanel,
    [switch]$NoUpdateCheck,
    [switch]$NoDiscovery,
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
$script:Prompts = 0

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
        [void][System.Windows.Forms.MessageBox]::Show($Message, 'Scrcpy Monitor', 'OK', 'Error')
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
    $request = Join-Path $script:RequestDir "$name.json"
    Move-Item -LiteralPath $temp -Destination $request
    $request
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
        if (Test-MonitorRunning) { [void](Send-MonitorRequest 'Exit' @()) }
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
        $guideName = 'scrcpy-monitor-guide.docx'
        & $robocopy $source.DirectoryName $UpdateTarget /E /R:10 /W:1 /NP /NFL /NDL /NJH /NJS /XF $guideName | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying the update failed (robocopy exit code $LASTEXITCODE)." }
        $guide = Join-Path $source.DirectoryName $guideName
        if (Test-Path -LiteralPath $guide) {
            try { Copy-Item -LiteralPath $guide -Destination $UpdateTarget -Force -ErrorAction Stop }
            catch { Write-Log "Update: could not replace $guideName (close it if it is open): $($_.Exception.Message)" }
        }
        Write-Log 'Update: installed.'
        try { Set-Content -LiteralPath (Join-Path $script:StateDir 'updated.txt') -Value $UpdateTarget -Encoding UTF8 } catch { }
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
    [void](Send-MonitorRequest $Command $Serial)
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

function Close-RedirectedProcess([System.Diagnostics.Process]$Process) {
    if (-not $Process) { return }
    try { $Process.StandardOutput.Dispose() } catch { }
    try { $Process.StandardError.Dispose() } catch { }
    $Process.Dispose()
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
        Close-RedirectedProcess $process
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

function Get-ConnectionType([string]$DeviceSerial) {
    if ($DeviceSerial -match '^emulator-\d+$') { return 'Emulator' }
    if ($DeviceSerial -match ':\d+$' -or $DeviceSerial -match '\._adb(-tls-connect)?\._tcp') { return 'Wi-Fi' }
    'USB'
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
    if ($script:SessionEnding) {
        try {
            [void][ScrcpyMonitor.Window]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
            [void][ScrcpyMonitor.Window]::FreeConsole()
            if (-not ([ScrcpyMonitor.Window]::AttachConsole([uint32]$Process.Id) -and [ScrcpyMonitor.Window]::GenerateConsoleCtrlEvent(0, 0))) {
                Write-Log "Could not send Ctrl+C to process $($Process.Id)."
            }
            [void][ScrcpyMonitor.Window]::FreeConsole()
        } catch {
            Write-Log "Could not send Ctrl+C to process $($Process.Id): $($_.Exception.Message)"
        }
        return $null
    }
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
    if (-not $script:Ffprobe -or $script:SessionEnding) { return $true }
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

function Get-EncoderCacheKeys([string]$DeviceSerial, [string]$Model) {
    $codec = Get-RecordCodec
    $keys = @("$DeviceSerial|$codec")
    if ($Model -and $Model -ne $DeviceSerial) { $keys += "model:$Model|$codec" }
    $keys
}

function Get-CachedEncoder([string]$DeviceSerial, [string]$Model) {
    try {
        $cache = Get-Content -LiteralPath $script:EncoderCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($key in (Get-EncoderCacheKeys $DeviceSerial $Model)) {
            $value = $cache.PSObject.Properties[$key]
            if ($value -and $value.Value) { return [string]$value.Value }
        }
    } catch { }
    return $null
}

function Set-CachedEncoder([string]$DeviceSerial, [string]$Model, [string]$Encoder) {
    $cache = @{}
    try {
        $json = Get-Content -LiteralPath $script:EncoderCachePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($property in $json.PSObject.Properties) { $cache[$property.Name] = $property.Value }
    } catch { }
    foreach ($key in (Get-EncoderCacheKeys $DeviceSerial $Model)) {
        if ($Encoder) { $cache[$key] = $Encoder } else { $cache.Remove($key) }
    }
    try { $cache | ConvertTo-Json | Set-Content -LiteralPath $script:EncoderCachePath -Encoding UTF8 } catch { }
}

function Show-Notification([string]$Message, [string]$Icon = 'Info') {
    Write-Log $Message
    if ($script:Tray) {
        try { $script:Tray.ShowBalloonTip(4000, 'Scrcpy Monitor', $Message, $Icon) } catch { }
    }
}

function Get-ExistingFolder([string]$Path) {
    $folder = $Path
    while ($folder) {
        if ([System.IO.Directory]::Exists($folder)) { return $folder }
        try { $folder = [System.IO.Path]::GetDirectoryName($folder) } catch { return $null }
    }
    $null
}

function Get-DiskFreeBytes([string]$Path) {
    try {
        $folder = Get-ExistingFolder $Path
        if (-not $folder) { return -1L }
        if (-not $script:Fso) { $script:Fso = New-Object -ComObject Scripting.FileSystemObject }
        $drive = $script:Fso.GetDrive($script:Fso.GetDriveName($folder))
        if (-not $drive.IsReady) { return -1L }
        return [long]$drive.AvailableSpace
    } catch {
        return -1L
    }
}

function Get-RecordFreeSpace([switch]$Force) {
    $now = Get-Date
    if ($Force -or $now -ge $script:DiskNextCheck -or $script:DiskCheckedDir -ne $RecordDir) {
        $script:DiskFree = Get-DiskFreeBytes $RecordDir
        $script:DiskCheckedDir = $RecordDir
        $script:DiskNextCheck = $now.AddSeconds($(if ($script:DiskFree -lt 0) { 60 } else { 10 }))
    }
    $script:DiskFree
}

function Get-DiskLevel([long]$Free) {
    if ($Free -lt 0) { return 'unknown' }
    if ($Free -lt $script:DiskCritical) { return 'critical' }
    if ($Free -lt $script:DiskLow) { return 'low' }
    'ok'
}

function Confirm-RecordSpace {
    if ($script:DiskPrompting) { return $false }
    if (((Get-Date) - $script:DiskConfirmedAt).TotalSeconds -lt 5) { return $true }
    $script:DiskPrompting = $true
    try {
        while ($true) {
            $free = Get-RecordFreeSpace -Force
            $level = Get-DiskLevel $free
            if ($level -eq 'ok' -or $level -eq 'unknown') { break }
            $text = "Only $(Format-ScreenBytes $free) is free on the drive of the recordings folder:`n$RecordDir`n`n"
            if ($level -eq 'critical') {
                $answer = Show-Message ($text + 'Recording needs at least 500 MB of free space. Choose another recordings folder?') 'YesNo' 'Error'
                if ($answer -ne 'Yes') { return $false }
            } else {
                $answer = Show-Message ($text + "Recording stops automatically when less than 500 MB is left.`n`nYes: choose another recordings folder`nNo: record here anyway`nCancel: do not record") 'YesNoCancel' 'Warning'
                if ($answer -eq 'No') { break }
                if ($answer -ne 'Yes') { return $false }
            }
            if (-not (Select-RecordFolder)) { return $false }
            if ((Get-DiskLevel (Get-RecordFreeSpace -Force)) -ne 'critical') { break }
        }
        $script:DiskConfirmedAt = Get-Date
        return $true
    } finally {
        $script:DiskPrompting = $false
    }
}

function Update-DiskSpace {
    if ($script:Exiting) { return }
    $sessions = @($script:Sessions.Values | Where-Object { $_.Recording })
    $screen = $script:ScreenRec -and $script:ScreenRec.Recording
    if (-not $sessions.Count -and -not $screen) {
        $script:DiskWarned = $false
        return
    }
    $free = Get-RecordFreeSpace
    $level = Get-DiskLevel $free
    if ($level -eq 'critical') {
        foreach ($session in $sessions) { Stop-Recording $session }
        if ($screen) { Stop-ScreenRecording }
        $script:DiskWarned = $false
        Show-Notification "Recording stopped: only $(Format-ScreenBytes $free) is left in $RecordDir. The recordings were saved. Free up space or change the recordings folder." 'Error'
        Update-TrayText
    } elseif ($level -eq 'low') {
        if (-not $script:DiskWarned) {
            $script:DiskWarned = $true
            Show-Notification "Low disk space: $(Format-ScreenBytes $free) left for recordings in $RecordDir. Recording stops automatically below 500 MB." 'Warning'
        }
    } elseif ($level -eq 'ok') {
        $script:DiskWarned = $false
    }
}

function Get-FreePortBlock {
    $used = @($script:Sessions.Values | ForEach-Object { $_.Port })
    for ($port = 27200; $port -lt 29200; $port += 4) {
        if ($used -notcontains $port) { return $port }
    }
    27200
}

function Test-HasPortArg($Arguments) {
    [bool]@($Arguments | Where-Object { $_ -match '^(--port|-p)' }).Count
}

function New-Session([string]$DeviceSerial, [string]$State) {
    $session = [pscustomobject]@{
        Serial             = $DeviceSerial
        Port               = Get-FreePortBlock
        SafeSerial         = ConvertTo-SafeName $DeviceSerial
        Name               = $null
        Title              = $DeviceSerial
        Connection         = Get-ConnectionType $DeviceSerial
        LastState          = $null
        BootedAt           = $null
        NextConnect        = Get-Date
        Connector          = $null
        UserClosed         = $false
        Disconnected       = $false
        MissingSince       = $null
        GoneSince          = $null
        PowerWatch         = $null
        NextPowerWatch     = Get-Date
        RestartingAt       = $null
        PoweringOff        = $false
        PendingAction      = $null
        MovedTo            = $null
        MoveAddress        = $null
        MoveDeadline       = Get-Date
        Display            = $null
        DisplayStartedAt   = $null
        WindowShown        = $false
        ScrcpyPid          = 0
        NaturalSize        = 0
        NextWake           = Get-Date
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
        CodecErrorAt       = $null
        RecorderFailures   = 0
        NextRecordAttempt  = Get-Date
        SoftwareEncoder    = $(if ($RecordEncoder -eq 'auto') { Get-CachedEncoder $DeviceSerial } else { $null })
        ControlPath        = Join-Path $script:ControlDir "$(ConvertTo-SafeName $DeviceSerial).state"
        Stopping           = $false
        RecordPending      = $script:RecordOnStart
        CombineMember      = $null
        PartStarts         = @{}
        PartStartPending   = $false
        LogCapture         = $null
    }
    $script:Sessions[$DeviceSerial] = $session
    Set-RecordState $session
    $session
}

function Set-RecordState($Session) {
    $state = if ($Session.Recording) { '1' } else { '0' }
    try { [System.IO.File]::WriteAllText($Session.ControlPath, $state) } catch { Write-Log "[$($Session.Serial)] Could not write $($Session.ControlPath): $($_.Exception.Message)" }
}

function Invoke-ControlRequests {
    if ($script:DiskPrompting) { return }
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
            'start' { if (Confirm-RecordSpace) { Start-Recording $session } }
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
    if (-not (Test-HasPortArg $ScrcpyArgs)) { $arguments += "--port=$($Session.Port):$($Session.Port + 1)" }
    $arguments += $ScrcpyArgs
    $log = Join-Path $script:LogDir "$($Session.SafeSerial)-display.log"
    Stop-OrphanServers $Session.Serial
    Write-Log "[$($Session.Serial)] Starting scrcpy window: $(ConvertTo-ArgumentString $arguments)"
    $Session.Display = Start-ScrcpyProcess $arguments $log
    $Session.DisplayStartedAt = Get-Date
    $Session.WindowShown = $false
    $Session.ScrcpyPid = 0
    $Session.NextWake = (Get-Date).AddSeconds(5)
    if ($script:PanelPending) { Show-Panel }
}

function Test-WindowShown($Session) {
    if (-not $Session.ScrcpyPid) {
        $child = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($Session.Display.Id) AND Name='scrcpy.exe'" -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $child) { return $false }
        $Session.ScrcpyPid = [int]$child.ProcessId
    }
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($Session.ScrcpyPid)
        try { return $process.MainWindowHandle -ne [IntPtr]::Zero } finally { $process.Dispose() }
    } catch { return $false }
}

function Request-Arrange {
    if (-not $script:AutoArrange) { return }
    if (-not $script:ArrangeRequestedAt) { $script:ArrangeRequestedAt = Get-Date }
}

function Update-Arrange {
    if (-not $script:ArrangeRequestedAt) { return }
    $opening = @($script:Sessions.Values | Where-Object { $_.Display -and -not $_.WindowShown -and -not $_.Display.HasExited })
    if ($opening.Count -and ((Get-Date) - $script:ArrangeRequestedAt).TotalSeconds -lt 10) { return }
    Invoke-ArrangeWindows
}

function Initialize-WindowArrange {
    if ('ScrcpyMonitor.WindowArrange' -as [type]) { return }
    Add-Type -TypeDefinition @'
namespace ScrcpyMonitor {
    using System;
    using System.Runtime.InteropServices;
    public static class WindowArrange {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        public static IntPtr EnterPerMonitor() {
            try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; }
        }
        public static void Leave(IntPtr previous) {
            if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
        }
        public static bool GetMonitor(IntPtr hWnd, out RECT monitor, out RECT work) {
            var info = new MONITORINFO();
            info.Size = Marshal.SizeOf(typeof(MONITORINFO));
            bool found = GetMonitorInfo(MonitorFromWindow(hWnd, hWnd == IntPtr.Zero ? 1u : 2u), ref info);
            monitor = info.Monitor;
            work = info.Work;
            return found;
        }
    }
}
'@
}

function Get-ArrangeArea {
    $anchor = [IntPtr]::Zero
    if ($script:Panel -and -not $script:Panel.IsDisposed -and $script:Panel.IsHandleCreated) { $anchor = $script:Panel.Handle }
    $monitor = New-Object ScrcpyMonitor.WindowArrange+RECT
    $work = New-Object ScrcpyMonitor.WindowArrange+RECT
    if (-not [ScrcpyMonitor.WindowArrange]::GetMonitor($anchor, [ref]$monitor, [ref]$work)) { return $null }
    New-Object System.Drawing.Rectangle($work.Left, $work.Top, ($work.Right - $work.Left), ($work.Bottom - $work.Top))
}

function Get-WindowLayout([System.Drawing.Rectangle]$Area, $Items, [int]$Gap = 8) {
    $count = @($Items).Count
    if (-not $count) { return $null }
    $frameHeight = ($Items | Measure-Object -Property FrameHeight -Maximum).Maximum
    $best = $null
    $bestScore = 0
    for ($rows = 1; $rows -le $count; $rows++) {
        $columns = [int][Math]::Ceiling($count / $rows)
        if ([int][Math]::Ceiling($count / $columns) -ne $rows) { continue }
        $groups = @(for ($start = 0; $start -lt $count; $start += $columns) { , @($Items[$start..([Math]::Min($start + $columns, $count) - 1)]) })
        $height = ($Area.Height - ($rows + 1) * $Gap) / $rows - $frameHeight
        foreach ($group in $groups) {
            $aspect = ($group | Measure-Object -Property Aspect -Sum).Sum
            $frames = ($group | Measure-Object -Property FrameWidth -Sum).Sum
            $height = [Math]::Min($height, ($Area.Width - ($group.Count + 1) * $Gap - $frames) / $aspect)
        }
        if ($height -lt 50) { continue }
        $score = 0
        foreach ($item in $Items) { $h = [Math]::Min($height, $item.MaxHeight); $score += $h * $h * $item.Aspect }
        if ($score -gt $bestScore * 1.001) { $bestScore = $score; $best = @{ Groups = $groups; Height = $height } }
    }
    if (-not $best) { return $null }
    $rowSizes = @(foreach ($group in $best.Groups) {
        $sizes = @(foreach ($item in $group) {
            $clientHeight = [Math]::Min($best.Height, $item.MaxHeight)
            New-Object System.Drawing.Size([int][Math]::Round($clientHeight * $item.Aspect + $item.FrameWidth), [int][Math]::Round($clientHeight + $item.FrameHeight))
        })
        , $sizes
    })
    $totalHeight = (@($rowSizes | ForEach-Object { ($_ | Measure-Object -Property Height -Maximum).Maximum }) | Measure-Object -Sum).Sum + ($best.Groups.Count - 1) * $Gap
    $y = $Area.Y + [int][Math]::Floor(($Area.Height - $totalHeight) / 2)
    $rects = New-Object System.Collections.ArrayList
    foreach ($sizes in $rowSizes) {
        $rowHeight = ($sizes | Measure-Object -Property Height -Maximum).Maximum
        $rowWidth = ($sizes | Measure-Object -Property Width -Sum).Sum + ($sizes.Count - 1) * $Gap
        $x = $Area.X + [int][Math]::Floor(($Area.Width - $rowWidth) / 2)
        foreach ($size in $sizes) {
            [void]$rects.Add((New-Object System.Drawing.Rectangle($x, ($y + [int][Math]::Floor(($rowHeight - $size.Height) / 2)), $size.Width, $size.Height)))
            $x += $size.Width + $Gap
        }
        $y += $rowHeight + $Gap
    }
    , $rects.ToArray()
}

function Invoke-ArrangeWindows {
    $script:ArrangeRequestedAt = $null
    Initialize-WindowArrange
    $previous = [ScrcpyMonitor.WindowArrange]::EnterPerMonitor()
    try { Set-WindowArrangement } finally { [ScrcpyMonitor.WindowArrange]::Leave($previous) }
}

function Set-WindowArrangement {
    $isFollowUp = $script:ArrangeFollowUp
    $script:ArrangeFollowUp = $false
    $items = New-Object System.Collections.ArrayList
    foreach ($session in @($script:Sessions.Values | Where-Object { $_.Display -and $_.WindowShown -and $_.ScrcpyPid } | Sort-Object Title)) {
        $handle = [IntPtr]::Zero
        try {
            $process = [System.Diagnostics.Process]::GetProcessById($session.ScrcpyPid)
            try { $handle = $process.MainWindowHandle } finally { $process.Dispose() }
        } catch { continue }
        if ($handle -eq [IntPtr]::Zero -or [ScrcpyMonitor.WindowArrange]::IsIconic($handle) -or [ScrcpyMonitor.WindowArrange]::IsZoomed($handle)) { continue }
        $window = New-Object ScrcpyMonitor.WindowArrange+RECT
        $client = New-Object ScrcpyMonitor.WindowArrange+RECT
        if (-not [ScrcpyMonitor.WindowArrange]::GetWindowRect($handle, [ref]$window) -or -not [ScrcpyMonitor.WindowArrange]::GetClientRect($handle, [ref]$client)) { continue }
        if ($client.Right -le 0 -or $client.Bottom -le 0) { continue }
        $outer = New-Object System.Drawing.Rectangle($window.Left, $window.Top, ($window.Right - $window.Left), ($window.Bottom - $window.Top))
        $monitor = New-Object ScrcpyMonitor.WindowArrange+RECT
        $work = New-Object ScrcpyMonitor.WindowArrange+RECT
        if ([ScrcpyMonitor.WindowArrange]::GetMonitor($handle, [ref]$monitor, [ref]$work) -and $monitor.Left -eq $window.Left -and $monitor.Top -eq $window.Top -and $monitor.Right -eq $window.Right -and $monitor.Bottom -eq $window.Bottom) { continue }
        if (-not $session.NaturalSize) { $session.NaturalSize = [Math]::Max($client.Right, $client.Bottom) }
        $aspect = $client.Right / $client.Bottom
        [void]$items.Add([pscustomobject]@{
            Handle      = $handle
            Aspect      = $aspect
            FrameWidth  = $outer.Width - $client.Right
            FrameHeight = $outer.Height - $client.Bottom
            MaxHeight   = $session.NaturalSize / [Math]::Max(1.0, $aspect)
            Work        = New-Object System.Drawing.Rectangle($work.Left, $work.Top, ($work.Right - $work.Left), ($work.Bottom - $work.Top))
        })
    }
    if (-not $items.Count) { return }
    $area = Get-ArrangeArea
    if (-not $area) { return }
    $script:ArrangeArea = $area
    $rects = Get-WindowLayout $area $items.ToArray()
    if (-not $rects) { return }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $r = $rects[$i]
        [void][ScrcpyMonitor.WindowArrange]::SetWindowPos($items[$i].Handle, [IntPtr]::Zero, $r.X, $r.Y, $r.Width, $r.Height, 0x4214)
    }
    if (-not $isFollowUp -and @($items | Where-Object { $_.Work -ne $area }).Count) {
        $script:ArrangeFollowUp = $true
        $script:ArrangeRequestedAt = Get-Date
    } else {
        Write-Log "Arranged $($items.Count) device window(s)."
    }
}

function Update-Display($Session, $Devices, [ref]$Ready) {
    $now = Get-Date
    if ($Session.Display) {
        if (-not $Session.Display.HasExited) {
            if ($Session.WindowShown) { return }
            if (Test-WindowShown $Session) {
                $Session.WindowShown = $true
                Request-Arrange
                return
            }
            if ($now -ge $Session.NextWake) {
                $Session.NextWake = $now.AddSeconds(10)
                Write-Log "[$($Session.Serial)] No video yet; waking the device screen."
                [void](Invoke-Adb @('-s', $Session.Serial, 'shell', 'case $(dumpsys power) in *mWakefulness=Asleep*|*mWakefulness=Dozing*) input keyevent KEYCODE_POWER;; esac') 3000)
            }
            return
        }

        $exitCode = $Session.Display.ExitCode
        $ranSeconds = ($now - $Session.DisplayStartedAt).TotalSeconds
        $Session.Display.Dispose()
        $Session.Display = $null
        if ($Session.WindowShown) { Request-Arrange }
        $Session.WindowShown = $false
        $Session.NaturalSize = 0

        if ($exitCode -eq 0) {
            Write-Log "[$($Session.Serial)] scrcpy window closed by user; removed from the list."
            Remove-Device $Session -UserClosed
            $script:ClosedByUser = $true
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
    if ($Session.Recording -or $Session.UserClosed -or $script:Standby.ContainsKey($Session.Serial)) { return }
    if ((Get-DiskLevel (Get-RecordFreeSpace)) -eq 'critical') {
        if (((Get-Date) - $script:DiskRefusedAt).TotalSeconds -ge 10) {
            $script:DiskRefusedAt = Get-Date
            Show-Notification "Recording not started: less than 500 MB is free in $RecordDir. Free up space or change the recordings folder." 'Error'
        }
        return
    }
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

    if ($RecordEncoder -eq 'auto' -and -not $Session.SoftwareEncoder) { $Session.SoftwareEncoder = Get-CachedEncoder $Session.Serial $Session.Name }
    $part = '{0}_part{1:D2}.mp4' -f $Session.RecordingBase, ($Session.Parts.Count + 1)
    $arguments = @('-s', $Session.Serial, '--no-window', '--no-playback', '--no-control', "--record=$part", '--record-format=mp4')
    if ($RecordEncoder -ne 'auto') { $arguments += "--video-encoder=$RecordEncoder" }
    elseif ($Session.SoftwareEncoder) { $arguments += "--video-encoder=$($Session.SoftwareEncoder)" }
    if (-not (Test-HasPortArg $RecordArgs)) { $arguments += "--port=$($Session.Port + 2):$($Session.Port + 3)" }
    $arguments += $RecordArgs

    $Session.RecorderLog = Join-Path $script:LogDir ('{0}-record-part{1:D2}.log' -f $Session.SafeSerial, ($Session.Parts.Count + 1))
    Stop-OrphanServers $Session.Serial
    Write-Log "[$($Session.Serial)] Starting recorder: $(ConvertTo-ArgumentString $arguments)"
    $Session.Recorder = Start-ScrcpyProcess $arguments $Session.RecorderLog
    $Session.RecorderStartedAt = Get-Date
    $Session.CodecErrorAt = $null
    $Session.RecorderPart = $part
    [void]$Session.Parts.Add($part)
    if ($Session.CombineMember) {
        $Session.PartStarts[$part] = $Session.RecorderStartedAt
        $Session.PartStartPending = $true
    }
}

function Update-PartStarts {
    foreach ($session in @($script:Sessions.Values | Where-Object { $_.PartStartPending })) {
        $part = $session.RecorderPart
        if (-not $session.CombineMember -or -not $part -or -not $session.PartStarts.ContainsKey($part)) {
            $session.PartStartPending = $false
            continue
        }
        try {
            $file = New-Object System.IO.FileInfo $part
            if ($file.Exists -and $file.Length -gt 0) {
                $session.PartStarts[$part] = Get-Date
                $session.PartStartPending = $false
            }
        } catch {
            $session.PartStartPending = $false
        }
    }
}

function Test-EncoderFailure($Session) {
    if ($RecordEncoder -ne 'auto' -or $Session.SoftwareEncoder) { return $false }
    if (-not $Session.CodecErrorAt) {
        if (((Get-Date) - $Session.RecorderStartedAt).TotalSeconds -gt 60) { return $false }
        try {
            $content = Get-Content -LiteralPath $Session.RecorderLog -Raw -ErrorAction Stop
        } catch {
            return $false
        }
        if (-not ($content -and $content -match 'CodecException')) { return $false }
        $Session.CodecErrorAt = Get-Date
    }
    if (-not $Session.Recorder.HasExited -and ((Get-Date) - $Session.CodecErrorAt).TotalSeconds -lt 5) { return $false }
    return -not (Test-VideoFile $Session.RecorderPart)
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
                Set-CachedEncoder $Session.Serial $Session.Name $encoder
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
                    Set-CachedEncoder $Session.Serial $Session.Name $null
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
        Member   = $Session.CombineMember
        Starts   = $Session.PartStarts
    }
    $Session.CombineMember = $null
    $Session.PartStarts = @{}
    $Session.PartStartPending = $false
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
            Complete-Recording $stop.Title $stop.Base $stop.Parts $stop.Member $stop.Starts
        }
        if ($script:Stops.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 200
    } while ($true)
}

function Complete-Recording([string]$Title, [string]$Base, [string[]]$AllParts, $Member = $null, [hashtable]$PartStarts = $null) {
    $parts = @($AllParts | Where-Object { $_ -and (Test-VideoFile $_) })
    foreach ($part in @($AllParts | Where-Object { $_ -and $parts -notcontains $_ })) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    $segments = @(if ($Member) { Get-CombineSegments $parts $PartStarts })
    if (-not $Base -or $parts.Count -eq 0) {
        Show-Notification "Recording stopped for $Title; nothing was recorded."
        if ($Member) { Complete-CombineMember $Member @() }
        return
    }

    $output = "$Base.mp4"
    if ($parts.Count -eq 1) {
        try {
            Move-Item -LiteralPath $parts[0] -Destination $output
            Add-RecordingHeader $Title $output $(if ($Member) { $Member.Group })
            foreach ($segment in $segments) { $segment.Path = $output }
        } finally {
            if ($Member) { Complete-CombineMember $Member $segments }
        }
        return
    }
    if (-not $script:Ffmpeg) {
        Show-Notification "Recording saved in $($parts.Count) parts next to $output (ffmpeg not found to join them)."
        if ($Member) { Complete-CombineMember $Member $segments }
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

    $merge = [pscustomobject]@{ Process = $null; Steps = $steps; Parts = $parts; Temps = @($temps); Output = $output; ListFile = $listFile; Member = $Member; Segments = $segments; Title = $Title }
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
            Add-RecordingHeader $merge.Title $merge.Output $(if ($merge.Member) { $merge.Member.Group })
            if ($merge.Member) {
                $position = 0.0
                foreach ($segment in $merge.Segments) {
                    $segment.Path = $merge.Output
                    $segment.Position = $position
                    $position += $segment.Duration
                }
                Complete-CombineMember $merge.Member $merge.Segments
            }
        } else {
            Remove-Item -LiteralPath $merge.Output -Force -ErrorAction SilentlyContinue
            Show-Notification "Could not join recording parts (ffmpeg exit code $exitCode); the parts were kept next to $($merge.Output)." 'Warning'
            if ($merge.Member) { Complete-CombineMember $merge.Member $merge.Segments }
        }
    }
}

function Format-Seconds([double]$Value) {
    $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-VideoDuration([string]$Path) {
    $value = 0.0
    if (-not $script:Ffprobe) { return $value }
    $text = (Invoke-Hidden $script:Ffprobe @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $Path) 30000).Trim()
    if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { $value = 0.0 }
    $value
}

function Get-VideoSize([string]$Path) {
    $text = (Invoke-Hidden $script:Ffprobe @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', $Path) 30000).Trim()
    if ($text -match '^(\d+)x(\d+)' -and [int]$Matches[1] -gt 0 -and [int]$Matches[2] -gt 0) { return @([int]$Matches[1], [int]$Matches[2]) }
    @(1080, 1920)
}

function Get-CombineSegments([string[]]$Parts, [hashtable]$PartStarts) {
    foreach ($part in $Parts) {
        $start = if ($PartStarts -and $PartStarts.ContainsKey($part)) { $PartStarts[$part] } else { $null }
        [pscustomobject]@{ Path = $part; Position = 0.0; Duration = (Get-VideoDuration $part); Start = $start }
    }
}

function Start-CombinedRecording($Sessions) {
    $group = [pscustomobject]@{ RequestedAt = Get-Date; Members = New-Object System.Collections.ArrayList; Finished = $false; Area = $script:ArrangeArea }
    $started = New-Object System.Collections.ArrayList
    foreach ($session in @($Sessions | Sort-Object Title)) {
        if ($session.Recording -or $session.Stopping) { continue }
        Start-Recording $session
        if (-not $session.Recording) { continue }
        $member = [pscustomobject]@{ Group = $group; Title = $session.Title; Segments = @(); Open = 1; Done = $false; Natural = $session.NaturalSize }
        [void]$group.Members.Add($member)
        $session.CombineMember = $member
        $session.PartStarts = @{}
        $session.PartStartPending = $false
        [void]$started.Add($session)
    }
    if ($group.Members.Count -ge 2) {
        Show-Notification "Combined recording started for $($group.Members.Count) devices. One video with all screens is saved after they all stop."
        return
    }
    $group.Finished = $true
    foreach ($session in $started) { $session.CombineMember = $null }
    if ($started.Count) { Show-Notification "Record combined needs at least two devices; recording $($started[0].Title) on its own." }
}

function Complete-CombineMember($Member, $Segments) {
    try {
        if ($Member.Done) { return }
        $Member.Segments = @($Member.Segments) + @($Segments | Where-Object { $_ -and $_.Path -and $_.Duration -gt 0 })
        $Member.Open--
        if ($Member.Open -gt 0) { return }
        $Member.Done = $true
        $group = $Member.Group
        if ($group.Finished -or @($group.Members | Where-Object { -not $_.Done }).Count) { return }
        $group.Finished = $true
        if (-not $script:Ffmpeg -or -not $script:Ffprobe) {
            Show-Notification 'Combined recording skipped: ffmpeg was not found. Each device recording was saved.' 'Warning'
            return
        }
        $recorded = @($group.Members | Where-Object { $_.Segments.Count -gt 0 })
        if ($recorded.Count -lt 2) {
            Show-Notification 'Combined recording skipped: fewer than two devices recorded video. Each device recording was saved.'
            return
        }
        Start-Combine $group $recorded
    } catch {
        Write-Log "Combined recording failed: $($_.Exception.Message)"
        Show-Notification 'Could not create the combined recording. Each device recording was saved.' 'Warning'
    }
}

function Join-CombineHandover($Session) {
    foreach ($handover in @($script:CombineHandovers | Where-Object { $_.Session -eq $Session })) {
        $script:CombineHandovers.Remove($handover)
        if ($Session.Recording -and -not $Session.CombineMember -and -not $handover.Member.Group.Finished) {
            $Session.CombineMember = $handover.Member
            $Session.PartStarts = @{}
            $Session.PartStartPending = $false
        } else {
            Complete-CombineMember $handover.Member @()
        }
    }
}

function Update-CombineHandovers([switch]$All) {
    foreach ($handover in @($script:CombineHandovers)) {
        if (-not $All -and ((Get-Date) - $handover.At).TotalSeconds -lt 60) { continue }
        $script:CombineHandovers.Remove($handover)
        Write-Log "[$($handover.Session.Serial)] Recording did not continue over USB; the combined recording keeps the Wi-Fi part only."
        Complete-CombineMember $handover.Member @()
    }
}

function Test-CombineActive {
    if ($script:Combines.Count -or $script:CombineHandovers.Count) { return $true }
    if (@($script:Sessions.Values | Where-Object { $_.CombineMember }).Count) { return $true }
    if (@($script:Stops | Where-Object { $_.Member }).Count) { return $true }
    @($script:Merges | Where-Object { $_.Member }).Count -gt 0
}

function Get-CombineEncoderArgs {
    if (-not $script:CombineEncoderArgs) {
        $list = Invoke-Hidden $script:Ffmpeg @('-hide_banner', '-encoders') 15000
        $encoder = if ($list -match '\slibx264\s') { @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23') }
                   elseif ($list -match '\slibopenh264\s') { @('-c:v', 'libopenh264', '-b:v', '8M') }
                   else { @('-c:v', 'mpeg4', '-q:v', '4') }
        if (-not $list) { return $encoder }
        $script:CombineEncoderArgs = $encoder
    }
    $script:CombineEncoderArgs
}

function New-CombineHeader([string]$Text, [int]$Width, [int]$Height, [string]$Path) {
    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $format = New-Object System.Drawing.StringFormat
        try {
            $graphics.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
            $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
            $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
            $size = [math]::Max(8.0, $Height * 0.55)
            $font = New-Object System.Drawing.Font('Segoe UI', [single]$size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            while ($size -gt 8 -and $graphics.MeasureString($Text, $font).Width -gt $Width - 8) {
                $font.Dispose()
                $size = [math]::Max(8.0, $size - 1)
                $font = New-Object System.Drawing.Font('Segoe UI', [single]$size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            }
            try {
                $graphics.DrawString($Text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(4, 0, ($Width - 8), $Height)), $format)
            } finally { $font.Dispose() }
        } finally {
            $format.Dispose()
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}

function ConvertTo-Even([double]$Value) {
    [int][math]::Max(2, [math]::Round($Value / 2) * 2)
}

function Get-CombineLayout($Sizes, $Naturals, $Area, [int]$Gap = 8) {
    $areaW = 1920
    $areaH = 1080
    if ($Area -and $Area.Width -gt 0 -and $Area.Height -gt 0) { $areaW = $Area.Width; $areaH = $Area.Height }
    $title = [int][math]::Max(16, [math]::Floor($areaH / 36))
    $items = @(for ($n = 0; $n -lt $Sizes.Count; $n++) {
        $width = [double]$Sizes[$n][0]
        $height = [double]$Sizes[$n][1]
        $aspect = $width / $height
        $natural = if ($Naturals -and $n -lt $Naturals.Count -and $Naturals[$n]) { [double]$Naturals[$n] } else { 0 }
        $maxHeight = if ($natural -gt 0) { $natural / [math]::Max(1.0, $aspect) }
                     else { $height * [math]::Min(1.0, [math]::Min([math]::Max(1, $areaW - 96) / $width, [math]::Max(1, $areaH - 96) / $height)) }
        [pscustomobject]@{ Aspect = $aspect; FrameWidth = 0; FrameHeight = $title; MaxHeight = $maxHeight }
    })
    $rects = $null
    foreach ($grow in 1, 2, 4, 8, 16) {
        $rects = Get-WindowLayout (New-Object System.Drawing.Rectangle(0, 0, ($areaW * $grow), ($areaH * $grow))) $items $Gap
        if ($rects) { break }
    }
    if (-not $rects) { $rects = @(for ($n = 0; $n -lt $Sizes.Count; $n++) { New-Object System.Drawing.Rectangle(($n * 66), 0, 58, (50 + $title)) }) }
    $left = ($rects | Measure-Object -Property X -Minimum).Minimum
    $top = ($rects | Measure-Object -Property Y -Minimum).Minimum
    $width = ($rects | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum - $left + 2 * $Gap
    $height = ($rects | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum - $top + 2 * $Gap
    $ratio = 0.0
    for ($n = 0; $n -lt $rects.Count; $n++) { $ratio = [math]::Max($ratio, $Sizes[$n][1] / [math]::Max(1, $rects[$n].Height - $title)) }
    $scale = [math]::Min([math]::Max(1.0, $ratio), [math]::Min(2560.0 / $width, 1440.0 / $height))
    for ($round = 0; $round -lt 8; $round++) {
        $headerH = ConvertTo-Even ($title * $scale)
        $tiles = @(foreach ($r in $rects) {
            New-Object System.Drawing.Rectangle((ConvertTo-Even (($r.X - $left + $Gap) * $scale)), ((ConvertTo-Even (($r.Y - $top + $Gap) * $scale)) + $headerH),
                (ConvertTo-Even ($r.Width * $scale)), (ConvertTo-Even (($r.Height - $title) * $scale)))
        })
        $margin = ConvertTo-Even ($Gap * $scale)
        $canvasW = [int](($tiles | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum + $margin)
        $canvasH = [int](($tiles | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum + $margin)
        if ($canvasW -le 2560 -and $canvasH -le 1440) { break }
        $scale = $scale * [math]::Min(1.0, [math]::Min(2558.0 / $canvasW, 1438.0 / $canvasH))
    }
    [pscustomobject]@{
        Width        = $canvasW
        Height       = $canvasH
        HeaderHeight = $headerH
        Tiles        = $tiles
    }
}

function Start-Combine($Group, $Members) {
    $t0 = $null
    foreach ($member in $Members) {
        foreach ($segment in $member.Segments) {
            if (-not $segment.Start) { $segment.Start = $Group.RequestedAt }
            if (-not $t0 -or $segment.Start -lt $t0) { $t0 = $segment.Start }
        }
    }
    $count = $Members.Count
    $sizes = @(foreach ($member in $Members) { , (Get-VideoSize $member.Segments[0].Path) })
    $layout = Get-CombineLayout $sizes @($Members | ForEach-Object { $_.Natural }) $Group.Area
    $headerH = $layout.HeaderHeight
    $tiles = $layout.Tiles

    $inputs = New-Object System.Collections.Generic.List[string]
    $filters = New-Object System.Collections.Generic.List[string]
    $overlays = New-Object System.Collections.Generic.List[string]
    $headers = New-Object System.Collections.Generic.List[string]
    $stamp = '{0:yyyyMMdd_HHmmss}_{1}' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 8)
    for ($m = 0; $m -lt $count; $m++) {
        $path = Join-Path $script:LogDir "combine-$stamp-header$($m + 1).png"
        try {
            New-CombineHeader $Members[$m].Title $tiles[$m].Width $headerH $path
            $headers.Add($path)
        } catch {
            Write-Log "Could not create the combined recording header for $($Members[$m].Title): $($_.Exception.Message)"
            foreach ($header in $headers) { Remove-Item -LiteralPath $header -Force -ErrorAction SilentlyContinue }
            $headers.Clear()
            break
        }
    }
    $total = 0.0
    $index = 0
    for ($m = 0; $m -lt $count; $m++) {
        $tile = $tiles[$m]
        $fit = "min($($tile.Width)/iw,$($tile.Height)/ih)"
        $chain = "scale=w='max(2,trunc(iw*$fit/2)*2)':h='max(2,trunc(ih*$fit/2)*2)':eval=frame,pad=$($tile.Width):$($tile.Height):(ow-iw)/2:(oh-ih)/2:eval=frame,setsar=1"
        foreach ($segment in $Members[$m].Segments) {
            $offset = [math]::Max(0.0, ($segment.Start - $t0).TotalSeconds)
            $total = [math]::Max($total, $offset + $segment.Duration)
            $inputs.AddRange([string[]]@('-reinit_filter', '0', '-ss', (Format-Seconds $segment.Position), '-t', (Format-Seconds $segment.Duration), '-i', $segment.Path))
            $filters.Add("[${index}:v]setpts=PTS-STARTPTS+$(Format-Seconds $offset)/TB,$chain[v$index]")
            $overlays.Add("[b$index][v$index]overlay=x=$($tile.X):y=$($tile.Y):eof_action=pass[b$($index + 1)]")
            $index++
        }
    }
    $base = "color=c=0x505050:s=$($layout.Width)x$($layout.Height):r=30:d=$(Format-Seconds $total)"
    $headerFilters = New-Object System.Collections.Generic.List[string]
    for ($m = 0; $m -lt $headers.Count; $m++) {
        $inputs.AddRange([string[]]@('-i', $headers[$m]))
        $source = if ($m) { "[h$m]" } else { "$base[h0];[h0]" }
        $target = if ($m -eq $headers.Count - 1) { '[b0]' } else { "[h$($m + 1)]" }
        $headerFilters.Add("$source[$($index + $m):v]overlay=x=$($tiles[$m].X):y=$($tiles[$m].Y - $headerH)$target")
    }
    if (-not $headers.Count) { $headerFilters.Add("$base[b0]") }
    $graph = (@($headerFilters) + $filters + $overlays) -join ';'

    $folder = Join-Path $RecordDir 'Combined'
    [void](New-Item -ItemType Directory -Force -Path $folder)
    $stem = 'Screen_Recording_Combined_{0:yyyyMMdd_HHmmss}' -f $Group.RequestedAt
    $output = Join-Path $folder "$stem.mp4"
    $suffix = 2
    while ((Test-Path -LiteralPath $output) -or @($script:Combines | Where-Object { $_.Output -eq $output }).Count) {
        $output = Join-Path $folder "${stem}_$suffix.mp4"
        $suffix++
    }
    $temp = $output -replace '\.mp4$', '_combining.mp4'
    $arguments = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y') + $inputs + @('-filter_complex', $graph, '-map', "[b$index]", '-an') +
                 (Get-CombineEncoderArgs) + @('-pix_fmt', 'yuv420p', '-r', '30', '-movflags', '+faststart', '-t', (Format-Seconds $total), $temp)
    $argumentString = ConvertTo-ArgumentString $arguments
    if ($argumentString.Length -gt 30000) {
        foreach ($header in $headers) { Remove-Item -LiteralPath $header -Force -ErrorAction SilentlyContinue }
        Show-Notification 'Combined recording skipped: too many recording parts. Each device recording was saved.' 'Warning'
        return
    }

    $log = Join-Path $script:LogDir ('combine-{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    $psi = New-HiddenStartInfo $script:Ffmpeg $argumentString
    $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (($log -replace '\\', '/') -replace ':', '\:') + ':level=16'
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        foreach ($header in $headers) { Remove-Item -LiteralPath $header -Force -ErrorAction SilentlyContinue }
        throw
    }
    try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $sources = @($Members | ForEach-Object { $_.Segments } | ForEach-Object { $_.Path } | Select-Object -Unique)
    [void]$script:Combines.Add([pscustomobject]@{ Process = $process; Output = $output; Temp = $temp; Log = $log; Headers = @($headers); Sources = $sources; Size = -1L; ProgressAt = Get-Date })
    Write-Log "Combining $count device recordings ($index part(s), $(Format-Seconds $total)s) into $output (log: $log)"
    Show-Notification "Combining $count device recordings into one video..."
}

function Update-Combines([int]$TimeoutMs = 0) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    foreach ($combine in @($script:Combines)) {
        $wait = [int][math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $combine.Process.WaitForExit($wait)) {
            $size = 0L
            try { $file = New-Object System.IO.FileInfo $combine.Temp; if ($file.Exists) { $size = $file.Length } } catch { }
            if ($size -ne $combine.Size) {
                $combine.Size = $size
                $combine.ProgressAt = Get-Date
                continue
            }
            if (((Get-Date) - $combine.ProgressAt).TotalMinutes -lt 5) { continue }
            Write-Log "Combined recording made no progress for 5 minutes; stopping ffmpeg."
            Stop-ProcessTree $combine.Process.Id
            [void]$combine.Process.WaitForExit(5000)
        }
        $exitCode = if ($combine.Process.HasExited) { $combine.Process.ExitCode } else { -1 }
        $combine.Process.Dispose()
        $script:Combines.Remove($combine)
        foreach ($header in $combine.Headers) { Remove-Item -LiteralPath $header -Force -ErrorAction SilentlyContinue }
        if ($exitCode -eq 0 -and (Test-VideoFile $combine.Temp)) {
            try {
                Move-Item -LiteralPath $combine.Temp -Destination $combine.Output -ErrorAction Stop
                Remove-Item -LiteralPath $combine.Log -Force -ErrorAction SilentlyContinue
                Show-Notification "Combined recording saved: $($combine.Output)"
            } catch {
                Show-Notification "Combined recording saved as $($combine.Temp) (could not rename it: $($_.Exception.Message))." 'Warning'
            }
        } else {
            Remove-Item -LiteralPath $combine.Temp -Force -ErrorAction SilentlyContinue
            Show-Notification "Could not create the combined recording (ffmpeg exit code $exitCode; log: $($combine.Log)). Each device recording was saved." 'Warning'
        }
    }
}

function Stop-Combines {
    foreach ($combine in @($script:Combines)) {
        try {
            if (-not $combine.Process.HasExited) {
                Stop-ProcessTree $combine.Process.Id
                [void]$combine.Process.WaitForExit(5000)
            }
            $combine.Process.Dispose()
        } catch { }
        $script:Combines.Remove($combine)
        Remove-Item -LiteralPath $combine.Temp -Force -ErrorAction SilentlyContinue
        foreach ($header in $combine.Headers) { Remove-Item -LiteralPath $header -Force -ErrorAction SilentlyContinue }
        Write-Log "Combined recording $($combine.Output) cancelled at exit; each device recording was saved."
        Show-Notification 'The combined recording was not finished before exit and was cancelled. Each device recording was saved.' 'Warning'
    }
}

function Add-RecordingHeader([string]$Title, [string]$Path, $Group = $null) {
    if (-not $Title) {
        Show-Notification "Screen recording saved: $Path"
        return
    }
    if (-not $script:Ffmpeg -or -not $script:Ffprobe) {
        Show-Notification "Recording saved: $Path"
        return
    }
    [void]$script:Labels.Add([pscustomobject]@{ Title = $Title; Path = $Path; Group = $Group; Process = $null; Temp = ($Path -replace '\.mp4$', '_labeling.mp4'); Header = $null; Size = -1L; ProgressAt = Get-Date })
}

function Test-LabelReady($Label) {
    if ($Label.Group -and -not $Label.Group.Finished) { return $false }
    -not @($script:Combines | Where-Object { $_.Sources -contains $Label.Path }).Count
}

function Get-FpsPassthroughArgs {
    if (-not $script:FpsPassthroughArgs) {
        $text = Invoke-Hidden $script:Ffmpeg @('-version') 15000
        $major = if ($text -match 'ffmpeg version n?(\d+)\.(\d+)') { [int]$Matches[1] } else { -1 }
        $old = $major -ge 0 -and ($major -lt 5 -or ($major -eq 5 -and [int]$Matches[2] -lt 1))
        $fpsArgs = if ($old) { @('-vsync', 'passthrough') } else { @('-fps_mode', 'passthrough') }
        if ($major -lt 0 -or $major -ge 4) { $fpsArgs += @('-enc_time_base', '1:60000') }
        if (-not $text) { return $fpsArgs }
        $script:FpsPassthroughArgs = $fpsArgs
    }
    $script:FpsPassthroughArgs
}

function Start-Label($Label) {
    $size = Get-VideoSize $Label.Path
    $width = [int][math]::Max(16, [math]::Ceiling($size[0] / 2) * 2)
    $height = [int][math]::Max(16, [math]::Ceiling($size[1] / 2) * 2)
    $headerH = [int][math]::Max(16, [math]::Floor($height / 40) * 2)
    $Label.Header = Join-Path $script:LogDir ('label-{0}.png' -f [guid]::NewGuid().ToString('N'))
    New-CombineHeader $Label.Title $width $headerH $Label.Header
    $fit = "min($width/iw,$height/ih)"
    $graph = "[0:v]scale=w='max(2,trunc(iw*$fit/2)*2)':h='max(2,trunc(ih*$fit/2)*2)':eval=frame,pad=${width}:$($height + $headerH):(ow-iw)/2:$headerH+($height-ih)/2:eval=frame,setsar=1[v];[v][1:v]overlay=x=0:y=0[out]"
    $arguments = @('-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-reinit_filter', '0', '-i', $Label.Path, '-i', $Label.Header,
                   '-filter_complex', $graph, '-map', '[out]', '-map', '0:a?', '-c:a', 'copy') +
                 (Get-CombineEncoderArgs) + @('-bf', '0', '-pix_fmt', 'yuv420p') + (Get-FpsPassthroughArgs) + @('-movflags', '+faststart', $Label.Temp)
    $Label.Process = [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:Ffmpeg (ConvertTo-ArgumentString $arguments)))
    try { $Label.Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $Label.ProgressAt = Get-Date
    Write-Log "Adding the device name header to $($Label.Path)"
}

function Remove-TempFile([string]$Path) {
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $Path); $i++) {
        if ($i) { Start-Sleep -Milliseconds 200 }
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Complete-Label($Label, [int]$ExitCode) {
    $script:Labels.Remove($Label)
    if ($Label.Process) {
        try {
            if (-not $Label.Process.HasExited) {
                Stop-ProcessTree $Label.Process.Id
                [void]$Label.Process.WaitForExit(5000)
            }
            $Label.Process.Dispose()
        } catch { }
        $Label.Process = $null
    }
    if ($Label.Header) { Remove-Item -LiteralPath $Label.Header -Force -ErrorAction SilentlyContinue }
    $labeled = $false
    if ($ExitCode -eq 0 -and (Test-VideoFile $Label.Temp)) {
        try {
            [System.IO.File]::Replace($Label.Temp, $Label.Path, [NullString]::Value)
            $labeled = $true
        } catch {
            Write-Log "Could not replace $($Label.Path) with the version that has the device name header: $($_.Exception.Message)"
        }
    } else {
        Write-Log "Could not add the device name header to $($Label.Path) (ffmpeg exit code $ExitCode); the recording was kept without it."
    }
    Remove-TempFile $Label.Temp
    if ($labeled) {
        Show-Notification "Recording saved: $($Label.Path)"
    } else {
        Show-Notification "Recording saved without the device name header: $($Label.Path)"
    }
}

function Update-Labels([int]$TimeoutMs = 0, [switch]$Force) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($script:Labels.Count) {
        $label = @($script:Labels | Where-Object { $_.Process })[0]
        if (-not $label) {
            $label = @($script:Labels | Where-Object { $Force -or (Test-LabelReady $_) })[0]
            if (-not $label) { return }
            try {
                Start-Label $label
            } catch {
                Write-Log "Could not start adding the device name header to $($label.Path): $($_.Exception.Message)"
                Complete-Label $label -1
                continue
            }
        }
        $wait = [int][math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $label.Process.WaitForExit($wait)) {
            $size = 0L
            try { $file = New-Object System.IO.FileInfo $label.Temp; if ($file.Exists) { $size = $file.Length } } catch { }
            if ($size -ne $label.Size) {
                $label.Size = $size
                $label.ProgressAt = Get-Date
                return
            }
            if (((Get-Date) - $label.ProgressAt).TotalMinutes -lt 5) { return }
            Write-Log "Adding the device name header to $($label.Path) made no progress for 5 minutes; stopping ffmpeg."
            Stop-ProcessTree $label.Process.Id
            [void]$label.Process.WaitForExit(5000)
        }
        $exitCode = if ($label.Process.HasExited) { $label.Process.ExitCode } else { -1 }
        Complete-Label $label $exitCode
    }
}

function Stop-Labels {
    foreach ($label in @($script:Labels)) {
        $script:Labels.Remove($label)
        try {
            if ($label.Process) {
                if (-not $label.Process.HasExited) {
                    Stop-ProcessTree $label.Process.Id
                    [void]$label.Process.WaitForExit(5000)
                }
                $label.Process.Dispose()
            }
        } catch { }
        Remove-TempFile $label.Temp
        if ($label.Header) { Remove-Item -LiteralPath $label.Header -Force -ErrorAction SilentlyContinue }
        Write-Log "Device name header for $($label.Path) cancelled at exit; the recording was kept without it."
        Show-Notification "Recording saved without the device name header: $($label.Path)"
    }
}

function Get-TargetSessions([string[]]$Serials) {
    $all = @($script:Sessions.Values | Where-Object { -not $_.UserClosed -and -not $script:Standby.ContainsKey($_.Serial) })
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
            'StartLogs' { foreach ($session in (Get-TargetSessions $serials)) { Start-DeviceLog $session } }
            'StopLogs' { Stop-AllLogs $serials }
            'ShowPanel' {
                if ($script:Panel) { Show-Panel }
                else { Show-Notification 'scrcpy monitor is already running (see the tray icon).' }
            }
            'OpenWindows' { $script:OpenWindowsRequested = $true }
            'Snip' { Request-Snip 'rect' $null 100 }
            'Exit' { Stop-Monitor; return }
        }
    }
}

function Start-AdbJob([string[]]$Arguments) {
    $psi = New-HiddenStartInfo $script:Adb (ConvertTo-ArgumentString $Arguments)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    @{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync(); StartedAt = Get-Date }
}

function Complete-AdbJob($Job, [int]$TimeoutSeconds = 20) {
    if (-not $Job.Process.HasExited) {
        if (((Get-Date) - $Job.StartedAt).TotalSeconds -lt $TimeoutSeconds) { return $null }
        try { $Job.Process.Kill(); [void]$Job.Process.WaitForExit(2000) } catch { }
    }
    $text = ''
    if ($Job.Output.Wait(1000)) { $text += $Job.Output.Result }
    if ($Job.Error.Wait(1000)) { $text += $Job.Error.Result }
    Close-RedirectedProcess $Job.Process
    $text.Trim()
}

function Stop-AdbJobs {
    foreach ($job in @(@($script:Connects) + @($script:Discovery) | Where-Object { $_ })) {
        try { if (-not $job.Process.HasExited) { $job.Process.Kill() } } catch { }
        Close-RedirectedProcess $job.Process
    }
    $script:Connects.Clear()
    $script:Discovery = $null
    Stop-Probe
}

function Start-Connect([string]$Address, [bool]$Manual) {
    if (@($script:Connects | Where-Object { $_.Address -eq $Address }).Count) { return }
    try {
        $job = Start-AdbJob @('connect', $Address)
    } catch {
        Write-Log "adb connect $Address failed: $($_.Exception.Message)"
        return
    }
    $job.Address = $Address
    $job.Manual = $Manual
    [void]$script:Connects.Add($job)
}

function Update-Connects($Devices) {
    foreach ($job in @($script:Connects)) {
        $output = Complete-AdbJob $job
        if ($null -eq $output) { continue }
        $script:Connects.Remove($job)
        Write-Log "adb connect $($job.Address): $output"
        $connected = $output -match '^(already )?connected to '
        if ($connected -and -not $job.Manual -and $output -notmatch '^already') {
            $usb = @($Devices.Keys | Where-Object { $Devices[$_] -eq 'device' -and (Get-ConnectionType $_) -eq 'USB' -and -not $script:MovedUsb.ContainsKey($_) -and -not ($script:Sessions.ContainsKey($_) -and $script:Sessions[$_].UserClosed) -and -not $script:ClosedSerials.ContainsKey($_) })
            if ($usb.Count -and $usb -contains (Get-DeviceProp $job.Address 'ro.serialno')) {
                Write-Log "$($job.Address) is a device already connected over USB; disconnecting the Wi-Fi connection."
                [void](Invoke-Adb @('disconnect', $job.Address) 5000)
                $Devices.Remove($job.Address)
                Remove-KnownWifi $job.Address
                $script:DiscoveryRetry[$job.Address] = (Get-Date).AddMinutes(10)
                continue
            }
        }
        if (-not $job.Manual) { continue }
        $moving = @($script:Sessions.Values | Where-Object { $_.MovedTo -eq 'Wi-Fi' -and $_.MoveAddress -eq $job.Address }) | Select-Object -First 1
        if ($moving) {
            if (-not $connected) { Undo-Move $moving "adb connect failed ($output)" }
            continue
        }
        if ($connected) {
            Add-ScanPort ([int]($job.Address -replace '^.*:', ''))
            Show-Notification "Connected to $($job.Address)."
        }
        else { [void]$script:ConnectFailures.Add(@{ Address = $job.Address; Output = $output }) }
    }
}

function Get-ConnectFailureReason([string]$Address, [string]$Output) {
    $ip = $Address -replace ':\d+$', ''
    $port = $Address -replace '^.*:', ''
    if ($Output -match '10061|refused') {
        return "The device at $ip answered, but port $port is not open for ADB. Check the port number and that ADB over Wi-Fi is turned on for this port on the device (for example adb tcpip $port)."
    }
    if ($Output -match '11001|resolve|no such host|not known') { return "The address $ip could not be found. Check the IP address." }
    if ($Output -match 'authenticat|unauthorized') { return 'Unlock the device and accept the "Allow debugging" prompt, then try again.' }
    if (-not $Output -or $Output -match '10060|10065|10051|timed out|did not properly respond|unreachable|failed to connect') {
        return "No device answered at $Address. Check that the IP address and port are correct, the device is turned on and on the same network as this PC, and ADB over Wi-Fi is turned on."
    }
    $Output
}

function Show-ConnectFailures {
    if ($script:ConnectPrompting -or -not $script:ConnectFailures.Count) { return }
    $failure = $script:ConnectFailures[0]
    $script:ConnectFailures.RemoveAt(0)
    $script:ConnectPrompting = $true
    try {
        $reason = Get-ConnectFailureReason $failure.Address $failure.Output
        $answer = Show-Message "Could not connect to $($failure.Address).`n`n$reason`n`nTry again?" 'RetryCancel' 'Warning'
        if ($answer -eq [System.Windows.Forms.DialogResult]::Retry) {
            Show-ConnectDialog ($failure.Address -replace ':\d+$', '') ($failure.Address -replace '^.*:', '')
        }
    } finally {
        $script:ConnectPrompting = $false
    }
}

function Update-Discovery($Devices) {
    if ($NoDiscovery -or $Serial.Count) { return }
    $now = Get-Date
    if ($script:Discovery) {
        $output = Complete-AdbJob $script:Discovery
        if ($null -ne $output) {
            $script:Discovery = $null
            foreach ($line in ($output -split "`r?`n")) {
                if ($line -notmatch '^\s*(\S+)\s+_adb\._tcp\.?\s+(\S+:\d+)\s*$') { continue }
                $name = $Matches[1]
                $address = $Matches[2]
                [void]$script:ScanFound.Add($address)
                if (@($Devices.Keys | Where-Object { $name -eq "adb-$_" }).Count) { continue }
                Connect-Found $address $name $Devices $now
            }
        }
    }
    if ($script:Probe) {
        $open = Complete-Probe
        if ($null -ne $open) {
            foreach ($address in $open) {
                [void]$script:ScanFound.Add($address)
                Connect-Found $address 'port scan' $Devices $now
            }
        }
    }
    if ($script:Discovery -or $script:Probe) { return }
    if ($script:Scanning) {
        $script:Scanning = $false
        $connected = @($Devices.Keys | Where-Object { $Devices[$_] -eq 'device' } | ForEach-Object { Get-ConnectionType $_ })
        $script:DiscoveryStatus = "Last scan $($now.ToString('HH:mm:ss')): $(@($connected | Where-Object { $_ -eq 'Wi-Fi' }).Count) Wi-Fi, $(@($connected | Where-Object { $_ -eq 'USB' }).Count) USB"
    }
    if ($now -lt $script:NextDiscovery) { return }
    $script:NextDiscovery = $now.AddSeconds(15)
    $script:ScanFound.Clear()
    foreach ($address in @($script:KnownWifi)) { Connect-Found $address 'remembered' $Devices $now }
    try {
        $script:Discovery = Start-AdbJob @('mdns', 'services')
    } catch {
        Write-Log "adb mdns services failed: $($_.Exception.Message)"
    }
    if ($script:ProbeRequested) {
        $script:ProbeRequested = $false
        try { Start-Probe } catch { Write-Log "Wi-Fi port scan failed: $($_.Exception.Message)" }
    }
    if ($script:Discovery -or $script:Probe) {
        $script:Scanning = $true
        if ($script:Probe) { $script:DiscoveryStatus = 'Scanning for devices...' }
    } else {
        $script:DiscoveryStatus = 'Wi-Fi scan: unavailable'
    }
}

function Connect-Found([string]$Address, [string]$Source, $Devices, [datetime]$Now) {
    if ($script:Sessions.ContainsKey($Address)) { return }
    $state = $Devices[$Address]
    if ($state -and $state -ne 'offline') { return }
    if ($script:DiscoveryRetry.ContainsKey($Address) -and $Now -lt $script:DiscoveryRetry[$Address]) { return }
    $script:DiscoveryRetry[$Address] = $Now.AddSeconds(60)
    if ($state) {
        Write-Log "Wi-Fi device $Address is offline ($Source); reconnecting."
        [void](Invoke-Adb @('disconnect', $Address) 5000)
        $Devices.Remove($Address)
    } else {
        Write-Log "Found Wi-Fi device $Address ($Source); connecting."
    }
    Start-Connect $Address $false
}

function Get-ProbeHosts {
    $hosts = New-Object System.Collections.Generic.HashSet[string]
    $own = New-Object System.Collections.Generic.HashSet[string]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -in @('Loopback', 'Tunnel')) { continue }
        $properties = $nic.GetIPProperties()
        if (-not @($properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }).Count) { continue }
        foreach ($unicast in $properties.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -ne 'InterNetwork' -or $unicast.Address.ToString() -like '169.254.*') { continue }
            [void]$own.Add($unicast.Address.ToString())
            $prefix = $unicast.PrefixLength
            if ($prefix -lt 22 -or $prefix -gt 30) { $prefix = 24 }
            $bytes = $unicast.Address.GetAddressBytes(); [array]::Reverse($bytes)
            $ip = [BitConverter]::ToUInt32($bytes, 0)
            $size = [uint32][math]::Pow(2, 32 - $prefix)
            $network = $ip - ($ip % $size)
            for ($i = 1; $i -lt $size - 1; $i++) {
                $hostBytes = [BitConverter]::GetBytes([uint32]($network + $i)); [array]::Reverse($hostBytes)
                [void]$hosts.Add(([System.Net.IPAddress]$hostBytes).ToString())
            }
        }
    }
    @($hosts | Where-Object { -not $own.Contains($_) })
}

function Get-ScanPorts {
    @(@(5555, 5037) + @($script:ScanPorts) + @($script:KnownWifi | ForEach-Object { [int]($_ -replace '^.*:', '') }) | Select-Object -Unique)
}

function Read-ScanPorts {
    $list = New-Object System.Collections.ArrayList
    try {
        $json = Get-Content -LiteralPath $script:ScanPortsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($port in @($json)) {
            $value = 0
            if ([int]::TryParse([string]$port, [ref]$value) -and $value -ge 1 -and $value -le 65535 -and -not $list.Contains($value)) { [void]$list.Add($value) }
        }
    } catch { }
    , $list
}

function Add-ScanPort([int]$Port) {
    if ($Port -in @(5555, 5037) -or $script:ScanPorts.Contains($Port)) { return }
    [void]$script:ScanPorts.Add($Port)
    Write-Log "Adding port $Port to the Wi-Fi scan."
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $script:ScanPortsPath))
        ConvertTo-Json -InputObject @($script:ScanPorts) | Set-Content -LiteralPath $script:ScanPortsPath -Encoding UTF8
    } catch { Write-Log "Could not save $($script:ScanPortsPath): $($_.Exception.Message)" }
}

function Start-Probe {
    $targets = New-Object System.Collections.Generic.HashSet[string]
    $ports = Get-ScanPorts
    foreach ($ip in (Get-ProbeHosts)) { foreach ($port in $ports) { [void]$targets.Add("${ip}:$port") } }
    foreach ($address in $script:KnownWifi) { if ($address -match '^\d+\.\d+\.\d+\.\d+:\d+$') { [void]$targets.Add($address) } }
    $probes = New-Object System.Collections.ArrayList
    foreach ($address in $targets) {
        $ip, $port = $address -split ':'
        $client = New-Object System.Net.Sockets.TcpClient
        try { [void]$probes.Add(@{ Address = $address; Client = $client; Task = $client.ConnectAsync([System.Net.IPAddress]::Parse($ip), [int]$port) }) }
        catch { $client.Close() }
    }
    Write-Log "Scanning $($probes.Count) address(es) on port(s) $($ports -join ', ')."
    $script:Probe = @{ Probes = $probes; StartedAt = Get-Date }
}

function Complete-Probe {
    if (((Get-Date) - $script:Probe.StartedAt).TotalSeconds -lt 1.5) { return $null }
    $probes = $script:Probe.Probes
    $open = @($probes | Where-Object { $_.Task.Status -eq 'RanToCompletion' -and $_.Client.Connected } | ForEach-Object { $_.Address })
    Stop-Probe
    $open
}

function Stop-Probe {
    if (-not $script:Probe) { return }
    foreach ($probe in $script:Probe.Probes) { try { $probe.Client.Close() } catch { } }
    $script:Probe = $null
}

function Read-KnownWifi {
    $list = New-Object System.Collections.ArrayList
    try {
        $json = Get-Content -LiteralPath $script:KnownWifiPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($address in @($json)) {
            if ([string]$address -match '^\S+:\d+$' -and -not $list.Contains([string]$address)) { [void]$list.Add([string]$address) }
        }
    } catch { }
    , $list
}

function Update-KnownWifi($Devices) {
    $added = @($Devices.Keys | Where-Object { $Devices[$_] -eq 'device' -and $_ -match '^\d+\.\d+\.\d+\.\d+:\d+$' -and -not $script:KnownWifi.Contains($_) })
    foreach ($address in $added) { Add-KnownWifi $address }
}

function Add-KnownWifi([string]$Address) {
    if (-not $Address -or $script:KnownWifi.Contains($Address)) { return }
    [void]$script:KnownWifi.Add($Address)
    Write-Log "Remembering Wi-Fi device $Address."
    Save-KnownWifi
}

function Remove-KnownWifi([string]$Address) {
    if (-not $script:KnownWifi.Contains($Address)) { return }
    $script:KnownWifi.Remove($Address)
    Write-Log "Forgetting Wi-Fi device $Address."
    Save-KnownWifi
}

function Save-KnownWifi {
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $script:KnownWifiPath))
        ConvertTo-Json -InputObject @($script:KnownWifi) | Set-Content -LiteralPath $script:KnownWifiPath -Encoding UTF8
    } catch { Write-Log "Could not save $($script:KnownWifiPath): $($_.Exception.Message)" }
}

function Start-Scan {
    if ($NoDiscovery -or $Serial.Count -or $script:Discovery -or $script:Probe) { return }
    $script:DiscoveryRetry.Clear()
    $script:NextDiscovery = Get-Date
    $script:ProbeRequested = $true
    $script:DiscoveryStatus = 'Scanning for devices...'
    Write-Log 'Device scan requested.'
    Request-Tick
}

function Invoke-Tick {
    Invoke-Requests
    if ($script:Exiting) { return }
    Update-Merges
    Update-Combines
    Update-Labels
    Update-CombineHandovers

    $now = Get-Date
    $devices = Get-AdbDevices
    $script:RemovedSerials.Clear()
    Update-Connects $devices
    Update-KnownWifi $devices
    Update-Discovery $devices
    Update-Moves $devices
    Update-UsbPriority $devices
    foreach ($address in @($script:DelayedConnects.Keys)) {
        if ($now -lt $script:DelayedConnects[$address]) { continue }
        $script:DelayedConnects.Remove($address)
        Connect-WifiDevice $address
    }
    $targets = if ($Serial.Count) { $Serial } else { @($devices.Keys | Where-Object { $devices[$_] -match '^(device|unauthorized|authorizing)$' }) + @($script:Sessions.Keys) | Select-Object -Unique }
    $targets = @($targets | Where-Object { -not (Test-MovedAway $_ $devices) })
    foreach ($closedSerial in @($script:ClosedSerials.Keys)) {
        if ($devices[$closedSerial] -eq 'device') { $script:ClosedSerials[$closedSerial] = $true }
        elseif ($script:ClosedSerials[$closedSerial] -and -not $devices.ContainsKey($closedSerial)) {
            $script:ClosedSerials.Remove($closedSerial)
            Write-Log "[$closedSerial] Closed device disconnected; it is shown again when it reconnects."
        }
    }

    foreach ($deviceSerial in $targets) {
        if ($script:RemovedSerials.Contains($deviceSerial) -or $script:ClosedSerials.ContainsKey($deviceSerial)) { continue }
        $session = if ($script:Sessions.ContainsKey($deviceSerial)) { $script:Sessions[$deviceSerial] } else { New-Session $deviceSerial $devices[$deviceSerial] }
        if ($session.PendingAction -and -not $session.Stopping) { Invoke-PendingAction $session }
        if ($session.UserClosed) { continue }

        $state = if ($devices.ContainsKey($deviceSerial)) { $devices[$deviceSerial] } else { 'missing' }
        if ($state -ne $session.LastState) {
            Write-Log "[$deviceSerial] adb state: $state"
            if ($state -eq 'device') {
                $script:WifiSerials.Remove($deviceSerial)
                $session.RestartingAt = $null
                $session.PoweringOff = $false
            }
            $session.LastState = $state
        }
        if ($state -eq 'device') { $session.MissingSince = $null } elseif (-not $session.MissingSince) { $session.MissingSince = $now }
        if ($state -notin @('missing', 'offline')) { $session.GoneSince = $null } elseif (-not $session.GoneSince) { $session.GoneSince = $now }
        if ($state -ne 'device') { $session.BootedAt = $null }
        if ($script:Standby.ContainsKey($deviceSerial)) { Stop-PowerWatch $session } else { Update-PowerWatch $session $state $now }
        if ($state -ne 'device' -and (Test-DeviceGone $session $now)) {
            $reason = if ($session.PoweringOff) { 'was turned off' } elseif ($session.RestartingAt) { 'did not come back after restarting' } else { 'was disconnected' }
            Write-Log "[$deviceSerial] Device $reason; removed from the list."
            Remove-Device $session
            if ($session.Name) { Show-Notification "$($session.Title) $reason and was removed from the list." }
            continue
        }
        if ($session.Connector -and $session.Connector.HasExited) {
            $session.Connector.Dispose()
            $session.Connector = $null
            $session.NextConnect = $now.AddSeconds(5)
        }
        if ($state -ne 'device' -and -not $session.Connector -and $deviceSerial -match '^[^\s:]+:\d+$' -and $now -ge $session.NextConnect) {
            if ($state -eq 'offline') { [void](Invoke-Adb @('disconnect', $deviceSerial) 5000) }
            $session.Connector = [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:Adb (ConvertTo-ArgumentString @('connect', $deviceSerial))))
        }
        if ($script:Standby.ContainsKey($deviceSerial)) {
            if (-not $session.Name -and $state -eq 'device') { [void](Test-DeviceReady $session $devices) }
            if ($session.RecordPending) {
                $active = $script:Sessions[$script:Standby[$deviceSerial]]
                if ($active -and $active.Recording) {
                    $session.RecordPending = $false
                    Write-Log "[$deviceSerial] Recording continues over $(Get-ConnectionType $script:Standby[$deviceSerial])."
                }
            }
            if ($session.Display) { Write-Log "[$deviceSerial] Standby: the device is mirrored over $(Get-ConnectionType $script:Standby[$deviceSerial])." }
            Stop-Display $session
            continue
        }
        if ($session.RecordPending -and $state -eq 'device') {
            $session.RecordPending = $false
            Start-Recording $session
            Join-CombineHandover $session
        }

        $ready = $null
        Update-Display $session $devices ([ref]$ready)
        if (-not $session.UserClosed) { Update-Recorder $session $devices ([ref]$ready) }
    }

    $tracked = @($script:Sessions.Values)
    $monitored = @($tracked | Where-Object { -not $_.Disconnected -and $_.Name -and -not $script:Standby.ContainsKey($_.Serial) })
    if ($script:OpenWindowsRequested) {
        $script:OpenWindowsRequested = $false
        $reopened = $script:ClosedSerials.Count
        if ($reopened) {
            $script:ClosedSerials.Clear()
            $script:ClosedByUser = $false
            Request-Tick
        }
        if ($script:Panel) { Show-Panel }
        elseif (-not $reopened) { Show-Notification 'scrcpy monitor is already running. Right-click the tray icon for recording and settings.' }
    }
    $opened = @($monitored | Where-Object { -not $_.UserClosed })
    if ($opened.Count) { $script:ClosedByUser = $false }
    if (-not ($script:Panel -and $script:Panel.Visible) -and $script:ClosedByUser -and -not $opened.Count -and -not ($tracked | Where-Object { $_.MovedTo }) -and -not (Test-CombineActive) -and -not $script:Labels.Count -and -not $script:ScreenRec) {
        Write-Log 'All scrcpy windows were closed.'
        Stop-Monitor
        return
    }
    Update-DeviceLogs
    Update-Arrange
    Update-TrayText
}

function Update-TrayText {
    if (-not $script:Tray) { return }
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $logging = @($script:Sessions.Values | Where-Object { $_.LogCapture }).Count
    $screen = $script:ScreenRec -and $script:ScreenRec.Recording
    $text = if ($recording -and $screen) { "Scrcpy Monitor - recording $recording device(s) and the screen" }
            elseif ($recording) { "Scrcpy Monitor - recording $recording device(s)" }
            elseif ($screen) { 'Scrcpy Monitor - recording the screen' }
            else { 'Scrcpy Monitor' }
    if ($logging) { $text += $(if ($text -eq 'Scrcpy Monitor') { " - logging $logging device(s)" } else { ", logging $logging" }) }
    $script:Tray.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
}

function Update-TrayMenu {
    $menu = $script:Tray.ContextMenuStrip
    $menu.Items.Clear()

    if ($script:Panel) {
        $showPanel = $menu.Items.Add('Show control panel')
        $showPanel.Font = New-Object System.Drawing.Font($showPanel.Font, [System.Drawing.FontStyle]::Bold)
        $showPanel.add_Click({ Invoke-Safely {
            if ($script:Panel.IsHandleCreated) { [void]$script:Panel.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Invoke-Safely { Show-Panel } }) }
            else { Show-Panel }
        } })
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }

    $sessions = @($script:Sessions.Values | Where-Object { -not $_.UserClosed } | Sort-Object Title)
    $closed = @($script:Sessions.Values | Where-Object { $_.UserClosed } | Sort-Object Title)
    if ($sessions.Count -eq 0 -and $closed.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem 'No device'
        $empty.Enabled = $false
        [void]$menu.Items.Add($empty)
    }
    foreach ($session in $sessions) {
        $label = "$($session.Title) - $($session.Connection)"
        if ($script:Standby.ContainsKey($session.Serial)) {
            $label += '  [standby]'
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
            if ($session.Connection -eq 'Wi-Fi') {
                $disconnect = New-Object System.Windows.Forms.ToolStripMenuItem 'Disconnect'
                $disconnect.Tag = $session.Serial
                $disconnect.add_Click({ param($sender, $e) Invoke-Safely { Disconnect-Device @($sender.Tag) } })
                [void]$item.DropDownItems.Add($disconnect)
            } else { $item.Enabled = $false }
            [void]$menu.Items.Add($item)
            continue
        }
        if ($session.Recording) { $label += '  [REC]' }
        if ($session.LogCapture) { $label += '  [LOG]' }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
        $toggle = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($session.Recording) { 'Stop recording' } else { 'Start recording' })
        $toggle.Tag = $session.Serial
        $toggle.add_Click({
            param($sender, $e)
            Invoke-Safely {
                $target = $script:Sessions[$sender.Tag]
                if ($target.Recording) { Stop-Recording $target } elseif (Confirm-RecordSpace) { Start-Recording $target }
                Update-TrayText
            }
        })
        [void]$item.DropDownItems.Add($toggle)
        $logs = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($session.LogCapture) { 'Stop device logs' } else { 'Start device logs' })
        $logs.Tag = $session.Serial
        $logs.add_Click({ param($sender, $e) Invoke-Safely { Switch-DeviceLog @($script:Sessions[$sender.Tag]); Update-TrayText } })
        [void]$item.DropDownItems.Add($logs)
        if ($session.LogCapture) {
            $openDeviceLog = New-Object System.Windows.Forms.ToolStripMenuItem 'Open device log'
            $openDeviceLog.Tag = $session.Serial
            $openDeviceLog.add_Click({ param($sender, $e) Invoke-Safely { Open-DeviceLog @($script:Sessions[$sender.Tag]) } })
            [void]$item.DropDownItems.Add($openDeviceLog)
        }
        if ($session.Connection -in @('Wi-Fi', 'USB')) {
            $switch = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($session.Connection -eq 'Wi-Fi') { 'Switch to USB' } else { 'Switch to Wi-Fi' })
            $switch.Tag = $session.Serial
            $switch.Enabled = $session.LastState -eq 'device'
            $switch.add_Click({ param($sender, $e) Invoke-Safely { Switch-Connection @($sender.Tag) } })
            [void]$item.DropDownItems.Add($switch)
        }
        if ($session.Connection -eq 'Wi-Fi') {
            $disconnect = New-Object System.Windows.Forms.ToolStripMenuItem 'Disconnect'
            $disconnect.Tag = $session.Serial
            $disconnect.add_Click({ param($sender, $e) Invoke-Safely { Disconnect-Device @($sender.Tag) } })
            [void]$item.DropDownItems.Add($disconnect)
        }
        $close = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop and close'
        $close.Tag = $session.Serial
        $close.add_Click({ param($sender, $e) Invoke-Safely { Close-Device @($sender.Tag); Update-TrayText } })
        [void]$item.DropDownItems.Add($close)
        [void]$menu.Items.Add($item)
    }
    foreach ($session in $closed) {
        $state = if ($session.MovedTo) { "switching to $($session.MovedTo)" } elseif ($session.Disconnected) { 'disconnected' } else { 'closed' }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem "$($session.Title) - $($session.Connection)  [$state]"
        $open = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($session.Disconnected) { 'Reconnect' } else { 'Open window' })
        $open.Tag = $session.Serial
        $open.add_Click({ param($sender, $e) Invoke-Safely { Open-Window @($sender.Tag) } })
        [void]$item.DropDownItems.Add($open)
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $startAll = $menu.Items.Add('Start recording on all devices')
    $startAll.Enabled = @($sessions | Where-Object { -not $_.Recording -and -not $script:Standby.ContainsKey($_.Serial) }).Count -gt 0
    $startAll.add_Click({ Invoke-Safely { if (Confirm-RecordSpace) { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s } }; Update-TrayText } })
    $stopAll = $menu.Items.Add('Stop recording on all devices')
    $stopAll.Enabled = @($sessions | Where-Object { $_.Recording }).Count -gt 0
    $stopAll.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s }; Update-TrayText } })
    $startLogs = $menu.Items.Add('Start device logs on all devices')
    $startLogs.Enabled = @($sessions | Where-Object { -not $_.LogCapture -and -not $script:Standby.ContainsKey($_.Serial) }).Count -gt 0
    $startLogs.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Start-DeviceLog $s }; Update-TrayText } })
    $stopLogs = $menu.Items.Add('Stop device logs on all devices')
    $stopLogs.Enabled = @($script:Sessions.Values | Where-Object { $_.LogCapture }).Count -gt 0 -or $script:LogHandovers.Count -gt 0
    $stopLogs.add_Click({ Invoke-Safely { Stop-AllLogs @(); Update-TrayText } })
    [void](Add-ScreenRecordMenu $menu.Items)
    [void](Add-SnipMenu $menu.Items)
    $connectWifi = $menu.Items.Add('Connect Wi-Fi device...')
    $connectWifi.add_Click({ Invoke-Safely { Show-ConnectDialog } })
    $refresh = $menu.Items.Add('Refresh devices')
    $refresh.Enabled = $script:ClosedSerials.Count -gt 0 -or -not ($NoDiscovery -or $Serial.Count -or $script:Discovery -or $script:Probe)
    $refresh.add_Click({ Invoke-Safely { Invoke-Refresh } })
    $arrange = $menu.Items.Add('Arrange device windows')
    $arrange.Enabled = @($sessions | Where-Object { $_.WindowShown }).Count -gt 0
    $arrange.add_Click({ Invoke-Safely { Invoke-ArrangeWindows } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $openFolder = $menu.Items.Add('Open recordings folder')
    $openFolder.add_Click({ Invoke-Safely { Open-RecordFolder } })
    $changeFolder = $menu.Items.Add('Change recordings folder...')
    $changeFolder.add_Click({ Invoke-Safely { [void](Select-RecordFolder) } })
    $openLogsFolder = $menu.Items.Add('Open device logs folder')
    $openLogsFolder.add_Click({ Invoke-Safely { Open-DeviceLogFolder } })
    $changeLogsFolder = $menu.Items.Add('Change device logs folder...')
    $changeLogsFolder.add_Click({ Invoke-Safely { [void](Select-DeviceLogFolder) } })
    $chooseLogApps = $menu.Items.Add('Choose apps for per-app logs...')
    $chooseLogApps.Enabled = -not $script:AppsScan
    $chooseLogApps.add_Click({ Invoke-Safely { Select-LogApps } })
    $openLog = $menu.Items.Add('Open log')
    $openLog.add_Click({ Invoke-Safely { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$script:LogPath`"" } })
    if ($script:UpdateConfig) {
        $checkUpdate = $menu.Items.Add('Check for updates')
        $checkUpdate.add_Click({ Invoke-Safely { Start-UpdateCheck $true } })
        $autoUpdate = New-Object System.Windows.Forms.ToolStripMenuItem 'Check for updates automatically'
        $autoUpdate.Checked = $script:AutoUpdateCheck
        $autoUpdate.add_Click({ Invoke-Safely { Set-AutoUpdateCheck (-not $script:AutoUpdateCheck) } })
        [void]$menu.Items.Add($autoUpdate)
    }
    $about = $menu.Items.Add('About')
    $about.add_Click({ Invoke-Safely { Show-About } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exit = $menu.Items.Add('Exit')
    $exit.add_Click({ Invoke-Safely { Stop-Monitor } })
}

function Get-ScrcpyVersion {
    if ($null -eq $script:ScrcpyVersion) {
        $first = @((Invoke-Hidden $script:Scrcpy @('--version') 5000 -ScrcpyEnvironment) -split "`r?`n" | Where-Object { $_ -match '^scrcpy\s' }) | Select-Object -First 1
        $script:ScrcpyVersion = if ($first -match '^scrcpy\s+(\S+)') { $Matches[1] } else { '' }
    }
    $script:ScrcpyVersion
}

function Show-About {
    if ($script:About -and -not $script:About.IsDisposed) {
        $script:About.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:About.Activate()
        return
    }
    $version = if ($script:UpdateConfig) { $script:UpdateConfig.Display } else { 'development build' }
    $repo = if ($script:UpdateConfig) { $script:UpdateConfig.Repo } else { $script:DefaultRepo }
    $scrcpyVersion = Get-ScrcpyVersion
    $engine = if ($scrcpyVersion) { "scrcpy $scrcpyVersion" } else { 'scrcpy' }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'About Scrcpy Monitor'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = -not ($script:Panel -and $script:Panel.Visible)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.Padding = New-Object System.Windows.Forms.Padding(16)
    if ($script:Icon) { $form.Icon = $script:Icon }

    $layout = New-Object System.Windows.Forms.FlowLayoutPanel
    $layout.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $layout.AutoSize = $true
    $layout.WrapContents = $false
    $form.Controls.Add($layout)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Scrcpy Monitor'
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 14, [System.Drawing.FontStyle]::Bold)
    $layout.Controls.Add($title)

    $details = New-Object System.Windows.Forms.Label
    $details.AutoSize = $true
    $details.MaximumSize = New-Object System.Drawing.Size(480, 0)
    $details.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 6)
    $details.Text = "Version: $version`nMirroring engine: $engine`nAuthor: $script:Author`n`n" +
        "Mirrors one or more Android devices in separate windows arranged without overlapping, keeps each window open while its device restarts or reconnects, and records the screens.`n`n" +
        "- Detects devices connected over USB or Wi-Fi and shows the connection type of each.`n" +
        "- A restarting device stays in the list as Device restarting; a device that is turned off or unplugged is removed.`n" +
        "- Closing a window or Stop and close removes the device from the list; Refresh shows it again and finds devices on the local Wi-Fi network (ports 5555, 5037 and any port you connected with).`n" +
        "- Connect a Wi-Fi device by IP address and port, disconnect it or reconnect it later; Wi-Fi devices are remembered.`n" +
        "- A device connected over both USB and Wi-Fi is mirrored over USB; the Wi-Fi connection is kept on standby.`n" +
        "- Switch a device between USB and Wi-Fi; the old entry is removed, and if the switch fails the previous connection is restored.`n" +
        "- Device windows open centered without overlapping, at 100% when they fit, and are arranged again when a window opens or closes (Window > Arrange windows).`n" +
        "- Record per device or all devices from the window button (Alt+E), this panel or the tray icon; recordings continue across restarts and are saved as one MP4 per device with the device name as a header above the screen.`n" +
        "- Record combined also joins the recordings of the selected devices into one video laid out like the arranged device windows, with each device name above its screen; each device keeps its real size and proportions.`n" +
        "- Screen recording (Recording menu or tray icon) records the desktop: a movable, resizable rectangle, a selected area, one or all screens (listed from the screens connected to this computer), a window or the area around the mouse, with pause and screenshots (F12 record, Shift+F12 pause, F11 screenshot).`n" +
        "- Snip (Print Screen, Recording > Snip or the tray icon) captures an area, a window, a screen or all screens like the Snipping Tool, copies it to the clipboard, saves it as PNG or JPEG and opens a markup editor (pen, highlighter, rectangle, arrow, eraser, crop, undo, copy, save as).`n" +
        "- The status bar shows the recordings folder and its free space; recordings have no time limit and are stopped and saved automatically when the disk is almost full.`n" +
        "- Device logs (Logs menu, Start device logs or the tray icon) save each device's logcat in the Android Studio Logcat format to a text file, one folder per device, with a copy per checked app (Logs > Choose apps for per-app logs..., which lists PA and PIA first, then the open, running and installed apps, none checked by default) in a subfolder named after the app package; logging continues across restarts and reconnections in the same file.`n" +
        "- The device log records whether PA, PIA and the checked apps are running (APP STATUS) at the start and after every restart or reconnection, with APP STARTED, APP STOPPED, APP CRASHED and APP NOT RESPONDING lines as they happen; the control panel shows the elapsed time and size of each device log.`n" +
        "- Click a column header to sort the list; global actions are in the File, Recording, Logs, Window and Help menus.`n" +
        "- Ctrl+Alt+M opens the tray menu at the mouse pointer from any application (also Window > Show tray menu).`n" +
        "- Checks for updates at startup (Help > Check for updates automatically) or on request; the portable version updates itself.`n`n" +
        'Built on scrcpy by Genymobile (Apache License 2.0).'
    $layout.Controls.Add($details)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = "https://github.com/$repo"
    $link.AutoSize = $true
    $link.add_LinkClicked({ param($sender, $e) Invoke-Safely { Start-Process $sender.Text } })
    $layout.Controls.Add($link)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true
    $buttons.WrapContents = $false
    $buttons.Anchor = [System.Windows.Forms.AnchorStyles]::Right
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    if ($script:Updating -or $script:AvailableUpdate) {
        $update = New-Object System.Windows.Forms.Label
        $update.AutoSize = $true
        $update.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 0)
        $update.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
        if ($script:Updating) {
            $update.Text = "Installing update $(Get-DisplayVersion $script:AvailableUpdate.Tag)... the monitor restarts when it is ready."
        } else {
            $update.Text = "Update $(Get-DisplayVersion $script:AvailableUpdate.Tag) is available."
            $install = New-Object System.Windows.Forms.Button
            $install.Text = 'Install update'
            $install.AutoSize = $true
            $install.add_Click({ param($sender, $e) Invoke-Safely { if (Confirm-Update) { $sender.FindForm().Close(); Start-Update } } })
            $buttons.Controls.Add($install)
        }
        $layout.Controls.Add($update)
    }
    $layout.Controls.Add($buttons)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.add_Click({ param($sender, $e) $sender.FindForm().Close() })
    $buttons.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.CancelButton = $ok
    $form.ActiveControl = $ok

    $form.add_FormClosed({ param($sender, $e) $sender.Dispose(); $script:About = $null })
    $script:About = $form
    $form.Show()
    $form.Activate()
}

function Show-Guide {
    if ($script:Guide -and -not $script:Guide.IsDisposed) {
        $script:Guide.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:Guide.Activate()
        return
    }
    $name = 'scrcpy-monitor-guide.html'
    $path = Join-Path $RepoRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [void](Show-Message "The user guide ($name) was not found in $RepoRoot." 'OK' 'Warning')
        return
    }
    $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Scrcpy Monitor user guide'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size([Math]::Min(1000, [int]($area.Width * 0.8)), [Math]::Min(800, [int]($area.Height * 0.85)))
    $form.MinimumSize = New-Object System.Drawing.Size(480, 360)
    $form.ShowInTaskbar = -not ($script:Panel -and $script:Panel.Visible)
    if ($script:Icon) { $form.Icon = $script:Icon }

    $browser = New-Object System.Windows.Forms.WebBrowser
    $browser.Dock = [System.Windows.Forms.DockStyle]::Fill
    $browser.AllowWebBrowserDrop = $false
    $browser.ScriptErrorsSuppressed = $true
    $browser.IsWebBrowserContextMenuEnabled = $false
    $browser.add_Navigating({
        param($sender, $e)
        if ($e.Url.Scheme -in @('http', 'https', 'mailto')) {
            $e.Cancel = $true
            $target = $e.Url.AbsoluteUri
            Invoke-Safely { Start-Process $target }
        }
    })
    $browser.add_NewWindow({ param($sender, $e) $e.Cancel = $true })
    $form.Controls.Add($browser)

    $form.add_FormClosed({ param($sender, $e) $sender.Dispose(); $script:Guide = $null })
    $script:Guide = $form
    $browser.Navigate((New-Object System.Uri $path))
    $form.Show()
    $form.Activate()
}

function Initialize-ScreenRecorder {
    if (-not ('ScrcpyMonitor.RecFrame' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
namespace ScrcpyMonitor {
    using System;
    using System.Collections.Generic;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Drawing.Imaging;
    using System.Runtime.InteropServices;
    using System.Windows.Forms;

    public class DisplayInfo {
        public IntPtr Handle;
        public Rectangle Bounds;
        public bool Primary;
        public int DdaIndex = -1;
        public string Device = "";
        public int Number;
    }

    public static class ScreenNative {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct MONITORINFOEX { public int Size; public RECT Monitor; public RECT Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct DXGI_OUTPUT_DESC { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; public RECT Desktop; public int Attached; public int Rotation; public IntPtr Monitor; }
        [ComImport, Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IDXGIFactory { void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent(); [PreserveSig] int EnumAdapters(uint index, out IDXGIAdapter adapter); }
        [ComImport, Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IDXGIAdapter { void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent(); [PreserveSig] int EnumOutputs(uint index, out IDXGIOutput output); }
        [ComImport, Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IDXGIOutput { void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent(); [PreserveSig] int GetDesc(out DXGI_OUTPUT_DESC desc); }
        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1([In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory factory);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] static extern bool GetPhysicalCursorPos(out POINT point);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
        public static bool IsCloaked(IntPtr hWnd)
        {
            int value;
            try { return DwmGetWindowAttribute(hWnd, 14, out value, 4) == 0 && value != 0; }
            catch (Exception) { return false; }
        }
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);

        public static IntPtr EnterPerMonitor() {
            try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; }
        }

        public static void Leave(IntPtr previous) {
            if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
        }

        public static float Scale(IntPtr hWnd) {
            try { uint dpi = GetDpiForWindow(hWnd); return dpi > 0 ? dpi / 96f : 1f; } catch (EntryPointNotFoundException) { return 1f; }
        }

        public static void ExcludeFromCapture(IntPtr hWnd) {
            try { SetWindowDisplayAffinity(hWnd, 0x11); } catch (EntryPointNotFoundException) { }
        }

        public static DisplayInfo[] Displays() {
            var list = new List<DisplayInfo>();
            IntPtr previous = EnterPerMonitor();
            try {
                MonitorEnumProc proc = delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data) {
                    var info = new MONITORINFOEX();
                    info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
                    if (GetMonitorInfo(monitor, ref info)) {
                        var display = new DisplayInfo();
                        display.Handle = monitor;
                        display.Bounds = Rectangle.FromLTRB(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom);
                        display.Primary = (info.Flags & 1) != 0;
                        display.Device = info.Device ?? "";
                        list.Add(display);
                    }
                    return true;
                };
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
                GC.KeepAlive(proc);
            } finally {
                Leave(previous);
            }
            try { MapDda(list); } catch (Exception) { }
            list.Sort(delegate(DisplayInfo a, DisplayInfo b) {
                if (a.Primary != b.Primary) return a.Primary ? -1 : 1;
                return a.Bounds.X != b.Bounds.X ? a.Bounds.X.CompareTo(b.Bounds.X) : a.Bounds.Y.CompareTo(b.Bounds.Y);
            });
            for (int i = 0; i < list.Count; i++) list[i].Number = i + 1;
            return list.ToArray();
        }

        static void MapDda(List<DisplayInfo> list) {
            var riid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            IDXGIFactory factory;
            if (CreateDXGIFactory1(ref riid, out factory) != 0 || factory == null) return;
            try {
                IDXGIAdapter adapter;
                if (factory.EnumAdapters(0, out adapter) != 0 || adapter == null) return;
                try {
                    for (uint i = 0; i < 16; i++) {
                        IDXGIOutput output;
                        if (adapter.EnumOutputs(i, out output) != 0 || output == null) break;
                        try {
                            DXGI_OUTPUT_DESC desc;
                            if (output.GetDesc(out desc) != 0) continue;
                            foreach (var display in list) {
                                if (display.Handle == desc.Monitor || (desc.DeviceName != null && desc.DeviceName == display.Device)) display.DdaIndex = (int)i;
                            }
                        } finally {
                            Marshal.ReleaseComObject(output);
                        }
                    }
                } finally {
                    Marshal.ReleaseComObject(adapter);
                }
            } finally {
                Marshal.ReleaseComObject(factory);
            }
        }

        public static Rectangle VirtualBounds(DisplayInfo[] displays) {
            Rectangle all = Rectangle.Empty;
            foreach (var display in displays) all = all.IsEmpty ? display.Bounds : Rectangle.Union(all, display.Bounds);
            return all;
        }

        public static Rectangle MonitorBounds(Rectangle area) {
            IntPtr previous = EnterPerMonitor();
            try {
                var rect = new RECT();
                rect.Left = area.Left; rect.Top = area.Top; rect.Right = area.Right; rect.Bottom = area.Bottom;
                var info = new MONITORINFOEX();
                info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (!GetMonitorInfo(MonitorFromRect(ref rect, 2), ref info)) return area;
                return Rectangle.FromLTRB(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom);
            } finally {
                Leave(previous);
            }
        }

        public static Point Cursor() {
            POINT point;
            if (GetPhysicalCursorPos(out point)) return new Point(point.X, point.Y);
            return System.Windows.Forms.Cursor.Position;
        }

        public static Rectangle ClientBounds(IntPtr hWnd) {
            IntPtr previous = EnterPerMonitor();
            try {
                RECT rect;
                if (!GetClientRect(hWnd, out rect)) return Rectangle.Empty;
                var origin = new POINT();
                if (!ClientToScreen(hWnd, ref origin)) return Rectangle.Empty;
                return new Rectangle(origin.X, origin.Y, rect.Right - rect.Left, rect.Bottom - rect.Top);
            } finally {
                Leave(previous);
            }
        }

        public static bool SaveScreenshot(Rectangle area, string path) {
            if (area.Width <= 0 || area.Height <= 0) return false;
            IntPtr previous = EnterPerMonitor();
            try {
                using (var bitmap = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb)) {
                    using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(area.Location, Point.Empty, area.Size);
                    bitmap.Save(path, ImageFormat.Png);
                }
                return true;
            } finally {
                Leave(previous);
            }
        }

        public static bool SaveWindowShot(IntPtr hWnd, string path) {
            IntPtr previous = EnterPerMonitor();
            try {
                RECT rect;
                if (!GetClientRect(hWnd, out rect) || rect.Right <= 0 || rect.Bottom <= 0) return false;
                using (var bitmap = new Bitmap(rect.Right, rect.Bottom, PixelFormat.Format32bppRgb)) {
                    bool ok;
                    using (var graphics = Graphics.FromImage(bitmap)) {
                        IntPtr hdc = graphics.GetHdc();
                        try { ok = PrintWindow(hWnd, hdc, 3); } finally { graphics.ReleaseHdc(hdc); }
                    }
                    if (!ok) return false;
                    bitmap.Save(path, ImageFormat.Png);
                }
                return true;
            } finally {
                Leave(previous);
            }
        }

        public static Bitmap CaptureArea(Rectangle area) {
            IntPtr previous = EnterPerMonitor();
            try {
                var bitmap = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb);
                using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(area.Location, Point.Empty, area.Size);
                return bitmap;
            } finally {
                Leave(previous);
            }
        }
    }

    public class RecFrame : Form {
        class ToolButton { public string Id; public string Glyph; public string Text; public string Tip; public Rectangle Bounds; public bool Enabled = true; public Color Color = Color.White; }

        public event EventHandler Command;
        public string LastCommand = "";
        public int PresetWidth;
        public int PresetHeight;
        public readonly bool BarOnly;
        public bool Recording { get; private set; }
        public bool Paused { get; private set; }
        string mode = "";
        string time = "00:00:00";
        string size = "";
        Rectangle capture;
        Rectangle frameArea;
        Rectangle toolbar;
        int toolbarPosition;
        float scale = 1f;
        int border = 4;
        int toolbarHeight = 34;
        bool layingOut;
        readonly List<ToolButton> buttons = new List<ToolButton>();
        string hover;
        readonly ToolTip tip = new ToolTip();
        int dragEdges;
        Point dragStart;
        Rectangle dragRect;
        static readonly Color Key = Color.FromArgb(255, 1, 0, 1);
        static string iconFamily;

        static string IconFamily {
            get {
                if (iconFamily == null) {
                    iconFamily = "";
                    foreach (var family in FontFamily.Families) {
                        if (family.Name == "Segoe Fluent Icons") { iconFamily = family.Name; break; }
                        if (family.Name == "Segoe MDL2 Assets") iconFamily = family.Name;
                    }
                }
                return iconFamily;
            }
        }

        RecFrame(bool barOnly) {
            BarOnly = barOnly;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Key;
            TransparencyKey = Key;
            DoubleBuffered = true;
            Text = "Scrcpy Monitor screen recorder";
            MinimumSize = new Size(1, 1);
        }

        public static RecFrame Create(bool barOnly, Rectangle area) {
            IntPtr previous = ScreenNative.EnterPerMonitor();
            try {
                var frame = new RecFrame(barOnly);
                frame.CreateControl();
                IntPtr handle = frame.Handle;
                frame.scale = ScreenNative.Scale(handle);
                ScreenNative.ExcludeFromCapture(handle);
                frame.capture = area;
                frame.Arrange();
                return frame;
            } finally {
                ScreenNative.Leave(previous);
            }
        }

        protected override CreateParams CreateParams {
            get {
                var parameters = base.CreateParams;
                parameters.ExStyle |= 0x80;
                return parameters;
            }
        }

        public Rectangle CaptureArea { get { return capture; } }

        public string Mode {
            get { return mode; }
            set { mode = value ?? ""; RunPerMonitor(Arrange); }
        }

        public void SetCaptureArea(Rectangle area) {
            capture = area;
            RunPerMonitor(Arrange);
        }

        public void PlaceBar(Rectangle monitor) {
            RunPerMonitor(delegate {
                Arrange();
                SetBounds(monitor.X + (monitor.Width - Width) / 2, monitor.Y + (int)(8 * scale), Width, Height);
            });
        }

        public void SetState(bool recording, bool paused) {
            Recording = recording;
            Paused = paused;
            if (!recording) time = "00:00:00";
            RunPerMonitor(Arrange);
            Invalidate();
        }

        public void SetStatus(string elapsed, string fileSize) {
            if (elapsed == time && fileSize == size) return;
            bool resize = (fileSize ?? "").Length != size.Length;
            time = elapsed ?? "";
            size = fileSize ?? "";
            if (resize) RunPerMonitor(Arrange);
            Invalidate();
        }

        void RunPerMonitor(MethodInvoker action) {
            IntPtr previous = ScreenNative.EnterPerMonitor();
            try { action(); } finally { ScreenNative.Leave(previous); }
        }

        Font IconFont() { return new Font(IconFamily.Length > 0 ? IconFamily : "Segoe UI Symbol", 13f * scale, GraphicsUnit.Pixel); }
        Font TextFont() { return new Font("Segoe UI", 13f * scale, GraphicsUnit.Pixel); }

        void AddButton(string id, string glyph, string fallback, string tipText, bool enabled, Color color) {
            var button = new ToolButton();
            button.Id = id;
            button.Glyph = IconFamily.Length > 0 ? glyph : null;
            button.Text = button.Glyph != null ? null : fallback;
            button.Tip = tipText;
            button.Enabled = enabled;
            button.Color = color;
            buttons.Add(button);
        }

        void AddText(string id, string text, Color color) {
            var button = new ToolButton();
            button.Id = id;
            button.Text = text;
            button.Enabled = false;
            button.Color = color;
            buttons.Add(button);
        }

        void BuildButtons() {
            buttons.Clear();
            var red = Color.FromArgb(255, 70, 70);
            if (Recording) AddButton("rec", "\uE71A", "Stop", "Stop recording (F12)", true, Color.White);
            else AddButton("rec", "\uE7C8", "REC", "Start recording (F12)", true, red);
            AddButton("pause", Paused ? "\uE768" : "\uE769", Paused ? "Resume" : "Pause", (Paused ? "Resume" : "Pause") + " recording (Shift+F12)", Recording, Color.White);
            AddButton("shot", "\uE722", "Shot", "Take a screenshot (F11)", true, Color.White);
            if (BarOnly) {
                AddText("mode", mode, Color.Gainsboro);
            } else {
                AddButton("size", null, string.Format("{0} \u00D7 {1}  \u25BE", capture.Width, capture.Height), "Choose the recording size", !Recording, Color.White);
                AddButton("full", "\uE740", "Full", "Fit the frame to this screen", !Recording, Color.White);
            }
            AddText("time", time, Recording ? (Paused ? Color.Orange : red) : Color.Gainsboro);
            AddText("bytes", size, Color.Gainsboro);
            AddButton("folder", "\uE838", "Folder", "Open the recordings folder", true, Color.White);
            AddButton("close", "\uE8BB", "X", Recording ? "Stop recording and close" : "Close the screen recorder", true, Color.White);
        }

        int MeasureButtons() {
            int x = (int)(6 * scale);
            int height = toolbarHeight - (int)(8 * scale);
            using (var iconFont = IconFont())
            using (var textFont = TextFont()) {
                foreach (var button in buttons) {
                    int width;
                    if (button.Glyph != null) width = toolbarHeight - (int)(6 * scale);
                    else if (string.IsNullOrEmpty(button.Text)) width = 0;
                    else width = TextRenderer.MeasureText(button.Text, textFont).Width + (int)(10 * scale);
                    if (button.Id == "time") width = Math.Max(width, TextRenderer.MeasureText("00:00:00", textFont).Width + (int)(10 * scale));
                    button.Bounds = new Rectangle(x, (int)(4 * scale), width, height);
                    x += width + (int)(3 * scale);
                }
            }
            return x + (int)(3 * scale);
        }

        void Arrange() {
            if (layingOut) return;
            layingOut = true;
            try {
                border = Math.Max(3, (int)Math.Round(4 * scale));
                toolbarHeight = (int)Math.Round(34 * scale);
                BuildButtons();
                int toolbarWidth = MeasureButtons();
                if (BarOnly) {
                    toolbar = new Rectangle(0, 0, toolbarWidth, toolbarHeight);
                    frameArea = Rectangle.Empty;
                    SetBounds(Left, Top, toolbarWidth, toolbarHeight);
                } else {
                    Rectangle monitor = ScreenNative.MonitorBounds(capture);
                    int frameWidth = capture.Width + 2 * border;
                    int frameHeight = capture.Height + 2 * border;
                    if (capture.Top - border - toolbarHeight >= monitor.Top) toolbarPosition = 0;
                    else if (capture.Bottom + border + toolbarHeight <= monitor.Bottom) toolbarPosition = 1;
                    else toolbarPosition = 2;
                    int width = Math.Max(frameWidth, toolbarWidth + (toolbarPosition == 2 ? 2 * border : 0));
                    if (toolbarPosition == 0) {
                        toolbar = new Rectangle(0, 0, toolbarWidth, toolbarHeight);
                        frameArea = new Rectangle(0, toolbarHeight, frameWidth, frameHeight);
                        SetBounds(capture.X - border, capture.Y - border - toolbarHeight, width, frameHeight + toolbarHeight);
                    } else if (toolbarPosition == 1) {
                        toolbar = new Rectangle(0, frameHeight, toolbarWidth, toolbarHeight);
                        frameArea = new Rectangle(0, 0, frameWidth, frameHeight);
                        SetBounds(capture.X - border, capture.Y - border, width, frameHeight + toolbarHeight);
                    } else {
                        toolbar = new Rectangle(border, border, toolbarWidth, toolbarHeight);
                        frameArea = new Rectangle(0, 0, frameWidth, frameHeight);
                        SetBounds(capture.X - border, capture.Y - border, width, Math.Max(frameHeight, toolbarHeight + 2 * border));
                    }
                }
                foreach (var button in buttons) button.Bounds.Offset(toolbar.Location);
            } finally {
                layingOut = false;
            }
            Invalidate();
        }

        protected override void OnLocationChanged(EventArgs e) {
            base.OnLocationChanged(e);
            if (layingOut || BarOnly) return;
            int top = toolbarPosition == 0 ? Top + toolbarHeight + border : Top + border;
            capture = new Rectangle(Left + border, top, capture.Width, capture.Height);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x02E0) {
                scale = ScreenNative.Scale(Handle);
                Arrange();
                return;
            }
            if (m.Msg == 0x0084) {
                base.WndProc(ref m);
                var point = PointToClient(new Point((short)((long)m.LParam & 0xFFFF), (short)(((long)m.LParam >> 16) & 0xFFFF)));
                if (toolbar.Contains(point) && ButtonAt(point) == null && (BarOnly || !Recording)) m.Result = new IntPtr(2);
                return;
            }
            if (m.Msg == 0x0232 && !BarOnly) {
                base.WndProc(ref m);
                Arrange();
                Raise("moved");
                return;
            }
            base.WndProc(ref m);
        }

        ToolButton ButtonAt(Point point) {
            foreach (var button in buttons) {
                if (button.Bounds.Contains(point) && (button.Glyph != null || button.Id == "size" || (button.Text != null && button.Enabled) || button.Tip != null)) {
                    if (button.Id == "time" || button.Id == "bytes" || button.Id == "mode") continue;
                    return button;
                }
            }
            return null;
        }

        int EdgesAt(Point point) {
            if (BarOnly || Recording || frameArea.IsEmpty || !frameArea.Contains(point)) return 0;
            if (toolbar.Contains(point)) return 0;
            int grip = Math.Max(border * 2, (int)(10 * scale));
            int corner = (int)(18 * scale);
            var inner = Rectangle.Inflate(frameArea, -border, -border);
            if (inner.Contains(point)) return 0;
            int edges = 0;
            if (point.X < frameArea.Left + grip || (point.Y < frameArea.Top + grip || point.Y >= frameArea.Bottom - grip) && point.X < frameArea.Left + corner) edges |= 1;
            if (point.X >= frameArea.Right - grip || (point.Y < frameArea.Top + grip || point.Y >= frameArea.Bottom - grip) && point.X >= frameArea.Right - corner) edges |= 4;
            if (point.Y < frameArea.Top + grip || (point.X < frameArea.Left + grip || point.X >= frameArea.Right - grip) && point.Y < frameArea.Top + corner) edges |= 2;
            if (point.Y >= frameArea.Bottom - grip || (point.X < frameArea.Left + grip || point.X >= frameArea.Right - grip) && point.Y >= frameArea.Bottom - corner) edges |= 8;
            return edges;
        }

        static Cursor EdgeCursor(int edges) {
            switch (edges) {
                case 1: case 4: return Cursors.SizeWE;
                case 2: case 8: return Cursors.SizeNS;
                case 3: case 12: return Cursors.SizeNWSE;
                case 6: case 9: return Cursors.SizeNESW;
                default: return Cursors.Default;
            }
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            int edges = EdgesAt(e.Location);
            if (edges == 0) return;
            dragEdges = edges;
            dragStart = ScreenNative.Cursor();
            dragRect = capture;
            Capture = true;
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            if (dragEdges != 0) {
                var now = ScreenNative.Cursor();
                int dx = now.X - dragStart.X, dy = now.Y - dragStart.Y;
                int left = dragRect.Left, top = dragRect.Top, right = dragRect.Right, bottom = dragRect.Bottom;
                int min = (int)(64 * scale);
                if ((dragEdges & 1) != 0) left = Math.Min(left + dx, right - min);
                if ((dragEdges & 4) != 0) right = Math.Max(right + dx, left + min);
                if ((dragEdges & 2) != 0) top = Math.Min(top + dy, bottom - min);
                if ((dragEdges & 8) != 0) bottom = Math.Max(bottom + dy, top + min);
                int width = (right - left) & ~1, height = (bottom - top) & ~1;
                if ((dragEdges & 1) != 0) left = right - width;
                if ((dragEdges & 2) != 0) top = bottom - height;
                capture = new Rectangle(left, top, width, height);
                Arrange();
                Update();
                return;
            }
            var button = ButtonAt(e.Location);
            string id = button == null ? null : button.Id;
            if (id != hover) {
                hover = id;
                Invalidate(toolbar);
                tip.Hide(this);
                if (button != null && button.Tip != null) tip.Show(button.Tip, this, button.Bounds.Left, toolbar.Bottom + (int)(4 * scale), 2500);
            }
            Cursor = EdgeCursor(EdgesAt(e.Location));
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (dragEdges != 0) {
                dragEdges = 0;
                Capture = false;
                Arrange();
                Raise("moved");
                return;
            }
            if (e.Button != MouseButtons.Left) return;
            var button = ButtonAt(e.Location);
            if (button == null || !button.Enabled) return;
            if (button.Id == "size") { ShowSizes(button); return; }
            if (button.Id == "full") {
                capture = ScreenNative.MonitorBounds(capture);
                capture.Width &= ~1;
                capture.Height &= ~1;
                Arrange();
                Raise("moved");
                return;
            }
            Raise(button.Id);
        }

        protected override void OnMouseLeave(EventArgs e) {
            base.OnMouseLeave(e);
            if (hover != null) { hover = null; tip.Hide(this); Invalidate(toolbar); }
        }

        void ShowSizes(ToolButton button) {
            var menu = new ContextMenuStrip();
            int[][] sizes = { new[] { 1920, 1080 }, new[] { 1280, 720 }, new[] { 854, 480 }, new[] { 640, 360 }, new[] { 1024, 768 }, new[] { 800, 600 }, new[] { 640, 480 }, new[] { 320, 240 } };
            foreach (var pair in sizes) {
                var item = new ToolStripMenuItem(string.Format("{0} \u00D7 {1}", pair[0], pair[1]));
                item.Tag = pair;
                item.Checked = capture.Width == pair[0] && capture.Height == pair[1];
                item.Click += delegate(object sender, EventArgs args) {
                    var chosen = (int[])((ToolStripItem)sender).Tag;
                    ApplySize(chosen[0], chosen[1]);
                };
                menu.Items.Add(item);
            }
            menu.Items.Add(new ToolStripSeparator());
            var full = new ToolStripMenuItem("Full screen");
            full.Click += delegate { capture = ScreenNative.MonitorBounds(capture); capture.Width &= ~1; capture.Height &= ~1; Arrange(); Raise("moved"); };
            menu.Items.Add(full);
            var select = new ToolStripMenuItem("Select area...");
            select.Click += delegate { Raise("select"); };
            menu.Items.Add(select);
            menu.Closed += delegate { BeginInvoke(new MethodInvoker(menu.Dispose)); };
            menu.Show(this, new Point(button.Bounds.Left, button.Bounds.Bottom));
        }

        void ApplySize(int width, int height) {
            Rectangle monitor = ScreenNative.MonitorBounds(capture);
            width = Math.Min(width, monitor.Width) & ~1;
            height = Math.Min(height, monitor.Height) & ~1;
            int left = Math.Max(monitor.Left, Math.Min(capture.Left, monitor.Right - width));
            int top = Math.Max(monitor.Top, Math.Min(capture.Top, monitor.Bottom - height));
            capture = new Rectangle(left, top, width, height);
            Arrange();
            Raise("moved");
        }

        void Raise(string name) {
            LastCommand = name;
            var handler = Command;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        protected override void OnPaint(PaintEventArgs e) {
            var graphics = e.Graphics;
            graphics.Clear(Key);
            if (!frameArea.IsEmpty) {
                var color = Recording ? (Paused ? Color.Orange : Color.FromArgb(230, 30, 30)) : Color.FromArgb(30, 144, 255);
                using (var brush = new SolidBrush(color)) {
                    var inner = Rectangle.Inflate(frameArea, -border, -border);
                    graphics.FillRectangle(brush, frameArea.Left, frameArea.Top, frameArea.Width, border);
                    graphics.FillRectangle(brush, frameArea.Left, inner.Bottom, frameArea.Width, border);
                    graphics.FillRectangle(brush, frameArea.Left, inner.Top, border, inner.Height);
                    graphics.FillRectangle(brush, inner.Right, inner.Top, border, inner.Height);
                    if (!Recording) {
                        int handle = Math.Max(border * 2, (int)(9 * scale));
                        int[] xs = { frameArea.Left, frameArea.Left + (frameArea.Width - handle) / 2, frameArea.Right - handle };
                        int[] ys = { frameArea.Top, frameArea.Top + (frameArea.Height - handle) / 2, frameArea.Bottom - handle };
                        using (var pen = new Pen(color))
                        foreach (int x in xs) foreach (int y in ys) {
                            if (x == xs[1] && y == ys[1]) continue;
                            graphics.FillRectangle(Brushes.White, x, y, handle - 1, handle - 1);
                            graphics.DrawRectangle(pen, x, y, handle - 1, handle - 1);
                        }
                    }
                }
            }
            using (var back = new SolidBrush(Color.FromArgb(38, 38, 42)))
                graphics.FillRectangle(back, toolbar);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var iconFont = IconFont())
            using (var textFont = TextFont()) {
                foreach (var button in buttons) {
                    bool clickable = ButtonAt(new Point(button.Bounds.Left + 1, button.Bounds.Top + 1)) == button;
                    if (clickable && button.Enabled && hover == button.Id) {
                        using (var brush = new SolidBrush(Color.FromArgb(70, 70, 78))) graphics.FillRectangle(brush, button.Bounds);
                    }
                    var color = button.Enabled || !clickable ? button.Color : Color.FromArgb(110, 110, 110);
                    var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
                    if (button.Glyph != null) TextRenderer.DrawText(graphics, button.Glyph, iconFont, button.Bounds, color, flags);
                    else if (!string.IsNullOrEmpty(button.Text)) TextRenderer.DrawText(graphics, button.Text, textFont, button.Bounds, color, flags);
                }
            }
        }

        protected override void Dispose(bool disposing) {
            if (disposing) tip.Dispose();
            base.Dispose(disposing);
        }
    }

    public class AreaPicker : Form {
        Bitmap shot;
        Rectangle bounds;
        Point start;
        Rectangle selection;
        bool dragging;
        public Rectangle Result = Rectangle.Empty;
        float scale = 1f;

        AreaPicker(Rectangle virtualBounds) {
            bounds = virtualBounds;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            DoubleBuffered = true;
            Cursor = Cursors.Cross;
            KeyPreview = true;
            Text = "Select the recording area";
        }

        public static Rectangle Pick(Rectangle virtualBounds) {
            IntPtr previous = ScreenNative.EnterPerMonitor();
            AreaPicker picker;
            try {
                picker = new AreaPicker(virtualBounds);
                picker.shot = ScreenNative.CaptureArea(virtualBounds);
                picker.CreateControl();
                picker.scale = ScreenNative.Scale(picker.Handle);
                picker.SetBounds(virtualBounds.X, virtualBounds.Y, virtualBounds.Width, virtualBounds.Height);
            } finally {
                ScreenNative.Leave(previous);
            }
            using (picker) {
                picker.ShowDialog();
                picker.shot.Dispose();
                return picker.Result;
            }
        }

        protected override CreateParams CreateParams {
            get {
                var parameters = base.CreateParams;
                parameters.ExStyle |= 0x80;
                return parameters;
            }
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x02E0) return;
            base.WndProc(ref m);
        }

        protected override void OnShown(EventArgs e) {
            base.OnShown(e);
            Activate();
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape) Close();
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Right) { Close(); return; }
            if (e.Button != MouseButtons.Left) return;
            start = e.Location;
            selection = new Rectangle(start, Size.Empty);
            dragging = true;
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            if (!dragging) return;
            var previous = selection;
            selection = Rectangle.FromLTRB(Math.Min(start.X, e.X), Math.Min(start.Y, e.Y), Math.Max(start.X, e.X), Math.Max(start.Y, e.Y));
            var dirty = Rectangle.Union(previous, selection);
            dirty.Inflate((int)(200 * scale), (int)(60 * scale));
            Invalidate(dirty);
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (!dragging || e.Button != MouseButtons.Left) return;
            dragging = false;
            var area = selection;
            area.Offset(bounds.Location);
            if (area.Width < 16 || area.Height < 16) area = ScreenNative.MonitorBounds(new Rectangle(bounds.X + e.X, bounds.Y + e.Y, 1, 1));
            area.Width &= ~1;
            area.Height &= ~1;
            Result = area;
            Close();
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e) {
            var graphics = e.Graphics;
            graphics.DrawImage(shot, e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);
            using (var dim = new SolidBrush(Color.FromArgb(120, 0, 0, 0))) {
                using (var region = new Region(new Rectangle(Point.Empty, Size))) {
                    if (selection.Width > 0 && selection.Height > 0) region.Exclude(selection);
                    graphics.FillRegion(dim, region);
                }
            }
            using (var font = new Font("Segoe UI", 15f * scale, GraphicsUnit.Pixel)) {
                if (selection.Width > 0 && selection.Height > 0) {
                    using (var pen = new Pen(Color.FromArgb(230, 30, 30), Math.Max(1f, 2f * scale)))
                        graphics.DrawRectangle(pen, selection);
                    string label = string.Format("{0} \u00D7 {1}", selection.Width & ~1, selection.Height & ~1);
                    var labelSize = TextRenderer.MeasureText(label, font);
                    var labelRect = new Rectangle(selection.Left, Math.Max(0, selection.Top - labelSize.Height - 4), labelSize.Width + 8, labelSize.Height + 2);
                    using (var back = new SolidBrush(Color.FromArgb(200, 30, 30, 30))) graphics.FillRectangle(back, labelRect);
                    TextRenderer.DrawText(graphics, label, font, labelRect, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                } else {
                    var cursor = PointToClient(ScreenNative.Cursor());
                    var monitor = ScreenNative.MonitorBounds(new Rectangle(cursor.X + bounds.X, cursor.Y + bounds.Y, 1, 1));
                    monitor.Offset(-bounds.X, -bounds.Y);
                    string help = "Drag to select the recording area. Click to select the whole screen. Esc cancels.";
                    var helpSize = TextRenderer.MeasureText(help, font);
                    var helpRect = new Rectangle(monitor.Left + (monitor.Width - helpSize.Width) / 2 - 12, monitor.Top + (int)(40 * scale), helpSize.Width + 24, helpSize.Height + 12);
                    using (var back = new SolidBrush(Color.FromArgb(210, 30, 30, 30))) graphics.FillRectangle(back, helpRect);
                    TextRenderer.DrawText(graphics, help, font, helpRect, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
            }
        }
    }

    public class RecHotKeys : NativeWindow, IDisposable {
        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr Hwnd; public int Message; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; }
        [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        public event EventHandler Pressed;
        public string LastKey = "";
        HookProc proc;
        IntPtr hook;
        IntPtr target;
        System.Threading.Thread thread;
        uint threadId;
        readonly bool[] down = new bool[2];

        public RecHotKeys() {
            var parameters = new CreateParams();
            parameters.Parent = new IntPtr(-3);
            CreateHandle(parameters);
            target = Handle;
        }

        public bool Enabled { get { return thread != null; } }

        public bool Enable() {
            if (thread != null) return true;
            bool installed = false;
            using (var ready = new System.Threading.ManualResetEvent(false)) {
                var worker = new System.Threading.Thread(delegate() {
                    MSG msg;
                    threadId = GetCurrentThreadId();
                    PeekMessage(out msg, IntPtr.Zero, 0, 0, 0);
                    proc = Hook;
                    hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
                    installed = hook != IntPtr.Zero;
                    ready.Set();
                    if (!installed) return;
                    while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { }
                    UnhookWindowsHookEx(hook);
                    hook = IntPtr.Zero;
                });
                worker.IsBackground = true;
                worker.Name = "Screen recorder hotkeys";
                worker.Start();
                if (!ready.WaitOne(5000) || !installed) return false;
                thread = worker;
            }
            return true;
        }

        public void Disable() {
            if (thread == null) return;
            PostThreadMessage(threadId, 0x12, IntPtr.Zero, IntPtr.Zero);
            thread.Join(2000);
            thread = null;
            down[0] = down[1] = false;
        }
        static bool Held(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }

        IntPtr Hook(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0) {
                int message = wParam.ToInt32();
                int key = Marshal.ReadInt32(lParam);
                if (key == 0x7A || key == 0x7B) {
                    int slot = key == 0x7B ? 1 : 0;
                    bool isDown = message == 0x100 || message == 0x104;
                    bool isUp = message == 0x101 || message == 0x105;
                    if (isDown && !Held(0x11) && !Held(0x12) && !Held(0x5B) && !Held(0x5C)) {
                        bool shift = Held(0x10);
                        int id = key == 0x7B ? (shift ? 2 : 1) : (shift ? 0 : 3);
                        if (id != 0) {
                            if (!down[slot]) PostMessage(target, 0x8001, new IntPtr(id), IntPtr.Zero);
                            down[slot] = true;
                            return new IntPtr(1);
                        }
                    } else if (isUp && down[slot]) {
                        down[slot] = false;
                        return new IntPtr(1);
                    }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x8001) {
                int id = m.WParam.ToInt32();
                LastKey = id == 1 ? "rec" : id == 2 ? "pause" : "shot";
                var handler = Pressed;
                if (handler != null) handler(this, EventArgs.Empty);
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            Disable();
            DestroyHandle();
        }
    }
}
'@
    }
    if (-not $script:ScreenKeys) {
        $script:ScreenKeys = New-Object ScrcpyMonitor.RecHotKeys
        $script:ScreenKeys.add_Pressed({ Invoke-Safely { Invoke-ScreenCommand $script:ScreenKeys.LastKey } })
    }
    if (-not $script:ScreenTimer) {
        $script:ScreenTimer = New-Object System.Windows.Forms.Timer
        $script:ScreenTimer.Interval = 100
        $script:ScreenTimer.add_Tick({ Invoke-Safely { Update-ScreenRecorder } })
    }
}

function Test-DdaGrab {
    if ($null -eq $script:ScreenDda) {
        $list = Invoke-Hidden $script:Ffmpeg @('-hide_banner', '-filters') 15000
        if (-not $list) { return $false }
        $script:ScreenDda = [bool]($list -match '\sddagrab\s')
    }
    $script:ScreenDda
}

function Get-ScreenFolder {
    $folder = Join-Path $RecordDir 'Screen Recordings'
    [void](New-Item -ItemType Directory -Force -Path $folder)
    $folder
}

function Open-ScreenFolder {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Get-ScreenFolder)`""
}

function Get-EvenSize([int]$Value) {
    [Math]::Max(2, $Value - ($Value % 2))
}

function Get-FileLength([string]$Path) {
    try { (New-Object System.IO.FileInfo $Path).Length } catch { 0L }
}

function Format-ScreenBytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:0.00} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0.0} MB' -f ($Bytes / 1MB) }
    '{0:0} KB' -f ($Bytes / 1KB)
}

function ConvertTo-ScreenArea([System.Drawing.Rectangle]$Area) {
    if ($Area.Width -lt 16 -or $Area.Height -lt 16) { return [System.Drawing.Rectangle]::Empty }
    [System.Drawing.Rectangle]::new($Area.X, $Area.Y, (Get-EvenSize $Area.Width), (Get-EvenSize $Area.Height))
}

function Save-ScreenArea([System.Drawing.Rectangle]$Area) {
    Set-Setting 'ScreenArea' ('{0},{1},{2},{3}' -f $Area.X, $Area.Y, $Area.Width, $Area.Height)
}

function Get-SavedScreenArea($Displays) {
    $virtual = [ScrcpyMonitor.ScreenNative]::VirtualBounds($Displays)
    if ([string](Get-Setting 'ScreenArea') -match '^(-?\d+),(-?\d+),(\d+),(\d+)$') {
        $area = [System.Drawing.Rectangle]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        if ($area.Width -ge 16 -and $area.Height -ge 16 -and $virtual.Contains($area)) { return $area }
    }
    $primary = $Displays[0].Bounds
    $width = Get-EvenSize ([Math]::Min(1280, $primary.Width - 80))
    $height = Get-EvenSize ([Math]::Min(720, $primary.Height - 160))
    [System.Drawing.Rectangle]::new($primary.X + [int][Math]::Floor(($primary.Width - $width) / 2), $primary.Y + [int][Math]::Floor(($primary.Height - $height) / 2), $width, $height)
}

function Get-ScreenFollowSize {
    if ([string](Get-Setting 'ScreenFollowSize') -match '^(\d+)x(\d+)$' -and [int]$Matches[1] -ge 64 -and [int]$Matches[2] -ge 64) {
        return [System.Drawing.Size]::new([int]$Matches[1], [int]$Matches[2])
    }
    [System.Drawing.Size]::new(1280, 720)
}

function Get-ScreenDisplayAt($Displays, [System.Drawing.Point]$Point) {
    foreach ($display in $Displays) { if ($display.Bounds.Contains($Point)) { return $display } }
    $Displays[0]
}

function Get-ScreenWindow($State) {
    if ($State.WindowSerial -and $script:Sessions.ContainsKey($State.WindowSerial) -and (Get-Date) -ge $State.NextWindowLookup -and
        -not [ScrcpyMonitor.ScreenNative]::IsWindow($State.Window)) {
        $State.NextWindowLookup = (Get-Date).AddSeconds(1)
        $session = $script:Sessions[$State.WindowSerial]
        if ($session.ScrcpyPid) {
            try {
                $process = [System.Diagnostics.Process]::GetProcessById($session.ScrcpyPid)
                try { $State.Window = $process.MainWindowHandle } finally { $process.Dispose() }
            } catch { }
        }
    }
    $State.Window
}

function Get-ScreenArea($State, $Displays) {
    switch ($State.Mode) {
        'rect' { return $State.Frame.CaptureArea }
        'all' { return [ScrcpyMonitor.ScreenNative]::VirtualBounds($Displays) }
        'monitor' {
            $display = @($Displays | Where-Object { $_.Device -eq $State.Device }) | Select-Object -First 1
            if (-not $display) { $display = $Displays[0] }
            return $display.Bounds
        }
        'window' {
            $handle = Get-ScreenWindow $State
            if ($handle -eq [IntPtr]::Zero -or -not [ScrcpyMonitor.ScreenNative]::IsWindow($handle) -or [ScrcpyMonitor.ScreenNative]::IsIconic($handle)) {
                return [System.Drawing.Rectangle]::Empty
            }
            return [ScrcpyMonitor.ScreenNative]::ClientBounds($handle)
        }
        default {
            $cursor = [ScrcpyMonitor.ScreenNative]::Cursor()
            $bounds = (Get-ScreenDisplayAt $Displays $cursor).Bounds
            $width = Get-EvenSize ([Math]::Min($State.FollowSize.Width, $bounds.Width))
            $height = Get-EvenSize ([Math]::Min($State.FollowSize.Height, $bounds.Height))
            $x = [Math]::Max($bounds.Left, [Math]::Min($cursor.X - [int][Math]::Floor($width / 2), $bounds.Right - $width))
            $y = [Math]::Max($bounds.Top, [Math]::Min($cursor.Y - [int][Math]::Floor($height / 2), $bounds.Bottom - $height))
            return [System.Drawing.Rectangle]::new($x, $y, $width, $height)
        }
    }
}

function Start-ScreenPart($State) {
    $displays = @([ScrcpyMonitor.ScreenNative]::Displays())
    if (-not $displays.Count) { throw 'No screen was found.' }
    $State.Displays = $displays
    $area = Get-ScreenArea $State $displays
    if ($area.Width -lt 2 -or $area.Height -lt 2) { throw 'The window to record is closed or minimized.' }
    $follow = $State.Mode -eq 'window' -or $State.Mode -eq 'mouse'
    $sources = @(if ($follow) { $displays } else { $displays | Where-Object { $_.Bounds.IntersectsWith($area) } })
    if (-not $sources.Count) { throw 'The recording area is outside the screens.' }
    $box = [ScrcpyMonitor.ScreenNative]::VirtualBounds($sources)
    if (-not $follow) { $area = [System.Drawing.Rectangle]::Intersect($area, $box) }
    $width = Get-EvenSize ([Math]::Min($area.Width, $box.Width))
    $height = Get-EvenSize ([Math]::Min($area.Height, $box.Height))
    $useDda = -not $State.NoDda -and (Test-DdaGrab) -and -not @($sources | Where-Object { $_.DdaIndex -lt 0 }).Count
    if (-not $useDda -and -not $follow) { $box = [System.Drawing.Rectangle]::new($area.X, $area.Y, $width, $height) }
    $x = [Math]::Max(0, [Math]::Min($area.X - $box.X, $box.Width - $width))
    $y = [Math]::Max(0, [Math]::Min($area.Y - $box.Y, $box.Height - $height))
    $crop = $follow -or $width -ne $box.Width -or $height -ne $box.Height
    $inputArgs = @()
    if ($useDda) {
        $chains = @($sources | ForEach-Object { "ddagrab=output_idx=$($_.DdaIndex):framerate=30:draw_mouse=1" })
        if ($sources.Count -eq 1 -and -not $follow) {
            $graph = $chains[0]
            if ($crop) { $graph += ":offset_x=$($box.X + $x - $sources[0].Bounds.X):offset_y=$($box.Y + $y - $sources[0].Bounds.Y):video_size=${width}x$height" }
            $graph += ',hwdownload,format=bgra'
            $crop = $false
        } elseif ($sources.Count -eq 1) {
            $graph = $chains[0] + ',hwdownload,format=bgra'
        } else {
            $labels = ''
            $parts = for ($i = 0; $i -lt $sources.Count; $i++) {
                $labels += "[s$i]"
                "$($chains[$i]),hwdownload,format=bgra[s$i]"
            }
            $layout = @($sources | ForEach-Object { '{0}_{1}' -f ($_.Bounds.X - $box.X), ($_.Bounds.Y - $box.Y) }) -join '|'
            $graph = ($parts -join ';') + ";${labels}xstack=inputs=$($sources.Count):layout=${layout}:fill=black"
        }
    } else {
        $inputArgs = @('-f', 'gdigrab', '-framerate', '30', '-draw_mouse', '1', '-offset_x', "$($box.X)", '-offset_y', "$($box.Y)", '-video_size', "$($box.Width)x$($box.Height)", '-i', 'desktop')
        $graph = '[0:v]null'
    }
    if ($crop) { $graph += ",crop=w=${width}:h=${height}:x=${x}:y=${y}:exact=1" }
    $graph += ',format=yuv420p[v]'
    $State.Follow = if ($follow) { [pscustomobject]@{ Box = $box; Width = $width; Height = $height; X = $x; Y = $y } } else { $null }
    $State.PendingSize = ''
    $State.ResizedAt = $null

    $index = $State.Parts.Count + 1
    $part = '{0}_part{1:D2}.mkv' -f $State.Base, $index
    $log = Join-Path $script:LogDir ('screen-record-part{0:D2}.log' -f $index)
    $arguments = @('-hide_banner', '-loglevel', 'warning', '-nostats', '-stats_period', '0.05') + $inputArgs + @('-filter_complex', $graph, '-map', '[v]') +
                 (Get-CombineEncoderArgs) + @('-pix_fmt', 'yuv420p', '-g', '60', '-y', $part)
    $psi = New-HiddenStartInfo $env:ComSpec ('/d /s /c ""{0}" {1} 2> "{2}""' -f $script:Ffmpeg, (ConvertTo-ArgumentString $arguments), $log)
    $psi.RedirectStandardInput = $true
    Write-Log "Starting screen recorder: $(ConvertTo-ArgumentString $arguments)"
    $State.Process = [System.Diagnostics.Process]::Start($psi)
    $State.Part = $part
    $State.PartLog = $log
    $State.PartStartedAt = Get-Date
    $State.UsedDda = $useDda
    [void]$State.Parts.Add($part)
}

function Stop-ScreenPart($State) {
    $process = $State.Process
    if (-not $process) { return }
    $State.Process = $null
    if ($State.PartStartedAt) {
        $State.Elapsed += (Get-Date) - $State.PartStartedAt
        $State.PartStartedAt = $null
    }
    try {
        if (-not $process.HasExited) {
            $process.StandardInput.Write('q')
            $process.StandardInput.Flush()
        }
    } catch { }
    if (-not $process.WaitForExit(8000)) {
        Write-Log 'The screen recorder did not stop gracefully; killing it.'
        Stop-ProcessTree $process.Id
        [void]$process.WaitForExit(3000)
    }
    try { $process.StandardInput.Dispose() } catch { }
    $process.Dispose()
    $State.DoneBytes += Get-FileLength $State.Part
}

function Restore-ScreenPart($State) {
    $exitCode = $State.Process.ExitCode
    $quick = $State.PartStartedAt -and ((Get-Date) - $State.PartStartedAt).TotalSeconds -lt 5
    $tail = @(Get-Content -LiteralPath $State.PartLog -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
    Write-Log "The screen recorder stopped unexpectedly (exit code $exitCode): $tail"
    Stop-ScreenPart $State
    if ($quick -and $State.UsedDda) {
        $State.NoDda = $true
        Write-Log 'Falling back to GDI screen capture.'
    }
    $now = Get-Date
    [void]$State.Failures.Add($now)
    foreach ($time in @($State.Failures)) { if (($now - $time).TotalSeconds -gt 30) { $State.Failures.Remove($time) } }
    if ($State.Failures.Count -ge 3) {
        Show-Notification "Screen recording stopped because ffmpeg failed repeatedly. $tail" 'Warning'
        Stop-ScreenRecording
        return
    }
    try { Start-ScreenPart $State } catch {
        Show-Notification "Screen recording stopped: $($_.Exception.Message)" 'Warning'
        Stop-ScreenRecording
    }
}

function Update-ScreenFollow($State, [datetime]$Now) {
    $follow = $State.Follow
    $area = Get-ScreenArea $State $State.Displays
    if ($area.Width -lt 2 -or $area.Height -lt 2) { return }
    if ($State.Mode -eq 'window') {
        $width = Get-EvenSize ([Math]::Min($area.Width, $follow.Box.Width))
        $height = Get-EvenSize ([Math]::Min($area.Height, $follow.Box.Height))
        if ($width -ne $follow.Width -or $height -ne $follow.Height) {
            $size = "${width}x$height"
            if ($State.PendingSize -ne $size) {
                $State.PendingSize = $size
                $State.ResizedAt = $Now
            } elseif (($Now - $State.ResizedAt).TotalMilliseconds -ge 800) {
                Write-Log "The recorded window was resized to $size; starting a new part."
                Stop-ScreenPart $State
                try { Start-ScreenPart $State } catch {
                    Show-Notification "Screen recording stopped: $($_.Exception.Message)" 'Warning'
                    Stop-ScreenRecording
                }
                return
            }
        } else {
            $State.PendingSize = ''
        }
    }
    $x = [Math]::Max(0, [Math]::Min($area.X - $follow.Box.X, $follow.Box.Width - $follow.Width))
    $y = [Math]::Max(0, [Math]::Min($area.Y - $follow.Box.Y, $follow.Box.Height - $follow.Height))
    if ($x -eq $follow.X -and $y -eq $follow.Y) { return }
    try {
        $writer = $State.Process.StandardInput
        if ($x -ne $follow.X) { $writer.Write("ccrop -1 x $x`n") }
        if ($y -ne $follow.Y) { $writer.Write("ccrop -1 y $y`n") }
        $writer.Flush()
        $follow.X = $x
        $follow.Y = $y
    } catch { }
}

function Update-ScreenRecorder {
    $state = $script:ScreenRec
    if (-not $state) {
        $script:ScreenTimer.Stop()
        return
    }
    $now = Get-Date
    if ($state.Recording -and -not $state.Paused -and $state.Process) {
        if ($state.Process.HasExited) { Restore-ScreenPart $state }
        elseif ($state.Follow -and $now -ge $state.NextFollow) {
            $state.NextFollow = $now.AddMilliseconds(200)
            Update-ScreenFollow $state $now
        }
    }
    if ($state.Recording -and $state.Frame -and $now -ge $state.NextStatus) {
        $state.NextStatus = $now.AddMilliseconds(500)
        $elapsed = $state.Elapsed
        if ($state.PartStartedAt) { $elapsed += $now - $state.PartStartedAt }
        $bytes = $state.DoneBytes
        if ($state.Process) { $bytes += Get-FileLength $state.Part }
        $state.Frame.SetStatus(('{0:00}:{1:mm}:{1:ss}' -f [int][Math]::Floor($elapsed.TotalHours), $elapsed), (Format-ScreenBytes $bytes))
    }
}

function Start-ScreenRecording {
    $state = $script:ScreenRec
    if (-not $state -or $state.Recording) { return }
    if (-not (Confirm-RecordSpace) -or $script:ScreenRec -ne $state -or $state.Recording) { return }
    $folder = Get-ScreenFolder
    $stem = 'Screen_Capture_{0:yyyyMMdd_HHmmss}' -f (Get-Date)
    $base = Join-Path $folder $stem
    $suffix = 2
    while ((Test-Path -LiteralPath "$base.mp4") -or (Test-Path -LiteralPath "${base}_part01.mkv")) {
        $base = Join-Path $folder "${stem}_$suffix"
        $suffix++
    }
    $state.Base = $base
    $state.Parts.Clear()
    $state.Failures.Clear()
    $state.Elapsed = [TimeSpan]::Zero
    $state.DoneBytes = 0L
    $state.NoDda = $false
    Get-ChildItem -LiteralPath $script:LogDir -Filter 'screen-record-part*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Start-ScreenPart $state } catch {
        Show-Notification "Could not start the screen recording: $($_.Exception.Message)" 'Warning'
        return
    }
    $state.Recording = $true
    $state.Paused = $false
    $state.NextStatus = Get-Date
    if ($state.Frame) { $state.Frame.SetState($true, $false) }
    Write-Log "Screen recording started: $($state.Label)"
    Update-TrayText
}

function Stop-ScreenRecording {
    $state = $script:ScreenRec
    if (-not $state -or -not $state.Recording) { return }
    Stop-ScreenPart $state
    $state.Recording = $false
    $state.Paused = $false
    if ($state.Frame) {
        $state.Frame.SetState($false, $false)
        $state.Frame.SetStatus('00:00:00', '')
    }
    Complete-ScreenRecording $state
    Update-TrayText
}

function Switch-ScreenPause {
    $state = $script:ScreenRec
    if (-not $state -or -not $state.Recording) { return }
    if ($state.Paused) {
        try { Start-ScreenPart $state } catch {
            Show-Notification "Screen recording stopped: $($_.Exception.Message)" 'Warning'
            Stop-ScreenRecording
            return
        }
        $state.Paused = $false
        Write-Log 'Screen recording resumed.'
    } else {
        Stop-ScreenPart $state
        $state.Paused = $true
        Write-Log 'Screen recording paused.'
    }
    if ($state.Frame) { $state.Frame.SetState($true, $state.Paused) }
}

function Complete-ScreenRecording($State) {
    $parts = @($State.Parts | Where-Object { Test-VideoFile $_ })
    foreach ($part in @($State.Parts | Where-Object { $parts -notcontains $_ })) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    $State.Parts.Clear()
    if (-not $parts.Count) {
        Show-Notification 'Screen recording stopped; nothing was recorded.'
        return
    }
    $output = "$($State.Base).mp4"
    $listFile = Join-Path $script:StateDir ("concat-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $sizes = @(if ($script:Ffprobe -and $parts.Count -gt 1) { $parts | ForEach-Object { Get-VideoSize $_ } })
    $widths = @(for ($i = 0; $i -lt $sizes.Count; $i += 2) { $sizes[$i] })
    $heights = @(for ($i = 1; $i -lt $sizes.Count; $i += 2) { $sizes[$i] })
    $steps = New-Object System.Collections.ArrayList
    if (@($widths | Select-Object -Unique).Count -le 1 -and @($heights | Select-Object -Unique).Count -le 1) {
        $lines = foreach ($part in $parts) { "file '" + ($part -replace "'", "'\''") + "'" }
        [System.IO.File]::WriteAllLines($listFile, [string[]]$lines)
        [void]$steps.Add(@('-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', $listFile, '-c', 'copy', '-movflags', '+faststart', $output))
    } else {
        $width = ($widths | Measure-Object -Maximum).Maximum
        $height = ($heights | Measure-Object -Maximum).Maximum
        $inputs = @()
        $filters = @()
        $labels = ''
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $inputs += @('-i', $parts[$i])
            $filters += "[${i}:v]scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,setsar=1[v$i]"
            $labels += "[v$i]"
        }
        $graph = ($filters -join ';') + ";${labels}concat=n=$($parts.Count):v=1:a=0[v]"
        [void]$steps.Add(@('-hide_banner', '-nostdin', '-loglevel', 'error', '-y') + $inputs + @('-filter_complex', $graph, '-map', '[v]') +
                         (Get-CombineEncoderArgs) + @('-pix_fmt', 'yuv420p', '-movflags', '+faststart', $output))
    }
    $merge = [pscustomobject]@{ Process = $null; Steps = $steps; Parts = $parts; Temps = @(); Output = $output; ListFile = $listFile; Member = $null; Segments = @(); Title = '' }
    try {
        $merge.Process = Start-MergeStep $merge
    } catch {
        Write-Log "Failed to start ffmpeg: $($_.Exception.Message)"
    }
    [void]$script:Merges.Add($merge)
    Write-Log "Saving the screen recording ($($parts.Count) part(s)) to $output"
}

function Save-ScreenShot {
    $state = $script:ScreenRec
    if (-not $state) { return }
    $area = Get-ScreenArea $state @([ScrcpyMonitor.ScreenNative]::Displays())
    if ($area.Width -lt 2 -or $area.Height -lt 2) {
        Show-Notification 'Nothing to capture: the window is closed or minimized.' 'Warning'
        return
    }
    $path = Join-Path (Get-ScreenFolder) ('Screenshot_{0:yyyyMMdd_HHmmss_fff}.png' -f (Get-Date))
    if ([ScrcpyMonitor.ScreenNative]::SaveScreenshot($area, $path)) { Show-Notification "Screenshot saved: $path" }
    else { Show-Notification 'Could not take the screenshot.' 'Warning' }
}

function Select-ScreenArea($State) {
    $State.Frame.Hide()
    try {
        $area = ConvertTo-ScreenArea ([ScrcpyMonitor.AreaPicker]::Pick([ScrcpyMonitor.ScreenNative]::VirtualBounds([ScrcpyMonitor.ScreenNative]::Displays())))
    } finally {
        if ($script:ScreenRec -eq $State -and $State.Frame) { $State.Frame.Show() }
    }
    if ($area.IsEmpty -or $script:ScreenRec -ne $State -or -not $State.Frame) { return }
    $State.Frame.SetCaptureArea($area)
    Save-ScreenArea $area
}

function Invoke-ScreenCommand([string]$Name) {
    $state = $script:ScreenRec
    if (-not $state) { return }
    switch ($Name) {
        'rec' { if ($state.Recording) { Stop-ScreenRecording } else { Start-ScreenRecording } }
        'pause' { Switch-ScreenPause }
        'shot' { Save-ScreenShot }
        'folder' { Open-ScreenFolder }
        'close' { Close-ScreenRecorder }
        'moved' { if ($state.Frame) { Save-ScreenArea $state.Frame.CaptureArea } }
        'select' { Select-ScreenArea $state }
    }
}

function Close-ScreenRecorder {
    $state = $script:ScreenRec
    if (-not $state) { return }
    Stop-ScreenRecording
    $script:ScreenRec = $null
    if ($script:ScreenTimer) { $script:ScreenTimer.Stop() }
    if ($script:ScreenKeys) { $script:ScreenKeys.Disable() }
    if ($state.Frame) {
        $frame = $state.Frame
        $state.Frame = $null
        $frame.Close()
    }
    Update-TrayText
}

function Open-ScreenRecorder([string]$Mode, [string]$Target = '', [string]$Label = '') {
    if (-not $script:Ffmpeg) {
        Show-Notification 'Screen recording needs ffmpeg, which was not found.' 'Warning'
        return
    }
    Initialize-ScreenRecorder
    if ($script:ScreenRec -and $script:ScreenRec.Recording) {
        Show-Notification 'A screen recording is in progress. Stop it (F12) before choosing another area.'
        return
    }
    $displays = @([ScrcpyMonitor.ScreenNative]::Displays())
    if (-not $displays.Count) { return }
    Close-ScreenRecorder
    $area = [System.Drawing.Rectangle]::Empty
    if ($Mode -eq 'select') {
        $area = ConvertTo-ScreenArea ([ScrcpyMonitor.AreaPicker]::Pick([ScrcpyMonitor.ScreenNative]::VirtualBounds($displays)))
        if ($area.IsEmpty) { return }
        Save-ScreenArea $area
        $Mode = 'rect'
    } elseif ($Mode -eq 'rect') {
        $area = Get-SavedScreenArea $displays
    }
    $state = [pscustomobject]@{
        Mode = $Mode; Device = ''; Window = [IntPtr]::Zero; WindowSerial = ''; Label = 'Rectangle on screen'; Frame = $null
        Recording = $false; Paused = $false; Process = $null; Part = $null; PartLog = $null; PartStartedAt = $null
        Parts = (New-Object System.Collections.ArrayList); Base = $null; Elapsed = [TimeSpan]::Zero; DoneBytes = 0L
        Failures = (New-Object System.Collections.ArrayList); NoDda = $false; UsedDda = $false; Displays = $displays
        Follow = $null; FollowSize = (Get-ScreenFollowSize); PendingSize = ''; ResizedAt = $null; NextStatus = Get-Date; NextFollow = Get-Date; NextWindowLookup = Get-Date
    }
    $barArea = $displays[0].Bounds
    switch ($Mode) {
        'all' {
            $virtual = [ScrcpyMonitor.ScreenNative]::VirtualBounds($displays)
            $state.Label = 'Full screen ({0} x {1})' -f $virtual.Width, $virtual.Height
        }
        'monitor' {
            $display = @($displays | Where-Object { "$($_.Number)" -eq $Target }) | Select-Object -First 1
            if (-not $display) { $display = $displays[0] }
            $state.Device = $display.Device
            $state.Label = if ($displays.Count -gt 1) { 'Screen {0} ({1} x {2})' -f $display.Number, $display.Bounds.Width, $display.Bounds.Height } else { 'Full screen ({0} x {1})' -f $display.Bounds.Width, $display.Bounds.Height }
            $barArea = $display.Bounds
        }
        'window' {
            if ($Target -like 'serial:*') {
                $state.WindowSerial = $Target.Substring(7)
            } elseif ($Target -match '^hwnd:(\d+)$') {
                $state.Window = [IntPtr][long]$Matches[1]
            }
            $handle = Get-ScreenWindow $state
            if ($handle -eq [IntPtr]::Zero -or -not [ScrcpyMonitor.ScreenNative]::IsWindow($handle)) {
                Show-Notification 'The window to record is no longer open.' 'Warning'
                return
            }
            $state.Label = "Window: $Label"
            $client = [ScrcpyMonitor.ScreenNative]::ClientBounds($handle)
            if (-not $client.IsEmpty) { $barArea = [ScrcpyMonitor.ScreenNative]::MonitorBounds($client) }
        }
        'mouse' {
            if ($Target -match '^(\d+)x(\d+)$') {
                $state.FollowSize = [System.Drawing.Size]::new([int]$Matches[1], [int]$Matches[2])
                Set-Setting 'ScreenFollowSize' $Target
            }
            $state.Label = 'Around mouse ({0} x {1})' -f $state.FollowSize.Width, $state.FollowSize.Height
            $barArea = (Get-ScreenDisplayAt $displays ([ScrcpyMonitor.ScreenNative]::Cursor())).Bounds
        }
    }
    if ($Mode -eq 'rect') {
        $frame = [ScrcpyMonitor.RecFrame]::Create($false, $area)
    } else {
        $frame = [ScrcpyMonitor.RecFrame]::Create($true, [System.Drawing.Rectangle]::Empty)
        $frame.Mode = $state.Label
        $frame.PlaceBar($barArea)
    }
    $frame.add_Command({ param($sender, $e) Invoke-Safely { Invoke-ScreenCommand $sender.LastCommand } })
    $frame.add_FormClosed({
        param($sender, $e)
        Invoke-Safely {
            $current = $script:ScreenRec
            if ($current -and $current.Frame -eq $sender) {
                $current.Frame = $null
                Close-ScreenRecorder
            }
        }
    })
    $state.Frame = $frame
    $script:ScreenRec = $state
    $frame.Show()
    if (-not $script:ScreenKeys.Enable()) { Write-Log 'Could not enable the screen recorder hotkeys.' }
    $script:ScreenTimer.Start()
    Write-Log "Screen recorder opened: $($state.Label)"
}

function Request-ScreenRecorder([string]$Mode, [string]$Target = '', [string]$Label = '') {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Tag = @($Mode, $Target, $Label)
    $timer.add_Tick({
        param($sender, $e)
        $sender.Stop()
        $request = $sender.Tag
        $sender.Dispose()
        Invoke-Safely { Open-ScreenRecorder $request[0] $request[1] $request[2] }
    })
    $timer.Start()
}

function Get-ScreenWindowChoices {
    $choices = New-Object System.Collections.ArrayList
    $owned = @{}
    foreach ($session in @($script:Sessions.Values | Where-Object { $_.WindowShown -and $_.ScrcpyPid } | Sort-Object Title)) {
        $owned[[int]$session.ScrcpyPid] = $true
        [void]$choices.Add([pscustomobject]@{ Text = $session.Title; Target = "serial:$($session.Serial)"; Device = $true })
    }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Id -eq $PID -or $owned.ContainsKey($process.Id)) { continue }
            $handle = $process.MainWindowHandle
            $title = $process.MainWindowTitle
            if ($handle -eq [IntPtr]::Zero -or -not $title -or -not [ScrcpyMonitor.ScreenNative]::IsWindowVisible($handle) -or [ScrcpyMonitor.ScreenNative]::IsCloaked($handle)) { continue }
            if ($title.Length -gt 60) { $title = $title.Substring(0, 57) + '...' }
            [void]$choices.Add([pscustomobject]@{ Text = $title; Target = "hwnd:$($handle.ToInt64())"; Device = $false })
        } catch { } finally { $process.Dispose() }
    }
    $devices = @($choices | Where-Object { $_.Device })
    $others = @($choices | Where-Object { -not $_.Device } | Sort-Object Text)
    , @($devices + $others)
}

function Add-ScreenMenuItem([System.Windows.Forms.ToolStripItemCollection]$Items, [string]$Text, [object[]]$Action, [bool]$Checked = $false) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Tag = $Action
    $item.Checked = $Checked
    $item.add_Click({
        param($sender, $e)
        Invoke-Safely {
            $action = $sender.Tag
            if ($action[0] -eq 'cmd') { Invoke-ScreenCommand $action[1] }
            elseif ($action[0] -eq 'folder') { Open-ScreenFolder }
            else { Request-ScreenRecorder $action[1] $action[2] $action[3] }
            Update-TrayText
        }
    })
    [void]$Items.Add($item)
    $item
}

function Add-ScreenRecordMenu([System.Windows.Forms.ToolStripItemCollection]$Items) {
    $root = New-Object System.Windows.Forms.ToolStripMenuItem 'Screen recording'
    [void]$root.DropDownItems.Add('...')
    $root.add_DropDownOpening({ param($sender, $e) Invoke-Safely { Update-ScreenRecordMenu $sender } })
    [void]$Items.Add($root)
    $root
}

function Update-ScreenRecordMenu([System.Windows.Forms.ToolStripMenuItem]$Root) {
    $items = $Root.DropDownItems
    $items.Clear()
    if (-not $script:Ffmpeg) {
        $missing = New-Object System.Windows.Forms.ToolStripMenuItem 'Needs ffmpeg (not found)'
        $missing.Enabled = $false
        [void]$items.Add($missing)
        return
    }
    $state = $script:ScreenRec
    if ($state) {
        $recText = if ($state.Recording) { 'Stop screen recording (F12)' } else { 'Start screen recording (F12)' }
        [void](Add-ScreenMenuItem $items $recText @('cmd', 'rec'))
        if ($state.Recording) {
            [void](Add-ScreenMenuItem $items $(if ($state.Paused) { 'Resume (Shift+F12)' } else { 'Pause (Shift+F12)' }) @('cmd', 'pause'))
        }
        [void](Add-ScreenMenuItem $items 'Take screenshot (F11)' @('cmd', 'shot'))
        if (-not $state.Recording) { [void](Add-ScreenMenuItem $items 'Close screen recorder' @('cmd', 'close')) }
        [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    if (-not ($state -and $state.Recording)) {
        Initialize-ScreenRecorder
        $mode = if ($state) { $state.Mode } else { '' }
        [void](Add-ScreenMenuItem $items 'Rectangle on screen' @('open', 'rect', '', '') ($mode -eq 'rect'))
        [void](Add-ScreenMenuItem $items 'Select area...' @('open', 'select', '', ''))
        $displays = @([ScrcpyMonitor.ScreenNative]::Displays())
        if ($displays.Count -gt 1) {
            $virtual = [ScrcpyMonitor.ScreenNative]::VirtualBounds($displays)
            [void](Add-ScreenMenuItem $items ('Full screen - all screens ({0} x {1})' -f $virtual.Width, $virtual.Height) @('open', 'all', '', '') ($mode -eq 'all'))
        }
        foreach ($display in $displays) {
            $text = if ($displays.Count -gt 1) { 'Screen {0} ({1} x {2}){3}' -f $display.Number, $display.Bounds.Width, $display.Bounds.Height, $(if ($display.Primary) { ', main' } else { '' }) }
                    else { 'Full screen ({0} x {1})' -f $display.Bounds.Width, $display.Bounds.Height }
            [void](Add-ScreenMenuItem $items $text @('open', 'monitor', "$($display.Number)", '') ($mode -eq 'monitor' -and $state.Device -eq $display.Device))
        }
        $windowMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Lock to window'
        $windowMenu.Checked = $mode -eq 'window'
        $choices = Get-ScreenWindowChoices
        $previousDevice = $true
        foreach ($choice in $choices) {
            if ($previousDevice -and -not $choice.Device -and $windowMenu.DropDownItems.Count) { [void]$windowMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
            $previousDevice = $choice.Device
            [void](Add-ScreenMenuItem $windowMenu.DropDownItems $choice.Text @('open', 'window', $choice.Target, $choice.Text))
        }
        if (-not $choices.Count) {
            $none = New-Object System.Windows.Forms.ToolStripMenuItem 'No window'
            $none.Enabled = $false
            [void]$windowMenu.DropDownItems.Add($none)
        }
        [void]$items.Add($windowMenu)
        $mouseMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Around mouse'
        $mouseMenu.Checked = $mode -eq 'mouse'
        $saved = Get-ScreenFollowSize
        foreach ($size in @('1920x1080', '1280x720', '854x480', '640x360', '800x600', '640x480')) {
            [void](Add-ScreenMenuItem $mouseMenu.DropDownItems ($size -replace 'x', ' x ') @('open', 'mouse', $size, '') ($size -eq "$($saved.Width)x$($saved.Height)"))
        }
        [void]$items.Add($mouseMenu)
        [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    [void](Add-ScreenMenuItem $items 'Open screen recordings folder' @('folder'))
}

function Get-SnipFolder {
    $folder = Join-Path $RecordDir 'Screenshots'
    [void](New-Item -ItemType Directory -Force -Path $folder)
    $folder
}

function Open-SnipFolder {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Get-SnipFolder)`""
}

function Get-SnipFormat {
    if ((Get-Setting 'SnipFormat') -eq 'jpg') { 'jpg' } else { 'png' }
}

function Test-SnipEditor { (Get-Setting 'SnipEditor') -ne $false }

function Test-SnipPrintScreen { (Get-Setting 'SnipPrintScreen') -ne $false }

function Enable-SnipKey {
    if ($script:SnipKey -and $script:SnipKey.Enabled) { return $true }
    Initialize-DesktopTools
    if (-not $script:SnipKey) {
        $script:SnipKey = New-Object ScrcpyMonitor.SnipKey
        $script:SnipKey.add_Pressed({ Invoke-Safely { Request-Snip 'rect' $null 1 } })
    }
    if ($script:SnipKey.Enable()) { return $true }
    Write-Log 'Could not hook the Print Screen key for snipping.'
    $false
}

function Set-SnipPrintScreen([bool]$Enabled) {
    Set-Setting 'SnipPrintScreen' $Enabled
    if ($Enabled) { [void](Enable-SnipKey) }
    elseif ($script:SnipKey) { $script:SnipKey.Disable() }
}

function Request-Snip([string]$Mode = 'rect', $Editor = $null, [int]$Delay = 250) {
    if ($script:Snipping -or $script:Exiting) { return }
    if ($Editor) {
        if (-not $Editor.ConfirmDiscard()) { return }
        $Editor.Hide()
    }
    $script:Snipping = $true
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(1, $Delay)
    $timer.Tag = @($Mode, $Editor)
    $timer.add_Tick({
        param($sender, $e)
        $sender.Stop()
        $request = $sender.Tag
        $sender.Dispose()
        try { Invoke-Safely { Invoke-Snip $request[0] $request[1] } } finally { $script:Snipping = $false }
    })
    $timer.Start()
}

function Invoke-Snip([string]$Mode, $Editor) {
    $image = $null
    try {
        Initialize-DesktopTools
        $image = [ScrcpyMonitor.SnipPicker]::Snip($Mode)
    } finally {
        if (-not $image -and $Editor -and -not $Editor.IsDisposed -and -not $script:Exiting) { $Editor.ShowEditor() }
    }
    if (-not $image) { return }
    if ($script:Exiting) { $image.Dispose(); return }
    $path = [System.IO.Path]::Combine($RecordDir, 'Screenshots', ('Snip_{0:yyyyMMdd_HHmmss_fff}.{1}' -f (Get-Date), (Get-SnipFormat)))
    $saved = $true
    try { [void](Get-SnipFolder); [ScrcpyMonitor.SnipImage]::Save($image, $path) } catch { $saved = $false; Write-Log "Could not save the snip to ${path}: $($_.Exception.Message)" }
    $copied = [ScrcpyMonitor.SnipImage]::Copy($image)
    $status = if ($saved -and $copied) { "Copied to the clipboard and saved: $path" }
              elseif ($saved) { "Saved: $path (could not copy to the clipboard)" }
              elseif ($copied) { 'Copied to the clipboard (could not save the file)' }
              else { 'Could not copy or save the snip' }
    Write-Log "Snip: $status"
    if ($Editor -and -not $Editor.IsDisposed) {
        $Editor.LoadImage($image, $path, $status)
        $Editor.ShowEditor()
    } elseif (Test-SnipEditor) {
        Show-SnipEditor $image $path $status
    } else {
        $image.Dispose()
        Show-Notification "Snip: $status" $(if ($saved -or $copied) { 'Info' } else { 'Warning' })
    }
}

function Show-SnipEditor($Image, [string]$Path, [string]$Status) {
    $editor = New-Object ScrcpyMonitor.SnipEditor -ArgumentList $Image, $Path, $Status
    if ($script:Icon) { $editor.Icon = $script:Icon }
    $editor.add_NewSnip({ param($sender, $e) Invoke-Safely { Request-Snip $sender.RequestedMode $sender 150 } })
    $editor.add_FormClosed({ param($sender, $e) [void]$script:SnipEditors.Remove($sender) })
    [void]$script:SnipEditors.Add($editor)
    $editor.ShowEditor()
}

function Close-SnipEditors {
    foreach ($editor in @($script:SnipEditors)) {
        Invoke-Safely {
            $editor.Prompt = $false
            $editor.Close()
            $editor.Dispose()
        }
    }
    $script:SnipEditors.Clear()
}

function Add-SnipMenuItem([System.Windows.Forms.ToolStripItemCollection]$Items, [string]$Text, [scriptblock]$Action, [bool]$Checked = $false, [string]$Shortcut = '') {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Tag = $Action
    $item.Checked = $Checked
    if ($Shortcut) { $item.ShortcutKeyDisplayString = $Shortcut }
    $item.add_Click({ param($sender, $e) Invoke-Safely { & $sender.Tag } })
    [void]$Items.Add($item)
    $item
}

function Add-SnipMenu([System.Windows.Forms.ToolStripItemCollection]$Items) {
    $root = New-Object System.Windows.Forms.ToolStripMenuItem 'Snip'
    [void]$root.DropDownItems.Add('...')
    $root.add_DropDownOpening({ param($sender, $e) Invoke-Safely { Update-SnipMenu $sender } })
    [void]$Items.Add($root)
    $root
}

function Update-SnipMenu([System.Windows.Forms.ToolStripMenuItem]$Root) {
    $items = $Root.DropDownItems
    $items.Clear()
    $keyText = if ($script:SnipKey -and $script:SnipKey.Enabled) { 'Print Screen' } else { '' }
    [void](Add-SnipMenuItem $items 'Snip an area' { Request-Snip 'rect' } $false $keyText)
    [void](Add-SnipMenuItem $items 'Snip a window' { Request-Snip 'window' })
    if (@([System.Windows.Forms.Screen]::AllScreens).Count -gt 1) {
        [void](Add-SnipMenuItem $items 'Snip a screen' { Request-Snip 'screen' })
        [void](Add-SnipMenuItem $items 'Snip all screens' { Request-Snip 'all' })
    } else {
        [void](Add-SnipMenuItem $items 'Snip full screen' { Request-Snip 'all' })
    }
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $format = Get-SnipFormat
    [void](Add-SnipMenuItem $items 'Save snips as PNG' { Set-Setting 'SnipFormat' 'png' } ($format -eq 'png'))
    [void](Add-SnipMenuItem $items 'Save snips as JPEG' { Set-Setting 'SnipFormat' 'jpg' } ($format -eq 'jpg'))
    [void](Add-SnipMenuItem $items 'Open markup editor after snipping' { Set-Setting 'SnipEditor' (-not (Test-SnipEditor)) } (Test-SnipEditor))
    [void](Add-SnipMenuItem $items 'Use Print Screen to snip' { Set-SnipPrintScreen (-not ($script:SnipKey -and $script:SnipKey.Enabled)) } ([bool]($script:SnipKey -and $script:SnipKey.Enabled)))
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-SnipMenuItem $items 'Open snips folder' { Open-SnipFolder })
}

function Open-RecordFolder {
    [void](New-Item -ItemType Directory -Force -Path $RecordDir)
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$RecordDir`""
}

function Initialize-LogcatCapture {
    if ('ScrcpyMonitor.LogcatCapture' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace ScrcpyMonitor {
    public class LogcatCapture {
        static readonly Regex HeaderPattern = new Regex(@"^\[ (\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\s+(?:\S+:\s*)?(\d+):\s*(\d+)\s+([VDIWEFAS])/(.*?)\s*\]$", RegexOptions.Compiled);
        static readonly Regex BootPattern = new Regex(@"^[0-9a-fA-F-]{16,}$", RegexOptions.Compiled);
        static readonly Regex VersionPattern = new Regex(@"versionName=(\S+)", RegexOptions.Compiled);
        static readonly Regex StartProcPattern = new Regex(@"^Start proc (\d+):([^/\s]+)/", RegexOptions.Compiled);
        static readonly Regex KillingPattern = new Regex(@"^Killing (\d+):([^/\s]+)/\S+(?: \(adj -?\d+\))?: (.*)$", RegexOptions.Compiled);
        static readonly Regex ClockPattern = new Regex(@"^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)()", RegexOptions.Compiled);
        static readonly Regex DiedPattern = new Regex(@"^Process (\S+) \(pid (\d+)\) has died", RegexOptions.Compiled);
        static readonly Regex AnrPattern = new Regex(@"^ANR in (\S+)", RegexOptions.Compiled);
        const string Rule = "----------------------------";
        public const string PaPackage = "com.global.wwca";
        public const string PiaPackage = "com.global.integrated";
        const string VersionCommand = "if [ \"$(getprop sys.boot_completed)\" = 1 ]; then for p in " + PaPackage + " " + PiaPackage + "; do echo \"@$p\"; dumpsys package $p | grep -E 'versionName|Unable to find'; done; fi";
        readonly object versionLock = new object();
        string versionText;
        bool versionPending;
        DateTime statusTime = DateTime.MinValue;
        readonly HashSet<int> stoppedPids = new HashSet<int>();
        readonly string adb;
        readonly string label;
        readonly object writeLock = new object();
        readonly object processLock = new object();
        readonly List<Process> children = new List<Process>();
        readonly ManualResetEvent stopEvent = new ManualResetEvent(false);
        readonly Dictionary<int, string> pids = new Dictionary<int, string>();
        readonly HashSet<int> missingPids = new HashSet<int>();
        readonly List<string> entryLines = new List<string>();
        readonly Dictionary<string, StreamWriter> appWriters = new Dictionary<string, StreamWriter>();
        readonly HashSet<string> appFailed = new HashSet<string>();
        volatile HashSet<string> apps = new HashSet<string>();
        string entryApp;
        StreamWriter writer;
        Timer flushTimer;
        Thread thread;
        DateTime pidsRefreshedAt = DateTime.MinValue;
        volatile bool stopping;
        volatile string serial;
        volatile string state = "Waiting for device";
        volatile string error;
        long entries;
        string reading;
        bool entryOpen;
        bool entryEmitted;
        bool entrySkipped;
        int pendingBlanks;
        DateTime entryTime;
        int entryPid;
        int entryTid;
        string entryLevel;
        string entryTag;
        string indent = "";
        bool filtering;
        DateTime lastKey = DateTime.MinValue;
        int lastKeyCount;
        int seenAtLastKey;

        public LogcatCapture(string adbPath, string deviceSerial, string path, string deviceLabel) {
            adb = adbPath;
            serial = deviceSerial;
            label = deviceLabel;
            Path = path;
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path));
            writer = new StreamWriter(new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
            StartedAt = DateTime.Now;
        }

        public string Path { get; private set; }
        public DateTime StartedAt { get; private set; }
        public string Serial { get { return serial; } set { serial = value; } }
        public string State { get { return state; } }
        public string Error { get { return error; } }
        public bool Failed { get { return error != null; } }
        public long Entries { get { return Interlocked.Read(ref entries); } }
        public long Size { get { try { return new FileInfo(Path).Length; } catch (Exception) { return 0; } } }

        public void SetApps(string[] list) {
            apps = new HashSet<string>(list ?? new string[0]);
        }

        public void Start() {
            Marker("LOGGING STARTED: " + label);
            flushTimer = new Timer(delegate { Flush(); }, null, 1000, 1000);
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "Logcat " + serial;
            thread.Start();
        }

        public void RequestStop() {
            stopping = true;
            stopEvent.Set();
            KillChildren();
        }

        public void Stop() {
            RequestStop();
            if (thread != null) thread.Join(5000);
            if (flushTimer != null) flushTimer.Dispose();
            lock (writeLock) {
                if (writer == null) return;
                string marker = MarkerText(error == null ? "LOGGING STOPPED" : "LOGGING STOPPED: " + error);
                foreach (string app in new List<string>(appWriters.Keys)) {
                    WriteApp(app, marker);
                    CloseApp(app);
                }
                try {
                    writer.WriteLine(marker);
                    writer.Flush();
                } catch (Exception) { }
                try { writer.Dispose(); } catch (Exception) { }
                writer = null;
            }
        }

        static string MarkerText(string text) {
            return Rule + " " + text + " (" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + ") " + Rule;
        }

        void Marker(string text) {
            string line = MarkerText(text);
            Write(line, null);
            lock (writeLock) {
                foreach (string app in new List<string>(appWriters.Keys)) WriteApp(app, line);
            }
        }

        bool IsTracked(string package) {
            return package == PaPackage || package == PiaPackage || apps.Contains(package);
        }

        static string AppLabel(string package) {
            if (package == PaPackage) return "PA (" + package + ")";
            if (package == PiaPackage) return "PIA (" + package + ")";
            return package;
        }

        public static string AppStatusText(Dictionary<int, string> processes, IEnumerable<string> chosen) {
            List<string> tracked = new List<string> { PaPackage, PiaPackage };
            List<string> others = new List<string>();
            foreach (string app in chosen ?? new string[0]) {
                if (!tracked.Contains(app) && !others.Contains(app)) others.Add(app);
            }
            others.Sort(StringComparer.Ordinal);
            tracked.AddRange(others);
            List<string> parts = new List<string>();
            foreach (string app in tracked) {
                List<int> found = new List<int>();
                foreach (KeyValuePair<int, string> pair in processes) {
                    if (pair.Value == app) found.Add(pair.Key);
                }
                found.Sort();
                parts.Add(AppLabel(app) + (found.Count > 0 ? " running (pid " + string.Join(", ", found) + ")" : " not running"));
            }
            return string.Join(", ", parts);
        }

        public static string[] ParseAppEvent(string tag, string message) {
            Match match;
            if (tag == "ActivityManager") {
                match = StartProcPattern.Match(message);
                if (match.Success) return new string[] { "APP STARTED", match.Groups[2].Value, match.Groups[1].Value, "" };
                match = KillingPattern.Match(message);
                if (match.Success) return new string[] { "APP STOPPED", match.Groups[2].Value, match.Groups[1].Value, match.Groups[3].Value.Trim() };
                match = DiedPattern.Match(message);
                if (match.Success) return new string[] { "APP STOPPED", match.Groups[1].Value, match.Groups[2].Value, "process died" };
                match = AnrPattern.Match(message);
                if (match.Success) return new string[] { "APP NOT RESPONDING", match.Groups[1].Value, "", "" };
                return null;
            }
            if ((tag == "AndroidRuntime" && message.StartsWith("FATAL EXCEPTION")) || (tag == "libc" && message.StartsWith("Fatal signal"))) {
                return new string[] { "APP CRASHED", "", "", message.Trim() };
            }
            return null;
        }

        void NoteAppEvent(string name) {
            if (entryLines.Count == 0 || entryTime < statusTime) return;
            string[] found = ParseAppEvent(entryTag, entryLines[0]);
            if (found == null) return;
            string process = found[1].Length > 0 ? found[1] : name;
            string pidText = found[2].Length > 0 ? found[2] : (found[0] == "APP CRASHED" ? entryPid.ToString(CultureInfo.InvariantCulture) : "");
            int pid;
            bool hasPid = int.TryParse(pidText, NumberStyles.None, CultureInfo.InvariantCulture, out pid);
            if (found[0] == "APP STARTED" && hasPid) {
                pids[pid] = process;
                missingPids.Remove(pid);
            }
            if (process.Length == 0 || process.IndexOf(':') >= 0 || !IsTracked(process)) return;
            if (found[0] == "APP STARTED" && hasPid) stoppedPids.Remove(pid);
            else if (found[0] == "APP STOPPED" && hasPid && !stoppedPids.Add(pid)) return;
            Marker(found[0] + ": " + AppLabel(process) + (hasPid ? ", pid " + pidText : "") + (found[3].Length > 0 ? " - " + found[3] : ""));
        }

        DateTime DeviceNow(string device) {
            Match match = ClockPattern.Match(RunAdb(new string[] { "-s", device, "shell", "date '+%m-%d %H:%M:%S'" }, 5000).Trim());
            return match.Success ? ParseTime(match) : DateTime.MinValue;
        }

        void Write(string text, string app) {
            lock (writeLock) {
                if (writer == null) return;
                try { writer.WriteLine(text); } catch (Exception ex) { Fail(ex); return; }
                if (app == null) return;
                if (!appWriters.ContainsKey(app)) {
                    if (appFailed.Contains(app) || appWriters.Count >= 500) return;
                    try {
                        string appPath = AppLogPath(Path, app);
                        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(appPath));
                        appWriters[app] = new StreamWriter(new FileStream(appPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
                    } catch (Exception) {
                        appFailed.Add(app);
                        return;
                    }
                    WriteApp(app, MarkerText("LOGGING STARTED: " + label));
                }
                WriteApp(app, text);
            }
        }

        void WriteApp(string app, string text) {
            StreamWriter appWriter;
            if (!appWriters.TryGetValue(app, out appWriter)) return;
            try { appWriter.WriteLine(text); } catch (Exception) { CloseApp(app); }
        }

        void CloseApp(string app) {
            StreamWriter appWriter;
            appFailed.Add(app);
            if (!appWriters.TryGetValue(app, out appWriter)) return;
            appWriters.Remove(app);
            try { appWriter.Dispose(); } catch (Exception) { }
        }

        public static string AppLogPath(string path, string package) {
            StringBuilder folder = new StringBuilder();
            foreach (char c in package) folder.Append(c < 32 || "<>:\"/\\|?*".IndexOf(c) >= 0 ? '_' : c);
            string name = folder.ToString().Trim('.', ' ');
            if (name.Length == 0) name = "_";
            return System.IO.Path.Combine(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path), name), System.IO.Path.GetFileName(path));
        }

        static bool LooksLikePackage(string name) {
            return name.IndexOf('.') >= 0 && name.IndexOfAny(new char[] { '/', '@', ' ' }) < 0;
        }

        public static string AppPackage(string name, HashSet<string> installed) {
            if (string.IsNullOrEmpty(name)) return null;
            int colon = name.IndexOf(':');
            string package = (colon >= 0 ? name.Substring(0, colon) : name).Trim();
            if (package.Length == 0) return null;
            if (package == "system_process") return package;
            if (installed.Count > 0) return installed.Contains(package) ? package : null;
            return LooksLikePackage(package) ? package : null;
        }

        public static HashSet<string> ParsePackages(string text) {
            HashSet<string> result = new HashSet<string>();
            foreach (string raw in text.Split('\n')) {
                string line = raw.Trim();
                if (line.StartsWith("package:") && line.Length > 8) result.Add(line.Substring(8));
            }
            return result;
        }

        public static string LogApp(string name, HashSet<string> chosen) {
            if (string.IsNullOrEmpty(name)) return null;
            int colon = name.IndexOf(':');
            string package = (colon >= 0 ? name.Substring(0, colon) : name).Trim();
            if (package.Length == 0) return null;
            return chosen.Contains(package) ? package : null;
        }

        public static string ForegroundApp(string text) {
            foreach (string pattern in new string[] { @"mCurrentFocus=Window\{[^}]*?\s([\w.]+)/", @"mFocusedApp=\S*\{[^}]*?\s([\w.]+)/", @"mResumedActivity:? ActivityRecord\{[^}]*?\s([\w.]+)/" }) {
                Match match = Regex.Match(text ?? "", pattern);
                if (match.Success) return match.Groups[1].Value;
            }
            return null;
        }

        static string RunAdbOnce(string adbPath, string[] args, int timeout) {
            ProcessStartInfo info = new ProcessStartInfo(adbPath, Join(args));
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = new UTF8Encoding(false);
            try {
                using (Process process = Process.Start(info)) {
                    process.ErrorDataReceived += delegate { };
                    process.BeginErrorReadLine();
                    System.Threading.Tasks.Task<string> output = process.StandardOutput.ReadToEndAsync();
                    if (!process.WaitForExit(timeout)) {
                        try { process.Kill(); } catch (Exception) { }
                        return "";
                    }
                    return output.Wait(2000) ? output.Result : "";
                }
            } catch (Exception) {
                return "";
            }
        }

        public static AppScan ScanApps(string adbPath, string[] serials) {
            HashSet<string> running = new HashSet<string>();
            HashSet<string> opened = new HashSet<string>();
            HashSet<string> userApps = new HashSet<string>();
            foreach (string device in serials) {
                HashSet<string> installed = ParsePackages(RunAdbOnce(adbPath, new string[] { "-s", device, "shell", "pm list packages" }, 15000));
                userApps.UnionWith(ParsePackages(RunAdbOnce(adbPath, new string[] { "-s", device, "shell", "pm list packages -3" }, 15000)));
                foreach (string package in new string[] { PaPackage, PiaPackage }) {
                    if (installed.Contains(package)) userApps.Add(package);
                }
                string text = RunAdbOnce(adbPath, new string[] { "-s", device, "shell", "ps -A -o PID,NAME" }, 10000);
                if (text.Split('\n').Length <= 3) text = RunAdbOnce(adbPath, new string[] { "-s", device, "shell", "ps" }, 10000);
                foreach (string name in ParseProcessNames(text).Values) {
                    string package = AppPackage(name, installed);
                    if (package != null) running.Add(package);
                }
                string app = ForegroundApp(RunAdbOnce(adbPath, new string[] { "-s", device, "shell", "dumpsys window" }, 10000));
                if (app != null) opened.Add(app);
            }
            running.UnionWith(opened);
            AppScan scan = new AppScan();
            scan.Running = new List<string>(running).ToArray();
            scan.Opened = new List<string>(opened).ToArray();
            scan.Installed = new List<string>(userApps).ToArray();
            return scan;
        }

        public static System.Threading.Tasks.Task<AppScan> ScanAppsAsync(string adbPath, string[] serials) {
            return System.Threading.Tasks.Task.Factory.StartNew(() => ScanApps(adbPath, serials ?? new string[0]));
        }

        public static Dictionary<string, string> ParseAppVersions(string text) {
            Dictionary<string, string> versions = new Dictionary<string, string>();
            HashSet<string> resolved = new HashSet<string>();
            string current = null;
            foreach (string raw in (text ?? "").Split('\n')) {
                string line = raw.Trim();
                if (line.StartsWith("@")) {
                    current = line.Substring(1);
                    if (!versions.ContainsKey(current)) versions[current] = "";
                    continue;
                }
                if (current == null || versions[current].Length > 0) continue;
                if (line.StartsWith("Unable to find")) {
                    resolved.Add(current);
                    continue;
                }
                Match match = VersionPattern.Match(line);
                if (match.Success) {
                    versions[current] = match.Groups[1].Value;
                    resolved.Add(current);
                }
            }
            if (!resolved.Contains(PaPackage) || !resolved.Contains(PiaPackage)) return null;
            return versions;
        }

        static string VersionOf(Dictionary<string, string> versions, string package) {
            string version;
            return versions.TryGetValue(package, out version) && version.Length > 0 ? version : "Not installed";
        }

        public static string AppVersionText(Dictionary<string, string> versions) {
            if (versions == null) return null;
            return "PA (" + PaPackage + ") " + VersionOf(versions, PaPackage) + ", PIA (" + PiaPackage + ") " + VersionOf(versions, PiaPackage);
        }

        public static Dictionary<string, string> ReadAppVersions(string adbPath, string device) {
            return ParseAppVersions(RunAdbOnce(adbPath, new string[] { "-s", device, "shell", VersionCommand }, 10000));
        }

        public static System.Threading.Tasks.Task<Dictionary<string, Dictionary<string, string>>> ScanVersionsAsync(string adbPath, string[] serials) {
            return System.Threading.Tasks.Task.Factory.StartNew(() => {
                Dictionary<string, Dictionary<string, string>> result = new Dictionary<string, Dictionary<string, string>>();
                foreach (string device in serials ?? new string[0]) {
                    Dictionary<string, string> versions = ReadAppVersions(adbPath, device);
                    if (versions != null) result[device] = versions;
                }
                return result;
            });
        }

        public void NoteVersions(Dictionary<string, string> versions, bool force) {
            string text = AppVersionText(versions);
            lock (versionLock) {
                if (text == null) {
                    if (force) versionPending = true;
                    return;
                }
                if (!force && !versionPending && text == versionText) return;
                versionPending = false;
                versionText = text;
                Marker("APP VERSIONS: " + text);
            }
        }

        void Flush() {
            lock (writeLock) {
                if (writer == null) return;
                try { writer.Flush(); } catch (Exception ex) { Fail(ex); }
                foreach (KeyValuePair<string, StreamWriter> pair in new List<KeyValuePair<string, StreamWriter>>(appWriters)) {
                    try { pair.Value.Flush(); } catch (Exception) { CloseApp(pair.Key); }
                }
            }
        }

        void Fail(Exception ex) {
            if (error == null) error = ex.Message;
            stopping = true;
            stopEvent.Set();
            KillChildren();
        }

        void KillChildren() {
            lock (processLock) {
                foreach (Process child in children) {
                    try { if (!child.HasExited) child.Kill(); } catch (Exception) { }
                }
            }
        }

        static string Join(string[] args) {
            StringBuilder text = new StringBuilder();
            foreach (string arg in args) {
                if (text.Length > 0) text.Append(' ');
                if (arg.IndexOfAny(new char[] { ' ', '\t', '"' }) >= 0) text.Append('"').Append(arg.Replace("\"", "\\\"")).Append('"');
                else text.Append(arg);
            }
            return text.ToString();
        }

        Process StartAdb(string[] args) {
            ProcessStartInfo info = new ProcessStartInfo(adb, Join(args));
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = new UTF8Encoding(false);
            lock (processLock) {
                if (stopping) return null;
                Process process = Process.Start(info);
                process.ErrorDataReceived += delegate { };
                process.BeginErrorReadLine();
                children.Add(process);
                return process;
            }
        }

        void Release(Process process) {
            lock (processLock) { children.Remove(process); }
            try { if (!process.HasExited) process.Kill(); } catch (Exception) { }
            try { process.WaitForExit(2000); } catch (Exception) { }
            process.Dispose();
        }

        string RunAdb(string[] args, int timeout) {
            Process process = null;
            try {
                process = StartAdb(args);
                if (process == null) return "";
                System.Threading.Tasks.Task<string> output = process.StandardOutput.ReadToEndAsync();
                if (!process.WaitForExit(timeout)) return "";
                return output.Wait(2000) ? output.Result : "";
            } catch (Exception) {
                return "";
            } finally {
                if (process != null) Release(process);
            }
        }

        void Run() {
            string lastBoot = null;
            bool announced = false;
            int quickExits = 0;
            try {
                while (!stopping) {
                    state = "Waiting for device";
                    string current = serial;
                    if (RunAdb(new string[] { "-s", current, "get-state" }, 5000).Trim() != "device") {
                        stopEvent.WaitOne(2000);
                        continue;
                    }
                    string boot = RunAdb(new string[] { "-s", current, "shell", "cat /proc/sys/kernel/random/boot_id" }, 5000).Trim();
                    if (stopping) break;
                    if (!BootPattern.IsMatch(boot)) boot = "";
                    bool sameBoot = lastBoot != null && (boot.Length == 0 || lastBoot.Length == 0 || boot == lastBoot);
                    bool restarted = lastBoot != null && !sameBoot;
                    if (restarted) Marker("DEVICE RESTARTED: " + current);
                    else if (announced) Marker("DEVICE RECONNECTED: " + current);
                    announced = false;
                    Dictionary<string, string> versions = ParseAppVersions(RunAdb(new string[] { "-s", current, "shell", VersionCommand }, 10000));
                    if (stopping) break;
                    NoteVersions(versions, restarted);
                    if (!sameBoot) {
                        lastKey = DateTime.MinValue;
                        lastKeyCount = 0;
                        pids.Clear();
                        missingPids.Clear();
                        stoppedPids.Clear();
                    }
                    filtering = sameBoot && lastKey != DateTime.MinValue;
                    seenAtLastKey = 0;
                    lastBoot = boot;
                    reading = current;
                    statusTime = DeviceNow(current);
                    if (stopping) break;
                    Dictionary<int, string> running = RefreshPids();
                    if (stopping) break;
                    Marker("APP STATUS: " + (running.Count > 0 ? AppStatusText(running, apps) : "unknown (could not read the process list)"));
                    state = "Logging";
                    DateTime began = DateTime.Now;
                    long before = Entries;
                    ReadLogcat();
                    if (stopping) break;
                    state = "Waiting for device";
                    if ((DateTime.Now - began).TotalSeconds >= 3 || Entries != before) {
                        Marker("DEVICE DISCONNECTED: " + current);
                        announced = true;
                        quickExits = 0;
                    } else {
                        quickExits++;
                    }
                    stopEvent.WaitOne(Math.Min(1000 * (1 + quickExits), 10000));
                }
            } catch (Exception ex) {
                if (!stopping) Fail(ex);
            } finally {
                state = "Stopped";
            }
        }

        void ReadLogcat() {
            Process process = StartAdb(new string[] { "-s", reading, "logcat", "-v", "long" });
            if (process == null) return;
            entryOpen = false;
            pendingBlanks = 0;
            try {
                StreamReader reader = process.StandardOutput;
                char[] buffer = new char[8192];
                StringBuilder line = new StringBuilder();
                int count;
                while (!stopping && (count = reader.Read(buffer, 0, buffer.Length)) > 0) {
                    int start = 0;
                    for (int i = 0; i < count; i++) {
                        if (buffer[i] != '\n') continue;
                        line.Append(buffer, start, i - start);
                        HandleLine(line.ToString().TrimEnd('\r'));
                        line.Length = 0;
                        start = i + 1;
                    }
                    line.Append(buffer, start, count - start);
                }
                if (line.Length > 0 && !stopping) HandleLine(line.ToString().TrimEnd('\r'));
            } finally {
                EndEntry();
                Release(process);
            }
        }

        void HandleLine(string line) {
            Match match = line.StartsWith("[ ") ? HeaderPattern.Match(line) : Match.Empty;
            if (match.Success) {
                EndEntry();
                entryTime = ParseTime(match);
                entryPid = int.Parse(match.Groups[7].Value, CultureInfo.InvariantCulture);
                entryTid = int.Parse(match.Groups[8].Value, CultureInfo.InvariantCulture);
                entryLevel = match.Groups[9].Value;
                entryTag = match.Groups[10].Value.Trim();
                entryLines.Clear();
                entryOpen = true;
                entryEmitted = false;
                entrySkipped = false;
                pendingBlanks = 0;
                return;
            }
            if (!entryOpen) return;
            if (line.Length == 0) {
                if (!entryEmitted) Emit();
                pendingBlanks++;
                return;
            }
            if (!entryEmitted) {
                entryLines.Add(line);
                return;
            }
            if (line.StartsWith("--------- beginning of ") || line.StartsWith("--------- switch to ")) {
                pendingBlanks = 0;
                return;
            }
            if (!entrySkipped) {
                StringBuilder text = new StringBuilder();
                for (int i = 0; i < pendingBlanks; i++) text.Append(Environment.NewLine);
                text.Append(indent).Append(line);
                Write(text.ToString(), entryApp);
            }
            pendingBlanks = 0;
        }

        void EndEntry() {
            if (entryOpen && !entryEmitted) Emit();
            entryOpen = false;
            pendingBlanks = 0;
        }

        static DateTime ParseTime(Match match) {
            DateTime now = DateTime.Now;
            int month = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
            int year = month > now.Month + 1 ? now.Year - 1 : now.Year;
            string fraction = (match.Groups[6].Value + "000").Substring(0, 3);
            try {
                return new DateTime(year, month,
                    int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture),
                    int.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture),
                    int.Parse(match.Groups[4].Value, CultureInfo.InvariantCulture),
                    int.Parse(match.Groups[5].Value, CultureInfo.InvariantCulture),
                    int.Parse(fraction, CultureInfo.InvariantCulture));
            } catch (ArgumentOutOfRangeException) {
                return now;
            }
        }

        void Emit() {
            entryEmitted = true;
            if (filtering) {
                int order = entryTime.CompareTo(lastKey);
                if (order < 0 || (order == 0 && seenAtLastKey < lastKeyCount)) {
                    if (order == 0) seenAtLastKey++;
                    entrySkipped = true;
                    return;
                }
                filtering = false;
            }
            if (entryTime == lastKey) lastKeyCount++;
            else {
                lastKey = entryTime;
                lastKeyCount = 1;
            }
            string name = AppName(entryPid);
            entryApp = LogApp(name, apps);
            string prefix = string.Format(CultureInfo.InvariantCulture, "{0:yyyy-MM-dd HH:mm:ss.fff}  {1,5}-{2,-5}  {3,-23}  {4,-35}  {5}  ",
                entryTime, entryPid, entryTid, entryTag, name, entryLevel);
            indent = new string(' ', prefix.Length);
            if (entryLines.Count == 0) {
                Write(prefix.TrimEnd(), entryApp);
            } else {
                StringBuilder text = new StringBuilder(prefix).Append(entryLines[0]);
                for (int i = 1; i < entryLines.Count; i++) text.Append(Environment.NewLine).Append(indent).Append(entryLines[i]);
                Write(text.ToString(), entryApp);
            }
            Interlocked.Increment(ref entries);
            NoteAppEvent(name);
        }

        string AppName(int pid) {
            string name;
            if (pids.TryGetValue(pid, out name)) return name;
            if (missingPids.Contains(pid) || (DateTime.Now - pidsRefreshedAt).TotalSeconds < 2) return "";
            RefreshPids();
            if (pids.TryGetValue(pid, out name)) return name;
            missingPids.Add(pid);
            return "";
        }

        static bool IsStale(string name) {
            return name.StartsWith("zygote") || name.StartsWith("usap") || name == "<pre-initialized>";
        }

        Dictionary<int, string> RefreshPids() {
            pidsRefreshedAt = DateTime.Now;
            string text = RunAdb(new string[] { "-s", reading, "shell", "ps -A -o PID,NAME" }, 10000);
            if (text.Split('\n').Length <= 3) text = RunAdb(new string[] { "-s", reading, "shell", "ps" }, 10000);
            Dictionary<int, string> names = ParseProcessNames(text);
            foreach (KeyValuePair<int, string> pair in names) pids[pair.Key] = pair.Value;
            if (names.Count > 0) missingPids.Clear();
            pidsRefreshedAt = DateTime.Now;
            return names;
        }

        static Dictionary<int, string> ParseProcessNames(string text) {
            Dictionary<int, string> names = new Dictionary<int, string>();
            int pidColumn = -1;
            foreach (string raw in text.Split('\n')) {
                string[] parts = raw.Split(new char[] { ' ', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 2) continue;
                if (pidColumn < 0) {
                    pidColumn = Array.IndexOf(parts, "PID");
                    continue;
                }
                int pid;
                if (parts.Length <= pidColumn || !int.TryParse(parts[pidColumn], NumberStyles.None, CultureInfo.InvariantCulture, out pid)) continue;
                string name = parts[parts.Length - 1];
                if (name == "system_server") name = "system_process";
                if (IsStale(name)) continue;
                names[pid] = name;
            }
            return names;
        }
    }

    public class AppScan {
        public string[] Running;
        public string[] Opened;
        public string[] Installed;
    }
}
'@
}

function Get-DeviceLogName($Session) {
    $name = $Session.Name
    if (-not $name -and $Session.LastState -eq 'device') { $name = Get-DeviceProp $Session.Serial 'ro.product.model' }
    $safe = ConvertTo-SafeName $name
    if ($safe) { $safe } else { $Session.SafeSerial }
}

function Get-DeviceHardwareSerial($Session) {
    $id = $Session.Serial
    if ((Get-ConnectionType $id) -eq 'Wi-Fi') {
        $id = $script:WifiSerials[$Session.Serial]
        if (-not $id -and $Session.LastState -eq 'device') {
            $id = Get-DeviceProp $Session.Serial 'ro.serialno'
            if ($id) { $script:WifiSerials[$Session.Serial] = $id }
        }
    }
    $safe = ConvertTo-SafeName $id
    if ($safe) { $safe } else { $Session.SafeSerial }
}

function Start-DeviceLog($Session) {
    if ($Session.LogCapture -or $Session.UserClosed -or $script:Standby.ContainsKey($Session.Serial)) { return }
    Initialize-LogcatCapture
    $deviceName = Get-DeviceLogName $Session
    $hardwareSerial = Get-DeviceHardwareSerial $Session
    $folder = Join-Path $script:DeviceLogDir $deviceName
    $stem = 'logs_{0}_{1}_{2:yyyyMMdd_HHmmss}' -f $deviceName, $hardwareSerial, (Get-Date)
    $path = Join-Path $folder "$stem.txt"
    $suffix = 2
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $folder "${stem}_$suffix.txt"
        $suffix++
    }
    try {
        $capture = New-Object ScrcpyMonitor.LogcatCapture($script:Adb, $Session.Serial, $path, "$deviceName, serial $hardwareSerial, adb $($Session.Serial)")
        $capture.SetApps([string[]]@($script:LogApps))
        $capture.Start()
    } catch {
        Show-Notification "Could not start device logs for $($Session.Title): $($_.Exception.Message)" 'Error'
        return
    }
    $Session.LogCapture = $capture
    Write-Log "[$($Session.Serial)] Device logs started: $path"
    Show-Notification "Device logs started for $($Session.Title)."
}

function Complete-DeviceLogs($Captures, [switch]$Quiet) {
    $Captures = @($Captures | Where-Object { $_ })
    foreach ($capture in $Captures) { Invoke-Safely { $capture.RequestStop() } }
    foreach ($capture in $Captures) {
        Invoke-Safely {
            $capture.Stop()
            Write-Log "Device logs saved: $($capture.Path) ($($capture.Entries) entries)$(if ($capture.Failed) { "; stopped by an error: $($capture.Error)" })"
        }
    }
    if ($Quiet -or -not $Captures.Count) { return }
    $text = if ($Captures.Count -eq 1) { "Device logs saved: $($Captures[0].Path)" } else { "Device logs of $($Captures.Count) devices saved in $script:DeviceLogDir" }
    Show-Notification $text
}

function Stop-DeviceLog($Sessions, [switch]$Quiet) {
    $captures = @(foreach ($session in @($Sessions | Where-Object { $_ -and $_.LogCapture })) {
        $session.LogCapture
        $session.LogCapture = $null
    })
    Complete-DeviceLogs $captures -Quiet:$Quiet
}

function Stop-AllDeviceLogs {
    $captures = @($script:Sessions.Values | Where-Object { $_.LogCapture } | ForEach-Object { $_.LogCapture; $_.LogCapture = $null }) + @($script:LogHandovers.Values | ForEach-Object { $_.Capture })
    $script:LogHandovers.Clear()
    Complete-DeviceLogs $captures -Quiet
}

function Stop-AllLogs($Serials) {
    $Serials = @($Serials | Where-Object { $_ })
    $keys = @($script:LogHandovers.Keys | Where-Object { -not $Serials.Count -or $Serials -contains $_ })
    $captures = @($keys | ForEach-Object { $script:LogHandovers[$_].Capture })
    foreach ($key in $keys) { $script:LogHandovers.Remove($key) }
    $captures += @($script:Sessions.Values | Where-Object { $_.LogCapture -and (-not $Serials.Count -or $Serials -contains $_.Serial) } | ForEach-Object { $_.LogCapture; $_.LogCapture = $null })
    Complete-DeviceLogs $captures
}

function Move-DeviceLog($Session) {
    $capture = $Session.LogCapture
    if (-not $capture) { return }
    $Session.LogCapture = $null
    $serial = $Session.Serial
    $candidates = @()
    if ($Session.MovedTo -and $Session.MoveAddress) { $candidates += $Session.MoveAddress }
    if ($script:Standby.ContainsKey($serial)) { $candidates += $script:Standby[$serial] }
    $candidates += @($script:Standby.Keys | Where-Object { $script:Standby[$_] -eq $serial })
    foreach ($candidate in $candidates) {
        $target = $script:Sessions[$candidate]
        if (-not $target -or $target -eq $Session -or $target.UserClosed -or $target.LogCapture -or $script:ClosedSerials.ContainsKey($candidate)) { continue }
        $capture.Serial = $candidate
        $target.LogCapture = $capture
        Write-Log "[$serial] Device logs continue over $candidate."
        return
    }
    $key = if ($Session.MovedTo -and $Session.MoveAddress) { $Session.MoveAddress } else { $serial }
    $capture.Serial = $key
    $seconds = if ($Session.MovedTo) { 60 } else { 300 }
    $script:LogHandovers[$key] = @{ Capture = $capture; Until = (Get-Date).AddSeconds($seconds) }
    Write-Log "[$serial] Device logs wait up to $seconds seconds for $key."
}

function Update-DeviceLogs {
    $now = Get-Date
    foreach ($key in @($script:LogHandovers.Keys)) {
        $entry = $script:LogHandovers[$key]
        $session = $script:Sessions[$key]
        if ($session -and -not $session.UserClosed -and -not $session.LogCapture) {
            $script:LogHandovers.Remove($key)
            $session.LogCapture = $entry.Capture
            Write-Log "[$key] Device logs resumed."
        } elseif ($now -ge $entry.Until -or $entry.Capture.Failed) {
            $script:LogHandovers.Remove($key)
            Write-Log "[$key] The device did not come back; saving its device logs."
            Complete-DeviceLogs @($entry.Capture)
        }
    }
    foreach ($session in @($script:Sessions.Values | Where-Object { $_.LogCapture })) {
        $capture = $session.LogCapture
        if ($capture.Failed) {
            $session.LogCapture = $null
            Complete-DeviceLogs @($capture) -Quiet
            Show-Notification "Device logs of $($session.Title) stopped: $($capture.Error). The logs up to that point were saved in $($capture.Path)." 'Error'
            continue
        }
        if (-not $script:Standby.ContainsKey($session.Serial)) { continue }
        $active = $script:Sessions[$script:Standby[$session.Serial]]
        if (-not $active -or $active.UserClosed -or $active.LogCapture) { continue }
        $capture.Serial = $active.Serial
        $active.LogCapture = $capture
        $session.LogCapture = $null
        Write-Log "[$($session.Serial)] Device logs continue over $($active.Serial)."
    }
}

function Format-Elapsed([TimeSpan]$Span) {
    if ($Span.Ticks -lt 0) { $Span = [TimeSpan]::Zero }
    $hours = [long][Math]::Floor($Span.TotalHours)
    '{0:00}:{1:00}:{2:00}' -f $hours, $Span.Minutes, $Span.Seconds
}

function Get-SessionLogText($Session) {
    $capture = $Session.LogCapture
    if (-not $capture) { return '' }
    $text = 'Logging {0} - {1}' -f (Format-Elapsed ((Get-Date) - $capture.StartedAt)), (Format-ScreenBytes $capture.Size)
    if ($capture.State -ne 'Logging') { $text += ' (waiting for device)' }
    $text
}

function Start-VersionScan {
    if ($script:VersionScan -or ((Get-Date) - $script:VersionScanAt).TotalSeconds -lt 30) { return }
    $serials = [string[]]@($script:Sessions.Values | Where-Object { $_.LastState -eq 'device' -and -not $script:Standby.ContainsKey($_.Serial) } | ForEach-Object { $_.Serial })
    if (-not $serials.Count) { return }
    Initialize-LogcatCapture
    $script:VersionScanAt = Get-Date
    $script:VersionScan = [ScrcpyMonitor.LogcatCapture]::ScanVersionsAsync($script:Adb, $serials)
}

function Complete-VersionScan {
    $task = $script:VersionScan
    if (-not $task -or -not $task.IsCompleted) { return }
    $script:VersionScan = $null
    if ($task.IsFaulted) {
        Write-Log "Reading PA and PIA versions failed: $($task.Exception.GetBaseException().Message)"
        return
    }
    foreach ($pair in @($task.Result.GetEnumerator())) {
        $text = [ScrcpyMonitor.LogcatCapture]::AppVersionText($pair.Value)
        $old = if ($script:AppVersions.ContainsKey($pair.Key)) { [ScrcpyMonitor.LogcatCapture]::AppVersionText($script:AppVersions[$pair.Key]) } else { $null }
        if ($text -ne $old) { Write-Log "[$($pair.Key)] App versions: $text" }
        $script:AppVersions[$pair.Key] = $pair.Value
        if ($script:Sessions.ContainsKey($pair.Key) -and $script:Sessions[$pair.Key].LogCapture) { $script:Sessions[$pair.Key].LogCapture.NoteVersions($pair.Value, $false) }
    }
}

function Test-VersionMismatch([string]$Package) {
    $found = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($session in @($script:Sessions.Values)) {
        if ($session.LastState -ne 'device' -or $script:Standby.ContainsKey($session.Serial) -or -not $script:AppVersions.ContainsKey($session.Serial)) { continue }
        $version = ''
        if ($script:AppVersions[$session.Serial].TryGetValue($Package, [ref]$version) -and $version) { [void]$found.Add($version) }
    }
    $found.Count -gt 1
}

function Open-DeviceLogFolder {
    [void](New-Item -ItemType Directory -Force -Path $script:DeviceLogDir)
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:DeviceLogDir`""
}

function Open-DeviceLog($Sessions) {
    foreach ($session in @($Sessions | Where-Object { $_ -and $_.LogCapture })) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$($session.LogCapture.Path)`""
    }
}

function Switch-DeviceLog($Sessions) {
    $open = @($Sessions | Where-Object { $_ -and -not $_.UserClosed -and -not $script:Standby.ContainsKey($_.Serial) })
    $toStart = @($open | Where-Object { -not $_.LogCapture })
    if ($toStart.Count) { foreach ($session in $toStart) { Start-DeviceLog $session } }
    else { Stop-DeviceLog $open }
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
        Invoke-Safely { Stop-AdbJobs }
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-PowerWatch $session } }
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-Recording $session } }
        Invoke-Safely { Stop-AllDeviceLogs }
        Invoke-Safely { Close-ScreenRecorder }
        if ('ScrcpyMonitor.SnipPicker' -as [type]) { Invoke-Safely { [ScrcpyMonitor.SnipPicker]::CancelOpen() } }
        Invoke-Safely { Close-SnipEditors }
        Invoke-Safely { Update-Stops 45000 }
        Invoke-Safely { Update-CombineHandovers -All }
        foreach ($session in @($script:Sessions.Values | Where-Object { $_.PendingAction })) {
            Invoke-Safely { Invoke-PendingAction $session }
        }
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
        if (-not $script:SessionEnding) { Invoke-Safely { Update-Combines 120000 } }
        Invoke-Safely { Stop-Combines }
        if (-not $script:SessionEnding) { Invoke-Safely { Update-Labels 120000 -Force } }
        Invoke-Safely { Stop-Labels }
    } finally {
        if ($script:ScreenKeys) { Invoke-Safely { $script:ScreenKeys.Dispose() } }
        if ($script:MenuKey) { Invoke-Safely { $script:MenuKey.Dispose() } }
        if ($script:SnipKey) { Invoke-Safely { $script:SnipKey.Dispose() } }
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
        if ($script:Panel) { $script:Panel.Dispose() }
        $script:AppContext.ExitThread()
    }
}

function Save-RecordingsForSessionEnd([System.Windows.Forms.Form]$Form) {
    $script:SessionEnding = $true
    if (-not @($script:Sessions.Values | Where-Object { $_.Recording }).Count -and -not $script:Stops.Count -and -not $script:Merges.Count -and
        -not $script:Combines.Count -and -not $script:CombineHandovers.Count -and -not $script:Labels.Count -and
        -not ($script:ScreenRec -and $script:ScreenRec.Recording)) { return }
    Write-Log 'Windows session is ending; saving recordings.'
    $blocked = $false
    try { $blocked = [ScrcpyMonitor.Window]::ShutdownBlockReasonCreate($Form.Handle, 'Saving screen recordings...') } catch { }
    try {
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-Recording $session } }
        Invoke-Safely { Close-ScreenRecorder }
        Invoke-Safely { Update-Stops 20000 }
        Invoke-Safely { Update-CombineHandovers -All }
        Invoke-Safely { Update-Merges 30000 }
        Invoke-Safely { Stop-Combines }
        Invoke-Safely { Stop-Labels }
    } finally {
        if ($blocked) { [void][ScrcpyMonitor.Window]::ShutdownBlockReasonDestroy($Form.Handle) }
    }
}

function Request-Tick {
    $script:Timer.Stop()
    $script:Timer.Interval = 100
    $script:Timer.Start()
}

function Open-Window([string[]]$Serials) {
    foreach ($serial in $Serials) {
        $session = $script:Sessions[$serial]
        if (-not $session -or -not $session.UserClosed) { continue }
        $session.UserClosed = $false
        $session.DisplayFailures = 0
        $session.NextDisplayAttempt = Get-Date
        if ($session.Disconnected) {
            $session.Disconnected = $false
            $session.PendingAction = $null
            $session.MovedTo = $null
            $session.GoneSince = $null
            $session.MissingSince = $null
            $session.RestartingAt = $null
            $session.PoweringOff = $false
            $session.NextConnect = Get-Date
            Write-Log "[$serial] Reconnecting."
        } else {
            Write-Log "[$serial] Reopening scrcpy window."
        }
    }
    Request-Tick
}

function Confirm-StopRecording($Sessions, [string]$Action) {
    if (-not @($Sessions | Where-Object { $_.Recording }).Count) { return $true }
    $text = "$Action $(($Sessions | ForEach-Object { $_.Title }) -join ', ')?`n`nThe recording in progress is stopped and saved."
    (Show-Message $text 'YesNo' 'Question') -eq [System.Windows.Forms.DialogResult]::Yes
}

function Stop-Display($Session) {
    if (-not $Session.Display) { return }
    try {
        if (-not $Session.Display.HasExited -and -not $Session.ScrcpyPid) { [void](Test-WindowShown $Session) }
        if (-not $Session.Display.HasExited -and $Session.ScrcpyPid) {
            $scrcpy = [System.Diagnostics.Process]::GetProcessById($Session.ScrcpyPid)
            try { if ($scrcpy.ProcessName -eq 'scrcpy') { $scrcpy.Kill() } } finally { $scrcpy.Dispose() }
        }
    } catch { }
    try { if (-not $Session.Display.HasExited) { $Session.Display.Kill() } } catch { }
    $Session.Display.Dispose()
    $Session.Display = $null
    if ($Session.WindowShown) { Request-Arrange }
    $Session.WindowShown = $false
    $Session.NaturalSize = 0
    $Session.ScrcpyPid = 0
}

function Close-Session($Session, [string]$Action) {
    $Session.Disconnected = $true
    $Session.UserClosed = $true
    $Session.PendingAction = $Action
    Stop-Recording $Session
    if (-not $Session.MovedTo) { Stop-DeviceLog @($Session) }
    Stop-PowerWatch $Session
    if ($Session.Connector) {
        if (-not $Session.Connector.HasExited) { $Session.Connector.Kill() }
        $Session.Connector.Dispose()
        $Session.Connector = $null
    }
    Stop-Display $Session
}

function Update-UsbPriority($Devices) {
    $script:Standby.Clear()
    if ($Serial.Count) { return }
    $known = @(@($Devices.Keys) + @($script:Sessions.Keys) | Select-Object -Unique)
    if (-not @($known | Where-Object { (Get-ConnectionType $_) -eq 'USB' }).Count) { return }
    foreach ($address in @($known | Where-Object { (Get-ConnectionType $_) -eq 'Wi-Fi' })) {
        if (-not $script:WifiSerials.ContainsKey($address)) {
            if ($Devices[$address] -ne 'device') { continue }
            $script:WifiSerials[$address] = Get-DeviceProp $address 'ro.serialno'
        }
        $usbSerial = $script:WifiSerials[$address]
        if (-not $usbSerial -or $script:MovedUsb.ContainsKey($usbSerial)) { continue }
        if ($script:ClosedSerials.ContainsKey($usbSerial) -and -not $script:ClosedSerials.ContainsKey($address)) {
            Write-Log "[$address] Same device as the closed $usbSerial; hiding it too."
            $script:ClosedSerials[$address] = $false
            if ($script:Sessions.ContainsKey($address)) { Remove-Session $script:Sessions[$address] }
            continue
        }
        $usbSession = $script:Sessions[$usbSerial]
        $wifi = $script:Sessions[$address]
        $usbOnline = $Devices[$usbSerial] -eq 'device'
        if (-not $usbOnline -and -not ($usbSession -and -not $usbSession.UserClosed)) { continue }
        if (($wifi -and ($wifi.MovedTo -or $wifi.UserClosed)) -or ($usbSession -and $usbSession.MovedTo)) { continue }
        $usbPreferred = $usbOnline -or $Devices[$address] -ne 'device' -or $usbSession.Recording -or -not $usbSession.MissingSince -or ((Get-Date) - $usbSession.MissingSince).TotalSeconds -lt 30
        $wifiRecording = $wifi -and $wifi.Recording
        if ($wifiRecording -and $usbOnline -and $Devices[$address] -ne 'device' -and $wifi.MissingSince -and ((Get-Date) - $wifi.MissingSince).TotalSeconds -ge 30) {
            Write-Log "[$address] Missing for 30 seconds; continuing the recording over USB ($usbSerial)."
            if ($usbSession -and $wifi.CombineMember) {
                $wifi.CombineMember.Open++
                [void]$script:CombineHandovers.Add([pscustomobject]@{ Session = $usbSession; Member = $wifi.CombineMember; At = Get-Date })
            }
            Stop-Recording $wifi
            if ($usbSession) { $usbSession.RecordPending = $true }
            $wifiRecording = $false
        }
        if ($usbPreferred -and -not $wifiRecording) { $script:Standby[$address] = $usbSerial }
        elseif (-not ($usbSession -and ($usbSession.UserClosed -or $usbSession.Recording))) { $script:Standby[$usbSerial] = $address }
    }
}

function Invoke-PendingAction($Session) {
    $action = $Session.PendingAction
    $Session.PendingAction = $null
    $serial = $Session.Serial
    switch ($action) {
        'disconnect' {
            Write-Log "[$serial] adb disconnect: $((Invoke-Adb @('disconnect', $serial) 5000).Trim())"
        }
        'usb' {
            $output = (Invoke-Adb @('-s', $serial, 'usb') 5000).Trim()
            Write-Log "[$serial] adb usb: $output"
            if ($output -notmatch 'restarting in USB mode') { Undo-Move $Session "adb usb failed ($output)"; return }
            [void](Invoke-Adb @('disconnect', $serial) 5000)
            Remove-KnownWifi $serial
            $script:ClosedSerials.Remove($Session.MoveAddress)
            $usbSession = $script:Sessions[$Session.MoveAddress]
            if ($usbSession -and $usbSession.UserClosed) { Open-Window @($usbSession.Serial) }
            $Session.MoveDeadline = (Get-Date).AddSeconds(30)
        }
        'tcpip' {
            $output = (Invoke-Adb @('-s', $serial, 'tcpip', '5555') 5000).Trim()
            Write-Log "[$serial] adb tcpip 5555: $output"
            if ($output -notmatch 'restarting in TCP mode') { Undo-Move $Session "adb tcpip failed ($output)"; return }
            $script:DelayedConnects[$Session.MoveAddress] = (Get-Date).AddSeconds(3)
            $Session.MoveDeadline = (Get-Date).AddSeconds(30)
        }
    }
}

function Remove-Session($Session) {
    Move-DeviceLog $Session
    Close-Session $Session $null
    $script:Sessions.Remove($Session.Serial)
    [void]$script:RemovedSerials.Add($Session.Serial)
    if ($script:PanelList -and -not $script:PanelList.IsDisposed) { $script:PanelList.Items.RemoveByKey($Session.Serial) }
}

function Remove-Device($Session, [switch]$UserClosed) {
    $serial = $Session.Serial
    $partners = @()
    if ($UserClosed) {
        $partners = @($script:Standby.Keys | Where-Object { $script:Standby[$_] -eq $serial }) + @($script:Standby[$serial] | Where-Object { $_ })
        foreach ($closed in @($serial) + $partners) { $script:ClosedSerials[$closed] = $false }
        Stop-DeviceLog (@($Session) + @($partners | ForEach-Object { $script:Sessions[$_] }))
    }
    Remove-Session $Session
    foreach ($partner in $partners) {
        if ($script:Sessions.ContainsKey($partner)) { Remove-Session $script:Sessions[$partner] }
    }
}

function Close-Device([string[]]$Serials) {
    $sessions = @($Serials | ForEach-Object { $script:Sessions[$_] } | Where-Object { $_ -and -not $_.MovedTo })
    if (-not $sessions.Count) { return }
    $affected = @($sessions) + @(foreach ($session in $sessions) {
        $id = $session.Serial
        foreach ($partner in @($script:Standby.Keys | Where-Object { $script:Standby[$_] -eq $id }) + @($script:Standby[$id] | Where-Object { $_ })) {
            if ($script:Sessions.ContainsKey($partner)) { $script:Sessions[$partner] }
        }
    })
    if (-not (Confirm-StopRecording $affected 'Stop and close')) { return }
    foreach ($session in $sessions) {
        if (-not $script:Sessions.ContainsKey($session.Serial)) { continue }
        Write-Log "[$($session.Serial)] Stopped and closed; removed from the list."
        Remove-Device $session -UserClosed
    }
    Request-Tick
}

function Invoke-Refresh {
    if ($script:ClosedSerials.Count) {
        Write-Log "Refresh: showing closed devices again ($(@($script:ClosedSerials.Keys) -join ', '))."
        $script:ClosedSerials.Clear()
        $script:ClosedByUser = $false
    }
    Start-Scan
    Request-Tick
}

function Stop-PowerWatch($Session) {
    if (-not $Session.PowerWatch) { return }
    try { if (-not $Session.PowerWatch.Process.HasExited) { $Session.PowerWatch.Process.Kill() } } catch { }
    Close-RedirectedProcess $Session.PowerWatch.Process
    $Session.PowerWatch = $null
}

function Update-PowerWatch($Session, [string]$State, [datetime]$Now) {
    if ($Session.PowerWatch) {
        if (-not $Session.PowerWatch.Process.HasExited) { return }
        $output = ''
        if ($Session.PowerWatch.Output.Wait(1000)) { $output = $Session.PowerWatch.Output.Result.Trim() }
        Close-RedirectedProcess $Session.PowerWatch.Process
        $Session.PowerWatch = $null
        $Session.NextPowerWatch = $Now.AddSeconds(5)
        if ($output -match '^(.*)/([^/]*)$') {
            $requested = $Matches[1]
            $powerctl = $Matches[2]
            if ($requested -like '1*' -or $powerctl -like 'reboot*') {
                $Session.RestartingAt = $Now
                Write-Log "[$($Session.Serial)] Device is restarting ($output)."
            } elseif ($requested -like '0*' -or $powerctl -like 'shutdown*') {
                $Session.PoweringOff = $true
                Write-Log "[$($Session.Serial)] Device is shutting down ($output)."
            }
        }
    }
    if ($Session.RestartingAt -and $State -eq 'device' -and ($Now - $Session.RestartingAt).TotalSeconds -ge 120) { $Session.RestartingAt = $null }
    if ($State -ne 'device' -or $Session.RestartingAt -or $Session.PoweringOff -or $Now -lt $Session.NextPowerWatch) { return }
    try {
        $Session.PowerWatch = Start-AdbJob @('-s', $Session.Serial, 'shell', $script:PowerWatchCommand)
    } catch {
        $Session.NextPowerWatch = $Now.AddSeconds(30)
        Write-Log "[$($Session.Serial)] Could not watch for restarts: $($_.Exception.Message)"
    }
}

function Test-DeviceGone($Session, [datetime]$Now) {
    if ($Serial.Count) { return $false }
    if ($Session.Recording -or $Session.Stopping -or $Session.RecordPending) { return $false }
    if ($Session.PoweringOff) { return $true }
    if ($NoDiscovery -and (Get-ConnectionType $Session.Serial) -eq 'Wi-Fi') { return $false }
    if (-not $Session.GoneSince) { return $false }
    $restarting = $Session.RestartingAt
    $partner = $script:Standby[$Session.Serial]
    if ($partner -and $script:Sessions.ContainsKey($partner) -and $script:Sessions[$partner].RestartingAt) { $restarting = $script:Sessions[$partner].RestartingAt }
    if ($restarting) { return ($Now - $restarting).TotalMinutes -ge 5 }
    ($Now - $Session.GoneSince).TotalSeconds -ge 30
}

function Update-Moves($Devices) {
    foreach ($session in @($script:Sessions.Values | Where-Object { $_.MovedTo -and -not $_.PendingAction })) {
        $target = $session.MoveAddress
        if ($Devices[$target] -eq 'device') {
            Write-Log "[$($session.Serial)] Switched to $($session.MovedTo) ($target)."
            if ($session.MovedTo -eq 'Wi-Fi') {
                $script:MovedUsb[$session.Serial] = $target
                Add-KnownWifi $target
            }
            Remove-Session $session
            Show-Notification "$($session.Title) switched to $($session.MovedTo) ($target)."
        } elseif ((Get-Date) -ge $session.MoveDeadline) {
            Undo-Move $session "the device did not appear over $($session.MovedTo) within 30 seconds"
        }
    }
}

function Undo-Move($Session, [string]$Reason) {
    $to = $Session.MovedTo
    $target = $Session.MoveAddress
    Write-Log "[$($Session.Serial)] Switch to $to failed: $Reason"
    if ($to -eq 'Wi-Fi' -and $target) {
        $script:DelayedConnects.Remove($target)
        $wifi = $script:Sessions[$target]
        if ($wifi) { Remove-Session $wifi }
        [void](Invoke-Adb @('disconnect', $target) 5000)
    }
    Open-Window @($Session.Serial)
    Show-Notification "Could not switch $($Session.Title) to ${to}: $Reason. Restored the $($Session.Connection) connection." 'Warning'
}

function Test-MovedAway([string]$DeviceSerial, $Devices) {
    $address = $script:MovedUsb[$DeviceSerial]
    if (-not $address) { return $false }
    $wifi = $script:Sessions[$address]
    if ($wifi) {
        $wifiLost = $Devices[$address] -ne 'device' -and $wifi.MissingSince -and ((Get-Date) - $wifi.MissingSince).TotalSeconds -ge 30 -and $Devices[$DeviceSerial] -eq 'device'
        if (-not $wifi.Disconnected -and -not $wifiLost) { return $true }
    }
    elseif ($Devices[$address] -eq 'device') { return $true }
    $script:MovedUsb.Remove($DeviceSerial)
    $false
}

function Get-WifiAddress([string]$DeviceSerial) {
    $interface = ''
    $candidates = @()
    foreach ($line in ((Invoke-Adb @('-s', $DeviceSerial, 'shell', 'ip', '-f', 'inet', 'addr', 'show') 5000) -split "`r?`n")) {
        if ($line -match '^\d+:\s+([^:@\s]+)') { $interface = $Matches[1]; continue }
        if ($line -notmatch '^\s+inet (\d+\.\d+\.\d+\.\d+)/') { continue }
        $ip = $Matches[1]
        if ($ip -like '127.*' -or $interface -match '^(lo|rmnet|dummy|tun|p2p|ccmni)') { continue }
        $candidates += [pscustomobject]@{ Interface = $interface; Ip = $ip }
    }
    $pick = @(@($candidates | Where-Object { $_.Interface -like 'wlan*' }) + @($candidates | Where-Object { $_.Interface -like 'eth*' }) + $candidates) | Select-Object -First 1
    if ($pick) { $pick.Ip } else { $null }
}

function Switch-Connection([string[]]$Serials) {
    $sessions = @($Serials | ForEach-Object { $script:Sessions[$_] } | Where-Object { $_ -and -not $_.Disconnected -and $_.LastState -eq 'device' -and $_.Connection -in @('Wi-Fi', 'USB') })
    $kinds = @($sessions | ForEach-Object { $_.Connection } | Select-Object -Unique)
    if ($kinds.Count -ne 1) { return }
    $target = if ($kinds[0] -eq 'Wi-Fi') { 'USB' } else { 'Wi-Fi' }
    $usbSerials = @{}
    $addresses = @{}
    $devices = Get-AdbDevices
    foreach ($session in @($sessions)) {
        if ($target -eq 'USB') {
            $usbSerial = Get-DeviceProp $session.Serial 'ro.serialno'
            if ($usbSerial -and $devices[$usbSerial] -eq 'device') { $usbSerials[$session.Serial] = $usbSerial; continue }
            [void](Show-Message "$($session.Title) is not connected over USB. Plug in its USB cable (and allow USB debugging) first, then try again." 'OK' 'Warning')
            $sessions = @($sessions | Where-Object { $_ -ne $session })
            continue
        }
        $ip = Get-WifiAddress $session.Serial
        if ($ip) { $addresses[$session.Serial] = "${ip}:5555"; continue }
        [void](Show-Message "$($session.Title) is not connected to a Wi-Fi network. Connect it to the same network as this PC and try again." 'OK' 'Warning')
        $sessions = @($sessions | Where-Object { $_ -ne $session })
    }
    if (-not $sessions.Count) { return }
    if (-not (Confirm-StopRecording $sessions "Switch to $target")) { return }
    foreach ($session in $sessions) {
        $session.MovedTo = $target
        if ($target -eq 'USB') {
            $usbSerial = $usbSerials[$session.Serial]
            $session.MoveAddress = $usbSerial
            $script:MovedUsb.Remove($usbSerial)
            if ($Serial.Count -and $Serial -notcontains $usbSerial) { $script:Serial = @($Serial) + $usbSerial }
            Write-Log "[$($session.Serial)] Switching to USB ($usbSerial)."
            Close-Session $session 'usb'
        } else {
            $usbSerial = $session.Serial
            $standby = @($script:Standby.Keys | Where-Object { $script:Standby[$_] -eq $usbSerial -and             (Get-ConnectionType $_) -eq 'Wi-Fi' -and $devices[$_] -eq 'device' }) | Select-Object -First 1
            if ($standby) {
                $session.MoveAddress = $standby
                Write-Log "[$usbSerial] Switching to Wi-Fi ($standby, already connected)."
                Close-Session $session $null
                $session.MoveDeadline = (Get-Date).AddSeconds(30)
                continue
            }
            $session.MoveAddress = $addresses[$session.Serial]
            Write-Log "[$($session.Serial)] Switching to Wi-Fi ($($session.MoveAddress))."
            Close-Session $session 'tcpip'
        }
    }
    Request-Tick
}

function Disconnect-Device([string[]]$Serials) {
    $sessions = @($Serials | ForEach-Object { $script:Sessions[$_] } | Where-Object { $_ -and $_.Connection -eq 'Wi-Fi' -and -not $_.Disconnected })
    if (-not $sessions.Count) { return }
    if (-not (Confirm-StopRecording $sessions 'Disconnect')) { return }
    foreach ($session in $sessions) {
        Write-Log "[$($session.Serial)] Disconnecting."
        Close-Session $session 'disconnect'
    }
    Request-Tick
}

function Connect-WifiDevice([string]$Address) {
    if ($Address -notmatch ':\d+$') { $Address += ':5555' }
    if ($Serial.Count -and $Serial -notcontains $Address) { $script:Serial = @($Serial) + $Address }
    $script:ClosedSerials.Remove($Address)
    $session = $script:Sessions[$Address]
    if ($session -and $session.UserClosed) { Open-Window @($Address); return }
    Write-Log "Connecting to $Address."
    Start-Connect $Address $true
    Request-Tick
}

function Show-ConnectDialog([string]$InitialAddress = '', [string]$InitialPort = '5555') {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Connect Wi-Fi device'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.Padding = New-Object System.Windows.Forms.Padding(10)
    if ($script:Icon) { $form.Icon = $script:Icon }
    $layout = New-Object System.Windows.Forms.FlowLayoutPanel
    $layout.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $layout.AutoSize = $true
    $layout.WrapContents = $false
    $form.Controls.Add($layout)
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(340, 0)
    $label.Text = "ADB over Wi-Fi must be enabled on the device (for example adb tcpip 5555).`n`nIP address:"
    $layout.Controls.Add($label)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Width = 340
    $box.Text = $InitialAddress
    $layout.Controls.Add($box)
    $portLabel = New-Object System.Windows.Forms.Label
    $portLabel.AutoSize = $true
    $portLabel.Text = 'Port:'
    $layout.Controls.Add($portLabel)
    $portBox = New-Object System.Windows.Forms.ComboBox
    $portBox.Width = 120
    $portBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    foreach ($port in (Get-ScanPorts)) { [void]$portBox.Items.Add([string]$port) }
    $portBox.Text = $InitialPort
    $layout.Controls.Add($portBox)
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $buttons.Width = 346
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $connect = New-Object System.Windows.Forms.Button
    $connect.Text = 'Connect'
    $connect.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttons.Controls.AddRange(@($cancel, $connect))
    $layout.Controls.Add($buttons)
    $form.AcceptButton = $connect
    $form.CancelButton = $cancel
    try {
        $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
        if ($owner) {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
            $result = $form.ShowDialog($owner)
        } else {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
            $form.TopMost = $true
            $result = $form.ShowDialog()
        }
        $address = $box.Text.Trim()
        $portText = $portBox.Text.Trim()
    } finally {
        $form.Dispose()
    }
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $address) { return }
    if ($address -match '^(.+):(\d{1,5})$') { $address = $Matches[1]; $portText = $Matches[2] }
    if ($address -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        [void](Show-Message "'$address' is not a valid address. Enter an IP address such as 192.168.1.20." 'OK' 'Warning')
        return
    }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [void](Show-Message "'$portText' is not a valid port. Enter a number from 1 to 65535, such as 5555." 'OK' 'Warning')
        return
    }
    Connect-WifiDevice "${address}:$port"
}

function Get-Setting([string]$Name) {
    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($settings.PSObject.Properties[$Name]) { return $settings.$Name }
    } catch { }
    return $null
}

function Set-Setting([string]$Name, $Value) {
    $settings = @{}
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    } catch { }
    $settings[$Name] = $Value
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SettingsPath))
    $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-SettingsRecordDir {
    $value = Get-Setting 'RecordDir'
    if ($value) { return [string]$value }
    return $null
}

function Set-AutoUpdateCheck([bool]$Enabled) {
    $script:AutoUpdateCheck = $Enabled
    if ($script:PanelAutoUpdate -and $script:PanelAutoUpdate.Checked -ne $Enabled) { $script:PanelAutoUpdate.Checked = $Enabled }
    Set-Setting 'AutoUpdateCheck' $Enabled
    Write-Log "Automatic update check turned $(if ($Enabled) { 'on' } else { 'off' })."
    if ($Enabled) { Start-UpdateCheck $false }
}

function Select-RecordFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $script:Prompts++
    try {
        $dialog.Description = 'Choose the folder where recordings are saved'
        if (Test-Path -LiteralPath $RecordDir) { $dialog.SelectedPath = $RecordDir }
        $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
        while ($true) {
            if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
            $free = Get-DiskFreeBytes $dialog.SelectedPath
            if ((Get-DiskLevel $free) -notin @('low', 'critical')) { break }
            $answer = Show-Message "Only $(Format-ScreenBytes $free) is free on the drive of:`n$($dialog.SelectedPath)`n`nRecording needs at least 500 MB and stops automatically below that. Use this folder anyway?" 'YesNo' 'Warning'
            if ($answer -eq 'Yes') { break }
        }
        $script:RecordDir = $dialog.SelectedPath
    } finally {
        $script:Prompts--
        $dialog.Dispose()
    }
    Set-Setting 'RecordDir' $RecordDir
    Write-Log "Recordings folder changed to $RecordDir"
    Update-Panel
    $true
}

function Select-DeviceLogFolder {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $script:Prompts++
    try {
        $dialog.Description = 'Choose the folder where device logs are saved'
        if (Test-Path -LiteralPath $script:DeviceLogDir) { $dialog.SelectedPath = $script:DeviceLogDir }
        $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
        $script:DeviceLogDir = $dialog.SelectedPath
    } finally {
        $script:Prompts--
        $dialog.Dispose()
    }
    Set-Setting 'DeviceLogDir' $script:DeviceLogDir
    Write-Log "Device logs folder changed to $script:DeviceLogDir (used by device logs started from now on)"
    Update-Panel
    $true
}

function ConvertTo-LogApps($Value) {
    $apps = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ([string]$item -split ',')) {
            $app = $part.Trim()
            if ($app) { [void]$apps.Add($app) }
        }
    }
    , [string[]]@($apps)
}

function Get-LogAppChoices($Running, $Opened, $Installed, $Chosen) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $result = New-Object 'System.Collections.Generic.List[string]'
    $all = @(@($Opened) + @($Running) + @($Installed) + @($Chosen))
    foreach ($app in $script:PaPackage, $script:PiaPackage) {
        if ($all -contains $app -and $seen.Add($app)) { $result.Add($app) }
    }
    foreach ($group in $Opened, $Running, $Installed, $Chosen) {
        $items = [string[]]@($group | Where-Object { $_ })
        [Array]::Sort($items, [StringComparer]::Ordinal)
        foreach ($item in $items) { if ($seen.Add($item)) { $result.Add($item) } }
    }
    , $result.ToArray()
}

function Set-LogApps($Apps) {
    $script:LogApps = ConvertTo-LogApps $Apps
    $captures = @($script:Sessions.Values | ForEach-Object { $_.LogCapture }) + @($script:LogHandovers.Values | ForEach-Object { $_.Capture })
    foreach ($capture in @($captures | Where-Object { $_ })) { $capture.SetApps($script:LogApps) }
    Set-Setting 'LogApps' $script:LogApps
    Write-Log "Apps for per-app logs: $(if ($script:LogApps.Count) { $script:LogApps -join ', ' } else { 'none' })"
}

function Select-LogApps {
    if ($script:AppsScan) { return }
    Initialize-LogcatCapture
    $serials = [string[]]@($script:Sessions.Values | Where-Object { $_.LastState -eq 'device' -and -not $script:Standby.ContainsKey($_.Serial) } | ForEach-Object { $_.Serial })
    $script:AppsScan = @{ Task = [ScrcpyMonitor.LogcatCapture]::ScanAppsAsync($script:Adb, $serials); Connected = $serials.Count -gt 0 }
    [System.Windows.Forms.Application]::UseWaitCursor = $true
}

function Complete-LogAppsScan {
    $scan = $script:AppsScan
    if (-not $scan -or -not $scan.Task.IsCompleted -or $script:ConnectPrompting -or $script:DiskPrompting -or $script:Prompts -gt 0) { return }
    if (@([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Modal }).Count) { return }
    $script:AppsScan = $null
    [System.Windows.Forms.Application]::UseWaitCursor = $false
    $running = @()
    $opened = @()
    $installed = @()
    if ($scan.Task.IsFaulted) {
        Write-Log "Listing running apps failed: $($scan.Task.Exception.GetBaseException().Message)"
    } else {
        $running = @($scan.Task.Result.Running)
        $opened = @($scan.Task.Result.Opened)
        $installed = @($scan.Task.Result.Installed)
    }
    $script:ConnectPrompting = $true
    try {
        $chosen = Show-LogAppsDialog $running $opened $installed @($script:LogApps) $scan.Connected
    } finally {
        $script:ConnectPrompting = $false
    }
    if ($chosen) { Set-LogApps $chosen.Apps }
}

function Show-LogAppsDialog($Running, $Opened, $Installed, $Chosen, [bool]$Connected) {
    $openSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($Opened | Where-Object { $_ }))
    $runningSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($Running | Where-Object { $_ }))
    $chosenSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@($Chosen | Where-Object { $_ }))
    $apps = Get-LogAppChoices $Running $Opened $Installed $Chosen
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Apps for per-app logs'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.AutoSize = $true
    $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $form.Padding = New-Object System.Windows.Forms.Padding(10)
    if ($script:Icon) { $form.Icon = $script:Icon }
    $layout = New-Object System.Windows.Forms.FlowLayoutPanel
    $layout.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $layout.AutoSize = $true
    $layout.WrapContents = $false
    $form.Controls.Add($layout)
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(460, 0)
    $label.Text = 'The full device log is always saved. Check the apps whose lines are also saved to their own file in a subfolder of the device log folder, like the Logcat package filter. PA and PIA are listed first, then the open, running and installed apps. Without a checked app, only the full device log is saved.'
    if (-not $Connected) { $label.Text += "`n`nNo device is connected, so only the apps chosen before are listed." }
    $layout.Controls.Add($label)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.CheckOnClick = $true
    $list.IntegralHeight = $false
    $list.Size = New-Object System.Drawing.Size(460, 320)
    foreach ($app in $apps) {
        $tag = if ($app -eq $script:PaPackage) { ' (PA)' } elseif ($app -eq $script:PiaPackage) { ' (PIA)' } else { '' }
        $suffix = if ($openSet.Contains($app)) { ' (open)' } elseif ($runningSet.Contains($app)) { '' } else { ' (not running)' }
        [void]$list.Items.Add("$app$tag$suffix", $chosenSet.Contains($app))
    }
    $layout.Controls.Add($list)
    $buttons = New-Object System.Windows.Forms.TableLayoutPanel
    $buttons.ColumnCount = 4
    $buttons.RowCount = 1
    $buttons.Size = New-Object System.Drawing.Size(466, 32)
    [void]$buttons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$buttons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$buttons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$buttons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $clear = New-Object System.Windows.Forms.Button
    $clear.Text = 'Clear all'
    $clear.add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) } }.GetNewClosure())
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttons.Controls.Add($clear, 0, 0)
    $buttons.Controls.Add($ok, 2, 0)
    $buttons.Controls.Add($cancel, 3, 0)
    $layout.Controls.Add($buttons)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    try {
        $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
        if ($owner) {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
            $result = $form.ShowDialog($owner)
        } else {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
            $form.TopMost = $true
            $result = $form.ShowDialog()
        }
        $checked = [string[]]@(for ($i = 0; $i -lt $apps.Count; $i++) { if ($list.GetItemChecked($i)) { $apps[$i] } })
    } finally {
        $form.Dispose()
    }
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    @{ Apps = $checked }
}

function Get-RepoUpdateConfig {
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $null }
    $git = $git.Source
    $url = (Invoke-Hidden $git @('-C', $RepoRoot, 'remote', 'get-url', 'origin') 5000).Trim()
    if ($url -notmatch '[:/]([^/:\s]+)/([^/\s]+?)(\.git)?/?$') { return $null }
    $repo = "$($Matches[1])/$($Matches[2])"
    $version = (Invoke-Hidden $git @('-C', $RepoRoot, 'describe', '--tags', '--first-parent', '--match', 'v[0-9]*', '--always', '--dirty') 5000).Trim()
    if (-not $version) { return $null }
    @{ Repo = $repo; Version = $version; Display = $version; Built = $null; Portable = $false; Git = $git }
}

function Test-ReleaseInRepo($Release) {
    $git = $script:UpdateConfig.Git
    foreach ($ref in @("refs/tags/$($Release.tag_name)", [string]$Release.target_commitish)) {
        if (-not $ref -or $ref -eq 'refs/tags/') { continue }
        $sha = (Invoke-Hidden $git @('-C', $RepoRoot, 'rev-parse', '-q', '--verify', "$ref^{commit}") 5000).Trim()
        if (-not $sha) { continue }
        $base = (Invoke-Hidden $git @('-C', $RepoRoot, 'merge-base', $sha, 'HEAD') 5000).Trim()
        return $base -eq $sha
    }
    $false
}

function Get-DisplayVersion([string]$Tag) {
    if ($Tag -match '^(?:qa-)?v?(\d+(?:\.\d+)+)(?:-(\d+)-g[0-9a-f]+)?(?:-dirty)?$') {
        $build = if ($Matches[2]) { $Matches[2] } else { '0' }
        return "$($Matches[1]).$build"
    }
    $Tag -replace '^qa-', ''
}

function Test-NewerVersion([string]$Tag, [string]$Current) {
    $latest = $null
    $installed = $null
    if (-not [version]::TryParse((Get-DisplayVersion $Tag), [ref]$latest) -or -not [version]::TryParse((Get-DisplayVersion $Current), [ref]$installed)) { return $true }
    $latest -gt $installed
}

function Complete-RepoUpdateCheck($Release, [bool]$Manual) {
    $current = $script:UpdateConfig.Display
    if (-not $Release -or -not $Release.PSObject.Properties['tag_name'] -or -not (Test-NewerVersion ([string]$Release.tag_name) $current) -or (Test-ReleaseInRepo $Release)) {
        Write-Log "Update check: $current is up to date."
        if ($Manual) { [void](Show-Message "You have the latest version ($current).") }
        return
    }
    $tag = [string]$Release.tag_name
    Write-Log "Update available: $tag (current: $current)"
    $display = Get-DisplayVersion $tag
    $script:UpdateStatus = "Update $display available"
    $text = "scrcpy monitor $display is available (you have $current).`n`nThis copy runs from a git checkout, so it is not updated automatically. Pull the latest changes and rebuild, or use the portable ZIP from the release page.`n`nOpen the release page?"
    if ((Show-Message $text 'YesNo' 'Question') -eq [System.Windows.Forms.DialogResult]::Yes) {
        $page = [string]$Release.html_url
        if ($page -notlike 'https://github.com/*') { $page = "https://github.com/$($script:UpdateConfig.Repo)/releases/latest" }
        Start-Process $page
    }
}

function Get-UpdateConfig {
    if (-not $portable) { return Get-RepoUpdateConfig }
    try {
        $config = Get-Content -LiteralPath (Join-Path $RepoRoot 'update.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($config.Repo -and $config.Version) {
            $built = $null
            if ($config.PSObject.Properties['Built']) {
                $parsed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$config.Built, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $built = $parsed }
            }
            return @{ Repo = [string]$config.Repo; Version = [string]$config.Version; Display = (Get-DisplayVersion ([string]$config.Version)); Built = $built; Portable = $true; Git = $null }
        }
    } catch { }
    $null
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
    $script:Prompts++
    try {
        if ($owner) { return [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Scrcpy Monitor', $Buttons, $Icon) }
        [System.Windows.Forms.MessageBox]::Show($Text, 'Scrcpy Monitor', $Buttons, $Icon)
    } finally {
        $script:Prompts--
    }
}

function Start-UpdateCheck([bool]$Manual) {
    if (-not $script:UpdateConfig -or $script:Updating) { return }
    if ($script:UpdateCheck) {
        if ($Manual) {
            $script:UpdateCheck.Manual = $true
            $script:UpdateStatus = 'Checking for updates...'
        }
        return
    }
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
    if ($script:Updating) {
        try { [void]$check.Shell.EndInvoke($check.Handle) } catch { } finally { $check.Shell.Dispose() }
        return
    }
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

    if (-not $script:UpdateConfig.Portable) { Complete-RepoUpdateCheck $release $check.Manual; return }
    $current = $script:UpdateConfig.Display
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
    if (-not $asset -or $release.tag_name -eq $script:UpdateConfig.Version -or -not $newer) {
        Write-Log "Update check: $($script:UpdateConfig.Version) is up to date."
        if ($check.Manual) { [void](Show-Message "You have the latest version ($current).") }
        return
    }

    $tag = [string]$release.tag_name
    $script:AvailableUpdate = @{ Tag = $tag; Url = [string]$asset.browser_download_url }
    Write-Log "Update available: $tag (current: $($script:UpdateConfig.Version))"
    $display = Get-DisplayVersion $tag
    $notes = if ($release.body) { [string]$release.body } else { '' }
    if ($notes.Length -gt 600) { $notes = $notes.Substring(0, 600) + '...' }
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $text = "scrcpy monitor $display is available (you have $current)."
    if ($notes) { $text += "`n`n$notes" }
    $text += "`n`nUpdate now? The monitor restarts"
    $text += if ($recording) { " and the $recording recording(s) in progress are stopped and saved." } else { '.' }
    if (Test-CombineActive) { $text += ' A combined recording that is not finished within 2 minutes is cancelled.' }
    if ((Show-Message $text 'YesNo' 'Question') -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Update
    } else {
        $script:UpdateStatus = "Update $display available"
    }
}

function Confirm-Update {
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $combining = Test-CombineActive
    if (-not $recording -and -not $combining) { return $true }
    $text = 'The monitor restarts to install the update'
    $text += if ($recording) { " and the $recording recording(s) in progress are stopped and saved." } else { '.' }
    if ($combining) { $text += ' A combined recording that is not finished within 2 minutes is cancelled.' }
    (Show-Message "$text`n`nInstall now?" 'YesNo' 'Question') -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-UpdateInstalled {
    $marker = Join-Path $script:StateDir 'updated.txt'
    if (-not (Test-Path -LiteralPath $marker)) { return }
    $target = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    if (-not $target -or $target.Trim() -ne $RepoRoot) { return }
    if ($script:UpdateConfig) { Show-Notification "Updated to scrcpy monitor $($script:UpdateConfig.Display)." }
}

function Start-Update {
    $update = $script:AvailableUpdate
    if ($script:Updating -or -not $update) { return }
    $updater = Join-Path $script:StateDir 'scrcpy-monitor-updater.ps1'
    Copy-Item -LiteralPath $script:ScriptPath -Destination $updater -Force
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $updater, '-ApplyUpdate', $update.Url, '-UpdateTarget', $RepoRoot)
    $script:Updater = Start-Process -FilePath $script:PowerShellExe -ArgumentList (ConvertTo-ArgumentString $arguments) -WindowStyle Hidden -PassThru
    $script:Updating = $true
    $script:UpdateStatus = "Downloading update $(Get-DisplayVersion $update.Tag)... the monitor restarts when it is ready."
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
    if ($Session.MovedTo) { return "Switching to $($Session.MovedTo)..." }
    if ($Session.Disconnected) { return 'Disconnected' }
    if ($Session.UserClosed) { return 'Window closed' }
    if ($Session.PoweringOff) { return $(if ($Session.LastState -eq 'device') { 'Shutting down' } else { 'Device turned off' }) }
    if ($Session.RestartingAt) { return 'Device restarting' }
    if ($script:Standby.ContainsKey($Session.Serial)) { return "Standby (using $(Get-ConnectionType $script:Standby[$Session.Serial]))" }
    if ($Session.LastState -eq 'unauthorized') { return 'Allow USB debugging on device' }
    if ($Session.LastState -ne 'device') {
        $state = if ($Session.LastState) { $Session.LastState } else { 'missing' }
        return "Waiting for device ($state)"
    }
    if ($Session.Display) { return $(if ($Session.WindowShown) { 'Mirroring' } else { 'Waiting for video' }) }
    'Opening window'
}

function Get-SessionRecordingText($Session) {
    if (-not $Session.Recording) { return $(if ($Session.Stopping) { 'Saving...' } else { '' }) }
    $text = 'REC {0}' -f (Format-Elapsed ((Get-Date) - $Session.RecordingStartedAt))
    if ($Session.CombineMember) { $text = "REC combined $($text.Substring(4))" }
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
    $standby = @($selected | Where-Object { $script:Standby.ContainsKey($_.Serial) })
    $active = @($selected | Where-Object { -not $script:Standby.ContainsKey($_.Serial) })
    $open = @($active | Where-Object { -not $_.UserClosed })
    $toStart = @($open | Where-Object { -not $_.Recording })
    $script:PanelToggle.Text = if ($toStart.Count -gt 0 -or $open.Count -eq 0) { 'Start recording' } else { 'Stop recording' }
    $script:PanelToggle.Enabled = $open.Count -gt 0
    $script:PanelCombine.Enabled = $open.Count -ge 2 -and -not @($open | Where-Object { $_.Recording -or $_.Stopping }).Count
    $script:PanelLogs.Text = if (@($open | Where-Object { -not $_.LogCapture }).Count -gt 0 -or $open.Count -eq 0) { 'Start device logs' } else { 'Stop device logs' }
    $script:PanelLogs.Enabled = $open.Count -gt 0
    $script:PanelOpenDeviceLog.Enabled = @($selected | Where-Object { $_.LogCapture }).Count -gt 0
    $closed = @($selected | Where-Object { $_.UserClosed })
    $openText = if ($closed.Count -and -not @($closed | Where-Object { -not $_.Disconnected }).Count) { 'Reconnect' } else { 'Open window' }
    if ($script:PanelOpen.Text -ne $openText) { $script:PanelOpen.Text = $openText }
    $script:PanelOpen.Enabled = $closed.Count -gt 0
    $script:PanelClose.Enabled = @($selected | Where-Object { -not $_.MovedTo }).Count -gt 0
    $script:PanelDisconnect.Enabled = @($selected | Where-Object { $_.Connection -eq 'Wi-Fi' -and -not $_.Disconnected }).Count -gt 0
    $kinds = @($selected | ForEach-Object { $_.Connection } | Select-Object -Unique)
    $switchText = if ($kinds.Count -eq 1 -and $kinds[0] -eq 'USB') { 'Switch to Wi-Fi' } else { 'Switch to USB' }
    if ($script:PanelSwitch.Text -ne $switchText) { $script:PanelSwitch.Text = $switchText }
    $script:PanelSwitch.Enabled = -not $standby.Count -and $kinds.Count -eq 1 -and $kinds[0] -in @('Wi-Fi', 'USB') -and @($selected | Where-Object { -not $_.Disconnected -and $_.LastState -eq 'device' }).Count -gt 0
    $script:PanelScanNow.Enabled = $script:ClosedSerials.Count -gt 0 -or -not ($NoDiscovery -or $Serial.Count -or $script:Discovery -or $script:Probe)
    $active = @(Get-TargetSessions @())
    $script:PanelStartAll.Enabled = @($active | Where-Object { -not $_.Recording }).Count -gt 0
    $script:PanelStopAll.Enabled = @($active | Where-Object { $_.Recording }).Count -gt 0
    $script:PanelLogsStartAll.Enabled = @($active | Where-Object { -not $_.LogCapture }).Count -gt 0
    $script:PanelLogsStopAll.Enabled = @($script:Sessions.Values | Where-Object { $_.LogCapture }).Count -gt 0 -or $script:LogHandovers.Count -gt 0
}

function Update-SortHeaders($List) {
    $sorter = $List.ListViewItemSorter
    foreach ($column in $List.Columns) {
        $text = [string]$column.Tag
        if ($column.Index -eq $sorter.Column) { $text += ' ' + [char]$(if ($sorter.Descending) { 0x25BC } else { 0x25B2 }) }
        if ($column.Text -ne $text) { $column.Text = $text }
    }
}

function Update-Panel {
    if (-not $script:Panel -or $script:Panel.IsDisposed -or -not $script:Panel.Visible) { return }
    $list = $script:PanelList
    $sortColumn = $list.ListViewItemSorter.Column
    $resort = $false
    $paMismatch = Test-VersionMismatch $script:PaPackage
    $piaMismatch = Test-VersionMismatch $script:PiaPackage
    $list.BeginUpdate()
    try {
        foreach ($session in @($script:Sessions.Values)) {
            $index = $list.Items.IndexOfKey($session.Serial)
            if ($index -lt 0) {
                $item = $list.Items.Add($session.Serial, $session.Title, -1)
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
            } else {
                $item = $list.Items[$index]
            }
            $texts = @($session.Title, $session.Connection, (Get-SessionStatus $session), (Get-SessionRecordingText $session), (Get-SessionLogText $session))
            for ($i = 0; $i -lt $texts.Count; $i++) {
                if ($item.SubItems[$i].Text -ne $texts[$i]) {
                    $item.SubItems[$i].Text = $texts[$i]
                    if ($i -eq $sortColumn -or $i -eq 0) { $resort = $true }
                }
            }
            $color = if ($session.Recording) { [System.Drawing.Color]::Firebrick } elseif ($session.UserClosed -or $script:Standby.ContainsKey($session.Serial)) { [System.Drawing.SystemColors]::GrayText } else { [System.Drawing.SystemColors]::WindowText }
            if ($item.ForeColor -ne $color) { $item.ForeColor = $color }
        }
        if ($resort) { $list.Sort() }
    } finally {
        $list.EndUpdate()
    }
    $free = Get-RecordFreeSpace
    $level = Get-DiskLevel $free
    $status = "Recordings: $RecordDir"
    if ($level -ne 'unknown') { $status += "  ($(Format-ScreenBytes $free) free$(if ($level -ne 'ok') { ' - low disk space' }))" }
    $statusColor = if ($level -eq 'low' -or $level -eq 'critical') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.SystemColors]::ControlText }
    $mismatched = @()
    if ($paMismatch) { $mismatched += 'PA' }
    if ($piaMismatch) { $mismatched += 'PIA' }
    if ($mismatched.Count) {
        $status = "$($mismatched -join ' and ') version mismatch between devices  |  $status"
        $statusColor = [System.Drawing.Color]::Firebrick
    }
    if ($script:PanelStatus.ForeColor -ne $statusColor) { $script:PanelStatus.ForeColor = $statusColor }
    $connecting = @($script:Connects | Where-Object { $_.Manual } | ForEach-Object { $_.Address })
    if ($connecting.Count) { $status = "Connecting to $($connecting -join ', ')...  $status" }
    if ($script:Merges.Count -gt 0) { $status = "Joining $($script:Merges.Count) recording(s)...  $status" }
    if ($script:Combines.Count -gt 0) { $status = "Combining $($script:Combines.Count) recording(s)...  $status" }
    if ($script:Labels.Count -gt 0) { $status = "Adding device name header to $($script:Labels.Count) recording(s)...  $status" }
    if ($script:UpdateStatus) { $status = "$($script:UpdateStatus)  |  $status" }
    if ($script:PanelStatus.Text -ne $status) { $script:PanelStatus.Text = $status }
    $scan = if ($NoDiscovery -or $Serial.Count) { 'Wi-Fi scan: off' } else { $script:DiscoveryStatus }
    if ($script:PanelScan.Text -ne $scan) { $script:PanelScan.Text = $scan }
    Update-PanelButtons
}

function Show-Panel {
    $script:PanelPending = $false
    if (-not $script:Panel -or $script:Panel.IsDisposed) { return }
    $script:Panel.Show()
    [void][ScrcpyMonitor.Window]::ShowWindow($script:Panel.Handle, 5)
    if ($script:Panel.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:Panel.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $script:Panel.Activate()
    Update-Panel
}

function Initialize-DesktopTools {
    if (-not ('ScrcpyMonitor.SnipEditor' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
namespace ScrcpyMonitor {
    using System;
    using System.Collections.Generic;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Drawing.Imaging;
    using System.IO;
    using System.Runtime.InteropServices;
    using System.Windows.Forms;

    public class MenuHotKey : NativeWindow, IDisposable {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public event EventHandler Pressed;
        public bool Registered { get; private set; }

        public MenuHotKey() {
            var parameters = new CreateParams();
            parameters.Parent = new IntPtr(-3);
            CreateHandle(parameters);
            Registered = RegisterHotKey(Handle, 1, 0x4003, 0x4D);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x312) {
                var handler = Pressed;
                if (handler != null) handler(this, EventArgs.Empty);
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            if (Registered) UnregisterHotKey(Handle, 1);
            Registered = false;
            DestroyHandle();
        }
    }

    public static class SnipNative {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }
        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        delegate bool WindowEnumProc(IntPtr hWnd, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] static extern bool GetPhysicalCursorPos(out POINT point);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowEnumProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW")] static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int size);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);

        public static IntPtr EnterPerMonitor() {
            try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; }
        }

        public static void Leave(IntPtr previous) {
            if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
        }

        public static float Scale(IntPtr hWnd) {
            try { uint dpi = GetDpiForWindow(hWnd); return dpi > 0 ? dpi / 96f : 1f; } catch (EntryPointNotFoundException) { return 1f; }
        }

        public static Point Cursor() {
            POINT point;
            if (GetPhysicalCursorPos(out point)) return new Point(point.X, point.Y);
            return System.Windows.Forms.Cursor.Position;
        }

        public static void Foreground(IntPtr hWnd) {
            IntPtr current = GetForegroundWindow();
            uint other = current == IntPtr.Zero ? 0 : GetWindowThreadProcessId(current, IntPtr.Zero);
            uint self = GetCurrentThreadId();
            if (other != 0 && other != self && AttachThreadInput(self, other, true)) {
                try { BringWindowToTop(hWnd); SetForegroundWindow(hWnd); } finally { AttachThreadInput(self, other, false); }
            } else {
                SetForegroundWindow(hWnd);
            }
        }

        public static Rectangle[] Screens() {
            var list = new List<Rectangle>();
            IntPtr previous = EnterPerMonitor();
            try {
                MonitorEnumProc proc = delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data) {
                    var info = new MONITORINFO();
                    info.Size = Marshal.SizeOf(typeof(MONITORINFO));
                    if (GetMonitorInfo(monitor, ref info)) list.Add(Rectangle.FromLTRB(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom));
                    return true;
                };
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
                GC.KeepAlive(proc);
            } finally {
                Leave(previous);
            }
            return list.ToArray();
        }

        public static Rectangle Union(Rectangle[] rects) {
            Rectangle all = Rectangle.Empty;
            foreach (var rect in rects) all = all.IsEmpty ? rect : Rectangle.Union(all, rect);
            return all;
        }

        static bool Cloaked(IntPtr hWnd) {
            int value;
            try { return DwmGetWindowAttribute(hWnd, 14, out value, 4) == 0 && value != 0; } catch (Exception) { return false; }
        }

        public static List<Rectangle> Windows() {
            var list = new List<Rectangle>();
            IntPtr previous = EnterPerMonitor();
            try {
                var name = new System.Text.StringBuilder(256);
                WindowEnumProc proc = delegate(IntPtr hWnd, IntPtr data) {
                    if (!IsWindowVisible(hWnd) || IsIconic(hWnd) || Cloaked(hWnd)) return true;
                    if ((GetWindowLong(hWnd, -20) & 0x20) != 0) return true;
                    name.Length = 0;
                    GetClassName(hWnd, name, name.Capacity);
                    string kind = name.ToString();
                    if (kind == "Progman" || kind == "WorkerW") return true;
                    if (GetWindowTextLength(hWnd) == 0 && kind != "Shell_TrayWnd" && kind != "Shell_SecondaryTrayWnd") return true;
                    RECT rect;
                    bool found;
                    try { found = DwmGetWindowAttribute(hWnd, 9, out rect, Marshal.SizeOf(typeof(RECT))) == 0; } catch (Exception) { found = false; rect = new RECT(); }
                    if (!found && !GetWindowRect(hWnd, out rect)) return true;
                    var bounds = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
                    if (bounds.Width >= 8 && bounds.Height >= 8) list.Add(bounds);
                    return true;
                };
                EnumWindows(proc, IntPtr.Zero);
                GC.KeepAlive(proc);
            } finally {
                Leave(previous);
            }
            return list;
        }

        public static Bitmap Capture(Rectangle area) {
            IntPtr previous = EnterPerMonitor();
            try {
                var bitmap = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb);
                try {
                    using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(area.Location, Point.Empty, area.Size);
                } catch {
                    bitmap.Dispose();
                    throw;
                }
                return bitmap;
            } finally {
                Leave(previous);
            }
        }
    }

    public static class SnipImage {
        public static Bitmap Crop(Bitmap source, Rectangle area) {
            area.Intersect(new Rectangle(Point.Empty, source.Size));
            if (area.Width < 1 || area.Height < 1) return null;
            var bitmap = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb);
            using (var graphics = Graphics.FromImage(bitmap)) {
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.DrawImage(source, new Rectangle(Point.Empty, area.Size), area, GraphicsUnit.Pixel);
            }
            return bitmap;
        }

        public static bool IsJpeg(string path) {
            string extension = (Path.GetExtension(path) ?? "").ToLowerInvariant();
            return extension == ".jpg" || extension == ".jpeg";
        }

        public static void Save(Image image, string path) {
            if (!IsJpeg(path)) {
                image.Save(path, ImageFormat.Png);
                return;
            }
            ImageCodecInfo codec = null;
            foreach (var info in ImageCodecInfo.GetImageEncoders()) if (info.FormatID == ImageFormat.Jpeg.Guid) codec = info;
            if (codec == null) {
                image.Save(path, ImageFormat.Jpeg);
                return;
            }
            using (var parameters = new EncoderParameters(1)) {
                parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 92L);
                image.Save(path, codec, parameters);
            }
        }

        static void SetClipboard(Image image) {
            var data = new DataObject();
            data.SetData(DataFormats.Bitmap, true, image);
            var png = new MemoryStream();
            image.Save(png, ImageFormat.Png);
            data.SetData("PNG", false, png);
            Clipboard.SetDataObject(data, true, 10, 100);
        }

        public static bool Copy(Image image) {
            try {
                if (System.Threading.Thread.CurrentThread.GetApartmentState() == System.Threading.ApartmentState.STA) {
                    SetClipboard(image);
                    return true;
                }
                bool copied = false;
                var thread = new System.Threading.Thread(delegate() {
                    try { SetClipboard(image); copied = true; } catch (Exception) { }
                });
                thread.SetApartmentState(System.Threading.ApartmentState.STA);
                thread.Start();
                thread.Join(5000);
                return copied;
            } catch (Exception) {
                return false;
            }
        }
    }

    public class SnipKey : NativeWindow, IDisposable {
        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr Hwnd; public int Message; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; }
        [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        public event EventHandler Pressed;
        HookProc proc;
        IntPtr hook;
        IntPtr target;
        System.Threading.Thread thread;
        uint threadId;
        bool down;
        bool passed;

        public SnipKey() {
            var parameters = new CreateParams();
            parameters.Parent = new IntPtr(-3);
            CreateHandle(parameters);
            target = Handle;
        }

        public bool Enabled { get { return thread != null; } }

        public bool Enable() {
            if (thread != null) return true;
            bool installed = false;
            using (var ready = new System.Threading.ManualResetEvent(false)) {
                var worker = new System.Threading.Thread(delegate() {
                    MSG msg;
                    threadId = GetCurrentThreadId();
                    PeekMessage(out msg, IntPtr.Zero, 0, 0, 0);
                    proc = Hook;
                    hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
                    installed = hook != IntPtr.Zero;
                    ready.Set();
                    if (!installed) return;
                    while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { }
                    UnhookWindowsHookEx(hook);
                    hook = IntPtr.Zero;
                });
                worker.IsBackground = true;
                worker.Name = "Snip hotkey";
                worker.Start();
                if (!ready.WaitOne(5000) || !installed) return false;
                thread = worker;
            }
            return true;
        }

        public void Disable() {
            if (thread == null) return;
            PostThreadMessage(threadId, 0x12, IntPtr.Zero, IntPtr.Zero);
            thread.Join(2000);
            thread = null;
            down = passed = false;
        }

        static bool Held(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }

        IntPtr Hook(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0 && Marshal.ReadInt32(lParam) == 0x2C) {
                int message = wParam.ToInt32();
                bool isDown = message == 0x100 || message == 0x104;
                bool isUp = message == 0x101 || message == 0x105;
                bool modified = Held(0x10) || Held(0x11) || Held(0x12) || Held(0x5B) || Held(0x5C);
                if (isDown) {
                    if (passed || modified) {
                        passed = true;
                    } else {
                        if (!down) PostMessage(target, 0x8002, IntPtr.Zero, IntPtr.Zero);
                        down = true;
                        return new IntPtr(1);
                    }
                } else if (isUp) {
                    if (down) {
                        down = false;
                        return new IntPtr(1);
                    }
                    if (passed) {
                        passed = false;
                    } else if (!modified) {
                        PostMessage(target, 0x8002, IntPtr.Zero, IntPtr.Zero);
                        return new IntPtr(1);
                    }
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x8002) {
                var handler = Pressed;
                if (handler != null) handler(this, EventArgs.Empty);
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            Disable();
            DestroyHandle();
        }
    }

    public class SnipPicker : Form {
        static readonly string[] ButtonIds = { "rect", "window", "screen", "all", "cancel" };
        static SnipPicker open;
        Bitmap shot;
        Rectangle[] screens;
        List<Rectangle> windows;
        string mode;
        Point start;
        Rectangle selection;
        bool dragging;
        Rectangle hover;
        Rectangle[] buttons = new Rectangle[5];
        string[] labels;
        Rectangle bar;
        Rectangle hint;
        int hot = -1;
        float scale = 1f;
        Font font;
        Rectangle result = Rectangle.Empty;

        SnipPicker(Bitmap shot, Rectangle bounds, Rectangle[] screens, List<Rectangle> windows, string mode) {
            this.shot = shot;
            this.mode = mode == "window" || mode == "screen" ? mode : "rect";
            this.screens = new Rectangle[screens.Length];
            for (int i = 0; i < screens.Length; i++) { this.screens[i] = screens[i]; this.screens[i].Offset(-bounds.X, -bounds.Y); }
            this.windows = new List<Rectangle>();
            if (windows != null) {
                foreach (var window in windows) {
                    var local = window;
                    local.Offset(-bounds.X, -bounds.Y);
                    local.Intersect(new Rectangle(Point.Empty, bounds.Size));
                    if (local.Width > 0 && local.Height > 0) this.windows.Add(local);
                }
            }
            labels = new[] { "Rectangle", "Window", screens.Length > 1 ? "Screen" : "Full screen", screens.Length > 1 ? "All screens" : "", "Cancel" };
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            DoubleBuffered = true;
            Cursor = Cursors.Cross;
            KeyPreview = true;
            Text = "Snip";
        }

        public static void CancelOpen() {
            if (open != null && !open.IsDisposed) open.Close();
        }

        public static Bitmap Snip(string mode) {
            Rectangle[] screens;
            Rectangle bounds;
            List<Rectangle> windows = null;
            Bitmap shot;
            IntPtr previous = SnipNative.EnterPerMonitor();
            try {
                screens = SnipNative.Screens();
                bounds = SnipNative.Union(screens);
                if (bounds.Width < 1 || bounds.Height < 1) return null;
                if (mode != "all") windows = SnipNative.Windows();
                shot = SnipNative.Capture(bounds);
            } finally {
                SnipNative.Leave(previous);
            }
            if (mode == "all" || (mode == "screen" && screens.Length == 1)) return shot;
            using (shot) {
                Rectangle area;
                SnipPicker picker;
                previous = SnipNative.EnterPerMonitor();
                try {
                    picker = new SnipPicker(shot, bounds, screens, windows, mode);
                    picker.CreateControl();
                    picker.scale = SnipNative.Scale(picker.Handle);
                    picker.SetBounds(bounds.X, bounds.Y, bounds.Width, bounds.Height);
                    var cursor = SnipNative.Cursor();
                    picker.Arrange(new Point(cursor.X - bounds.X, cursor.Y - bounds.Y));
                } finally {
                    SnipNative.Leave(previous);
                }
                using (picker) {
                    open = picker;
                    try { picker.ShowDialog(); } finally { open = null; }
                    area = picker.result;
                }
                if (area.Width < 1 || area.Height < 1) return null;
                return SnipImage.Crop(shot, area);
            }
        }

        void Arrange(Point cursor) {
            Rectangle monitor = screens.Length > 0 ? screens[0] : ClientRectangle;
            foreach (var screen in screens) if (screen.Contains(cursor)) monitor = screen;
            font = new Font("Segoe UI", 14f * scale, GraphicsUnit.Pixel);
            int pad = (int)(12 * scale), height = (int)(font.Height + 16 * scale), x = 0;
            var widths = new int[labels.Length];
            for (int i = 0; i < labels.Length; i++) {
                widths[i] = labels[i].Length == 0 ? 0 : TextRenderer.MeasureText(labels[i], font).Width + 2 * pad;
                x += widths[i];
            }
            int left = monitor.Left + (monitor.Width - x) / 2, top = monitor.Top + (int)(16 * scale);
            for (int i = 0; i < labels.Length; i++) {
                buttons[i] = widths[i] == 0 ? Rectangle.Empty : new Rectangle(left, top, widths[i], height);
                left += widths[i];
            }
            bar = Rectangle.Union(buttons[0], buttons[4]);
            var hintSize = TextRenderer.MeasureText(HintText(), font);
            hint = new Rectangle(monitor.Left + (monitor.Width - hintSize.Width) / 2 - pad, bar.Bottom + (int)(8 * scale), hintSize.Width + 2 * pad, hintSize.Height + pad);
            if (mode != "rect") hover = Target(cursor);
        }

        string HintText() {
            if (mode == "window") return "Click a window to snip it. Esc cancels.";
            if (mode == "screen") return "Click a screen to snip it. Esc cancels.";
            return "Drag to snip an area. Esc cancels.";
        }

        protected override CreateParams CreateParams {
            get {
                var parameters = base.CreateParams;
                parameters.ExStyle |= 0x80;
                return parameters;
            }
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x02E0) return;
            base.WndProc(ref m);
        }

        protected override void OnShown(EventArgs e) {
            base.OnShown(e);
            SnipNative.Foreground(Handle);
            Activate();
        }

        protected override void Dispose(bool disposing) {
            if (disposing && font != null) font.Dispose();
            base.Dispose(disposing);
        }

        int ButtonAt(Point point) {
            for (int i = 0; i < buttons.Length; i++) if (buttons[i].Contains(point)) return i;
            return -1;
        }

        Rectangle Target(Point point) {
            if (mode == "window") foreach (var window in windows) if (window.Contains(point)) return window;
            foreach (var screen in screens) if (screen.Contains(point)) return screen;
            return Rectangle.Empty;
        }

        Rectangle Highlight() {
            if (mode == "rect") return dragging ? selection : Rectangle.Empty;
            return hover;
        }

        void Repaint(Rectangle area) {
            if (area.Width <= 0 || area.Height <= 0) return;
            area.Inflate((int)(4 * scale), (int)(4 * scale));
            Invalidate(area);
        }

        void Choose(int button) {
            string id = ButtonIds[button];
            if (id == "cancel") { Close(); return; }
            if (id == "all") { Finish(ClientRectangle); return; }
            if (screens.Length == 1 && id == "screen") { Finish(screens[0]); return; }
            mode = id;
            dragging = false;
            selection = Rectangle.Empty;
            hover = mode == "rect" ? Rectangle.Empty : Target(PointToClient(System.Windows.Forms.Cursor.Position));
            var hintSize = TextRenderer.MeasureText(HintText(), font);
            int pad = (int)(12 * scale);
            hint = new Rectangle(bar.Left + (bar.Width - hintSize.Width) / 2 - pad, hint.Top, hintSize.Width + 2 * pad, hintSize.Height + pad);
            Invalidate();
        }

        void Finish(Rectangle area) {
            result = area;
            Close();
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape) {
                if (dragging) {
                    dragging = false;
                    Repaint(Rectangle.Inflate(selection, (int)(200 * scale), (int)(60 * scale)));
                    Repaint(bar);
                    Repaint(hint);
                    selection = Rectangle.Empty;
                } else {
                    Close();
                }
            } else if (e.KeyCode == Keys.Enter && mode != "rect" && hover.Width > 0) {
                Finish(hover);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Right) { Close(); return; }
            if (e.Button != MouseButtons.Left) return;
            int button = ButtonAt(e.Location);
            if (button >= 0) { Choose(button); return; }
            if (mode != "rect") return;
            start = e.Location;
            selection = new Rectangle(start, Size.Empty);
            dragging = true;
            Repaint(bar);
            Repaint(hint);
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            int button = dragging ? -1 : ButtonAt(e.Location);
            if (button != hot) {
                hot = button;
                Repaint(bar);
            }
            if (dragging) {
                var previous = selection;
                selection = Rectangle.FromLTRB(Math.Min(start.X, e.X), Math.Min(start.Y, e.Y), Math.Max(start.X, e.X), Math.Max(start.Y, e.Y));
                var dirty = Rectangle.Union(previous, selection);
                dirty.Inflate((int)(200 * scale), (int)(60 * scale));
                Invalidate(dirty);
            } else if (mode != "rect") {
                var target = button >= 0 ? hover : Target(e.Location);
                if (target != hover) {
                    Repaint(hover);
                    hover = target;
                    Repaint(hover);
                }
            }
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            if (dragging) {
                dragging = false;
                if (selection.Width >= 4 && selection.Height >= 4) { Finish(selection); return; }
                Repaint(Rectangle.Inflate(selection, (int)(200 * scale), (int)(60 * scale)));
                Repaint(bar);
                Repaint(hint);
                selection = Rectangle.Empty;
                return;
            }
            if (mode != "rect" && hover.Width > 0 && ButtonAt(e.Location) < 0) Finish(hover);
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnPaint(PaintEventArgs e) {
            var graphics = e.Graphics;
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.DrawImage(shot, e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);
            graphics.CompositingMode = CompositingMode.SourceOver;
            var focus = Highlight();
            using (var dim = new SolidBrush(Color.FromArgb(110, 0, 0, 0))) {
                using (var region = new Region(e.ClipRectangle)) {
                    if (focus.Width > 0 && focus.Height > 0) region.Exclude(focus);
                    graphics.FillRegion(dim, region);
                }
            }
            if (focus.Width > 0 && focus.Height > 0) {
                using (var pen = new Pen(Color.FromArgb(230, 30, 30), Math.Max(1f, 2f * scale))) {
                    pen.Alignment = PenAlignment.Inset;
                    graphics.DrawRectangle(pen, focus);
                }
                if (mode == "rect") {
                    string label = string.Format("{0} \u00D7 {1}", focus.Width, focus.Height);
                    var labelSize = TextRenderer.MeasureText(label, font);
                    var labelRect = new Rectangle(focus.Left, Math.Max(0, focus.Top - labelSize.Height - 4), labelSize.Width + 8, labelSize.Height + 2);
                    using (var back = new SolidBrush(Color.FromArgb(200, 30, 30, 30))) graphics.FillRectangle(back, labelRect);
                    TextRenderer.DrawText(graphics, label, font, labelRect, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
            }
            if (dragging) return;
            using (var back = new SolidBrush(Color.FromArgb(235, 38, 38, 42))) {
                graphics.FillRectangle(back, bar);
                if (!(mode == "rect" && dragging)) {
                    graphics.FillRectangle(back, hint);
                    TextRenderer.DrawText(graphics, HintText(), font, hint, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
            }
            for (int i = 0; i < buttons.Length; i++) {
                if (buttons[i].Width == 0) continue;
                bool selected = ButtonIds[i] == mode;
                if (selected || i == hot) {
                    using (var brush = new SolidBrush(selected ? Color.FromArgb(30, 144, 255) : Color.FromArgb(70, 70, 78))) graphics.FillRectangle(brush, buttons[i]);
                }
                TextRenderer.DrawText(graphics, labels[i], font, buttons[i], Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }

    public class SnipEditor : Form {
        class Shape { public string Kind; public Color Color; public float Width; public List<PointF> Points; }
        class State { public Bitmap Image; public List<Shape> Shapes; }

        class Canvas : Control {
            public SnipEditor Editor;
            public Canvas() {
                SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
                Cursor = Cursors.Cross;
            }
            protected override void OnPaint(PaintEventArgs e) { Editor.PaintCanvas(e); }
            protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); Editor.CanvasDown(e); }
            protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); Editor.CanvasMove(e); }
            protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); Editor.CanvasUp(e); }
        }

        static readonly Color[] Colors = { Color.FromArgb(230, 30, 30), Color.FromArgb(255, 214, 0), Color.FromArgb(40, 180, 70), Color.FromArgb(30, 120, 255), Color.Black, Color.White };
        static readonly string[] ColorNames = { "Red", "Yellow", "Green", "Blue", "Black", "White" };
        static readonly string[] ToolIds = { "pen", "highlighter", "rect", "arrow", "eraser", "crop" };
        static readonly string[] ToolNames = { "Pen", "Highlighter", "Rectangle", "Arrow", "Eraser", "Crop" };
        static readonly Keys[] ToolKeys = { Keys.P, Keys.H, Keys.R, Keys.A, Keys.E, Keys.X };
        static readonly float[] Widths = { 2f, 4f, 8f };
        static readonly string[] WidthNames = { "Thin", "Medium", "Thick" };

        public event EventHandler NewSnip;
        public string RequestedMode = "rect";
        public bool Prompt = true;
        public string FilePath { get; private set; }

        Panel host;
        Canvas canvas;
        ToolStrip bar;
        ToolStripStatusLabel message;
        ToolStripStatusLabel sizeLabel;
        ToolStripButton[] toolButtons = new ToolStripButton[6];
        ToolStripDropDownButton colorButton;
        ToolStripDropDownButton widthButton;
        ToolStripButton undoButton;
        ToolStripButton redoButton;
        ToolStripButton fitButton;
        List<Bitmap> swatches = new List<Bitmap>();
        HashSet<Bitmap> images = new HashSet<Bitmap>();
        List<State> undo = new List<State>();
        List<State> redo = new List<State>();
        State current;
        State saved;
        Bitmap rendered;
        Bitmap view;
        string tool = "pen";
        Color penColor = Colors[0];
        Color highlightColor = Colors[1];
        int widthIndex = 1;
        float zoom = 1f;
        bool fit = true;
        Shape drawing;
        bool erasing;
        bool erased;
        bool cropping;
        PointF cropStart;
        PointF cropEnd;

        public SnipEditor(Bitmap image, string path, string status) {
            Text = "Snip";
            KeyPreview = true;
            StartPosition = FormStartPosition.Manual;
            MinimumSize = new Size(640, 400);
            Font = SystemFonts.MessageBoxFont;

            host = new Panel();
            host.Dock = DockStyle.Fill;
            host.AutoScroll = true;
            host.BackColor = Color.FromArgb(64, 64, 68);
            host.Resize += delegate { UpdateLayout(); };
            canvas = new Canvas();
            canvas.Editor = this;
            host.Controls.Add(canvas);

            var status_ = new StatusStrip();
            status_.SizingGrip = true;
            message = new ToolStripStatusLabel();
            message.Spring = true;
            message.TextAlign = ContentAlignment.MiddleLeft;
            sizeLabel = new ToolStripStatusLabel();
            status_.Items.Add(message);
            status_.Items.Add(sizeLabel);

            bar = new ToolStrip();
            bar.GripStyle = ToolStripGripStyle.Hidden;
            bar.ImageScalingSize = new Size(16, 16);
            var newSnip = new ToolStripSplitButton("New snip");
            newSnip.ToolTipText = "New snip (Ctrl+N)";
            newSnip.ButtonClick += delegate { RequestSnip("rect"); };
            AddMenu(newSnip.DropDownItems, "Rectangle", delegate { RequestSnip("rect"); });
            AddMenu(newSnip.DropDownItems, "Window", delegate { RequestSnip("window"); });
            AddMenu(newSnip.DropDownItems, "Screen", delegate { RequestSnip("screen"); });
            AddMenu(newSnip.DropDownItems, "All screens", delegate { RequestSnip("all"); });
            bar.Items.Add(newSnip);
            bar.Items.Add(new ToolStripSeparator());
            for (int i = 0; i < ToolIds.Length; i++) {
                string id = ToolIds[i];
                var button = new ToolStripButton(ToolNames[i]);
                button.ToolTipText = ToolNames[i] + " (" + ToolKeys[i] + ")";
                button.Click += delegate { SelectTool(id); };
                toolButtons[i] = button;
                bar.Items.Add(button);
            }
            bar.Items.Add(new ToolStripSeparator());
            colorButton = new ToolStripDropDownButton("Color");
            colorButton.DisplayStyle = ToolStripItemDisplayStyle.ImageAndText;
            for (int i = 0; i < Colors.Length; i++) {
                var chosen = Colors[i];
                var item = AddMenu(colorButton.DropDownItems, ColorNames[i], delegate { SetColor(chosen); });
                item.Image = Swatch(chosen);
            }
            bar.Items.Add(colorButton);
            widthButton = new ToolStripDropDownButton();
            for (int i = 0; i < Widths.Length; i++) {
                int index = i;
                AddMenu(widthButton.DropDownItems, WidthNames[i], delegate { widthIndex = index; UpdateState(); });
            }
            bar.Items.Add(widthButton);
            bar.Items.Add(new ToolStripSeparator());
            undoButton = AddButton("Undo", "Undo (Ctrl+Z)", delegate { Undo(); });
            redoButton = AddButton("Redo", "Redo (Ctrl+Y)", delegate { Redo(); });
            bar.Items.Add(new ToolStripSeparator());
            fitButton = AddButton("Fit to window", "Fit to window or show at 100% (Ctrl+0)", delegate { SetFit(!fit); });
            bar.Items.Add(new ToolStripSeparator());
            AddButton("Copy", "Copy to the clipboard (Ctrl+C)", delegate { CopyImage(); });
            AddButton("Save", "Save (Ctrl+S)", delegate { Save(); });
            AddButton("Save as...", "Save as PNG or JPEG (Ctrl+Shift+S)", delegate { SaveAs(); });

            Controls.Add(host);
            Controls.Add(status_);
            Controls.Add(bar);

            LoadImage(image, path, status);
            var area = Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
            int chromeWidth = Width - ClientSize.Width + 40, chromeHeight = Height - ClientSize.Height + bar.PreferredSize.Height + status_.PreferredSize.Height + 40;
            int width = Math.Max(MinimumSize.Width, Math.Min(area.Width * 9 / 10, image.Width + chromeWidth));
            int height = Math.Max(MinimumSize.Height, Math.Min(area.Height * 9 / 10, image.Height + chromeHeight));
            width = Math.Max(width, Math.Min(area.Width * 9 / 10, bar.PreferredSize.Width + Width - ClientSize.Width));
            SetBounds(area.Left + (area.Width - width) / 2, area.Top + (area.Height - height) / 2, width, height);
        }

        ToolStripMenuItem AddMenu(ToolStripItemCollection items, string text, EventHandler click) {
            var item = new ToolStripMenuItem(text);
            item.Click += click;
            items.Add(item);
            return item;
        }

        ToolStripButton AddButton(string text, string tip, EventHandler click) {
            var button = new ToolStripButton(text);
            button.ToolTipText = tip;
            button.Click += click;
            bar.Items.Add(button);
            return button;
        }

        Bitmap Swatch(Color color) {
            var bitmap = new Bitmap(16, 16);
            using (var graphics = Graphics.FromImage(bitmap)) {
                using (var brush = new SolidBrush(color)) graphics.FillRectangle(brush, 1, 1, 14, 14);
                graphics.DrawRectangle(Pens.Gray, 1, 1, 13, 13);
            }
            swatches.Add(bitmap);
            return bitmap;
        }

        public void LoadImage(Bitmap image, string path, string status) {
            drawing = null;
            erasing = cropping = false;
            undo.Clear();
            redo.Clear();
            DropCache();
            foreach (var old in images) old.Dispose();
            images.Clear();
            images.Add(image);
            current = saved = new State { Image = image, Shapes = new List<Shape>() };
            FilePath = path;
            fit = true;
            SetMessage(status);
            UpdateLayout();
            UpdateState();
        }

        public void ShowEditor() {
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            SnipNative.Foreground(Handle);
            Activate();
        }

        public bool Modified { get { return current != saved; } }

        void SetMessage(string text) { message.Text = text ?? ""; }

        void RequestSnip(string mode) {
            RequestedMode = mode;
            var handler = NewSnip;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        void SelectTool(string id) {
            if (cropping || drawing != null) return;
            tool = id;
            UpdateState();
        }

        void SetColor(Color color) {
            if (tool == "highlighter") highlightColor = color; else penColor = color;
            UpdateState();
        }

        void SetFit(bool value) {
            fit = value;
            if (!fit) zoom = 1f;
            UpdateLayout();
            UpdateState();
        }

        void UpdateState() {
            if (current == null) return;
            string name = Path.GetFileName(FilePath);
            Text = name + (Modified ? " *" : "") + " - Snip";
            for (int i = 0; i < ToolIds.Length; i++) toolButtons[i].Checked = ToolIds[i] == tool;
            bool colored = tool == "pen" || tool == "highlighter" || tool == "rect" || tool == "arrow";
            colorButton.Enabled = widthButton.Enabled = colored;
            var swatchColor = tool == "highlighter" ? highlightColor : penColor;
            var previous = colorButton.Image;
            colorButton.Image = Swatch(swatchColor);
            if (previous != null) { swatches.Remove((Bitmap)previous); previous.Dispose(); }
            widthButton.Text = WidthNames[widthIndex];
            undoButton.Enabled = undo.Count > 0;
            redoButton.Enabled = redo.Count > 0;
            fitButton.Checked = fit;
            sizeLabel.Text = string.Format("{0} \u00D7 {1}   {2}%", current.Image.Width, current.Image.Height, (int)Math.Round(zoom * 100));
        }

        void UpdateLayout() {
            if (current == null || canvas == null) return;
            var image = current.Image;
            var area = host.ClientSize;
            float previous = zoom;
            if (fit && area.Width > 0 && area.Height > 0) zoom = Math.Max(0.05f, Math.Min(1f, Math.Min((area.Width - 16f) / image.Width, (area.Height - 16f) / image.Height)));
            var size = new Size(Math.Max(1, (int)Math.Round(image.Width * zoom)), Math.Max(1, (int)Math.Round(image.Height * zoom)));
            if (zoom != previous || canvas.Size != size) DropView();
            canvas.Size = size;
            var scroll = host.AutoScrollPosition;
            canvas.Location = new Point(Math.Max(0, (area.Width - size.Width) / 2) + scroll.X, Math.Max(0, (area.Height - size.Height) / 2) + scroll.Y);
            canvas.Invalidate();
            UpdateState();
        }

        void DropView() {
            if (view != null) { view.Dispose(); view = null; }
        }

        void DropCache() {
            DropView();
            if (rendered != null) { rendered.Dispose(); rendered = null; }
        }

        void Changed() {
            DropCache();
            canvas.Invalidate();
            UpdateState();
        }

        void Push(State next) {
            undo.Add(current);
            if (undo.Count > 100) undo.RemoveAt(0);
            redo.Clear();
            current = next;
            Changed();
        }

        void Undo() {
            if (undo.Count == 0 || drawing != null || cropping) return;
            redo.Add(current);
            current = undo[undo.Count - 1];
            undo.RemoveAt(undo.Count - 1);
            Changed();
            UpdateLayout();
        }

        void Redo() {
            if (redo.Count == 0 || drawing != null || cropping) return;
            undo.Add(current);
            current = redo[redo.Count - 1];
            redo.RemoveAt(redo.Count - 1);
            Changed();
            UpdateLayout();
        }

        Bitmap Rendered() {
            if (rendered == null) {
                var image = current.Image;
                rendered = new Bitmap(image.Width, image.Height, PixelFormat.Format32bppRgb);
                using (var graphics = Graphics.FromImage(rendered)) {
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.DrawImage(image, new Rectangle(0, 0, image.Width, image.Height), new Rectangle(0, 0, image.Width, image.Height), GraphicsUnit.Pixel);
                    graphics.CompositingMode = CompositingMode.SourceOver;
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    foreach (var shape in current.Shapes) Draw(graphics, shape);
                }
            }
            return rendered;
        }

        Bitmap View() {
            var source = Rendered();
            if (zoom == 1f && canvas.Width == source.Width && canvas.Height == source.Height) return source;
            if (view == null) {
                view = new Bitmap(canvas.Width, canvas.Height, PixelFormat.Format32bppRgb);
                using (var graphics = Graphics.FromImage(view)) {
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    using (var attributes = new ImageAttributes()) {
                        attributes.SetWrapMode(WrapMode.TileFlipXY);
                        graphics.DrawImage(source, new Rectangle(0, 0, view.Width, view.Height), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
                    }
                }
            }
            return view;
        }

        public Bitmap Flatten() {
            return SnipImage.Crop(Rendered(), new Rectangle(0, 0, current.Image.Width, current.Image.Height));
        }

        static RectangleF Normalize(PointF a, PointF b) {
            return RectangleF.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
        }

        static void Draw(Graphics graphics, Shape shape) {
            var points = shape.Points;
            using (var pen = new Pen(shape.Color, shape.Width)) {
                pen.LineJoin = LineJoin.Round;
                pen.StartCap = pen.EndCap = shape.Kind == "highlighter" ? LineCap.Square : LineCap.Round;
                if (shape.Kind == "rect") {
                    pen.LineJoin = LineJoin.Miter;
                    var rect = Normalize(points[0], points[1]);
                    graphics.DrawRectangle(pen, rect.X, rect.Y, rect.Width, rect.Height);
                } else if (shape.Kind == "arrow") {
                    DrawArrow(graphics, pen, shape);
                } else if (points.Count == 1) {
                    using (var brush = new SolidBrush(shape.Color)) graphics.FillEllipse(brush, points[0].X - shape.Width / 2, points[0].Y - shape.Width / 2, shape.Width, shape.Width);
                } else {
                    graphics.DrawLines(pen, points.ToArray());
                }
            }
        }

        static void DrawArrow(Graphics graphics, Pen pen, Shape shape) {
            PointF a = shape.Points[0], b = shape.Points[1];
            float dx = b.X - a.X, dy = b.Y - a.Y, length = (float)Math.Sqrt(dx * dx + dy * dy);
            if (length < 1f) return;
            float head = Math.Min(length, Math.Max(12f, shape.Width * 4f)), ux = dx / length, uy = dy / length;
            var bottom = new PointF(b.X - ux * head, b.Y - uy * head);
            float half = head * 0.55f;
            var left = new PointF(bottom.X - uy * half, bottom.Y + ux * half);
            var right = new PointF(bottom.X + uy * half, bottom.Y - ux * half);
            if (length > head) graphics.DrawLine(pen, a, new PointF(b.X - ux * head * 0.7f, b.Y - uy * head * 0.7f));
            using (var brush = new SolidBrush(shape.Color)) graphics.FillPolygon(brush, new[] { b, left, right });
        }

        static float SegmentDistance(PointF p, PointF a, PointF b) {
            float dx = b.X - a.X, dy = b.Y - a.Y, length = dx * dx + dy * dy;
            float t = length <= 0f ? 0f : Math.Max(0f, Math.Min(1f, ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / length));
            float x = a.X + t * dx - p.X, y = a.Y + t * dy - p.Y;
            return (float)Math.Sqrt(x * x + y * y);
        }

        static bool Hit(Shape shape, PointF point, float tolerance) {
            float limit = shape.Width / 2f + tolerance;
            var points = shape.Points;
            if (shape.Kind == "rect") {
                var rect = Normalize(points[0], points[1]);
                var corners = new[] { new PointF(rect.Left, rect.Top), new PointF(rect.Right, rect.Top), new PointF(rect.Right, rect.Bottom), new PointF(rect.Left, rect.Bottom) };
                for (int i = 0; i < 4; i++) if (SegmentDistance(point, corners[i], corners[(i + 1) % 4]) <= limit) return true;
                return false;
            }
            if (points.Count == 1) return SegmentDistance(point, points[0], points[0]) <= limit;
            for (int i = 1; i < points.Count; i++) if (SegmentDistance(point, points[i - 1], points[i]) <= limit) return true;
            return false;
        }

        PointF ToImage(Point point) {
            return new PointF(point.X / zoom, point.Y / zoom);
        }

        Rectangle ToCanvas(RectangleF rect, float margin) {
            var result = Rectangle.FromLTRB((int)Math.Floor(rect.Left * zoom), (int)Math.Floor(rect.Top * zoom), (int)Math.Ceiling(rect.Right * zoom), (int)Math.Ceiling(rect.Bottom * zoom));
            int inflate = (int)Math.Ceiling(margin * zoom) + 4;
            result.Inflate(inflate, inflate);
            return result;
        }

        RectangleF ShapeBounds(Shape shape) {
            float left = float.MaxValue, top = float.MaxValue, right = float.MinValue, bottom = float.MinValue;
            foreach (var point in shape.Points) {
                left = Math.Min(left, point.X); top = Math.Min(top, point.Y);
                right = Math.Max(right, point.X); bottom = Math.Max(bottom, point.Y);
            }
            return RectangleF.FromLTRB(left, top, right, bottom);
        }

        void InvalidateShape(Shape shape) {
            float margin = shape.Width + (shape.Kind == "arrow" ? Math.Max(12f, shape.Width * 4f) : 0f);
            canvas.Invalidate(ToCanvas(ShapeBounds(shape), margin));
        }

        RectangleF CropRect() {
            var rect = Normalize(cropStart, cropEnd);
            rect.Intersect(new RectangleF(0, 0, current.Image.Width, current.Image.Height));
            return rect;
        }

        void CanvasDown(MouseEventArgs e) {
            if (e.Button != MouseButtons.Left || current == null) return;
            var point = ToImage(e.Location);
            if (tool == "eraser") {
                erasing = true;
                erased = false;
                EraseAt(point);
            } else if (tool == "crop") {
                cropping = true;
                cropStart = cropEnd = point;
                canvas.Invalidate();
            } else {
                drawing = new Shape();
                drawing.Kind = tool;
                drawing.Color = tool == "highlighter" ? Color.FromArgb(110, highlightColor) : penColor;
                drawing.Width = Widths[widthIndex] * (tool == "highlighter" ? 4f : 1f);
                drawing.Points = new List<PointF>();
                drawing.Points.Add(point);
                if (tool == "rect" || tool == "arrow") drawing.Points.Add(point);
                InvalidateShape(drawing);
            }
        }

        void CanvasMove(MouseEventArgs e) {
            if (current == null) return;
            var point = ToImage(e.Location);
            if (drawing != null) {
                var points = drawing.Points;
                if (drawing.Kind == "rect" || drawing.Kind == "arrow") {
                    InvalidateShape(drawing);
                    points[1] = point;
                    InvalidateShape(drawing);
                } else {
                    var last = points[points.Count - 1];
                    if (Math.Abs(point.X - last.X) * zoom < 1f && Math.Abs(point.Y - last.Y) * zoom < 1f) return;
                    points.Add(point);
                    float margin = drawing.Width;
                    canvas.Invalidate(ToCanvas(Normalize(last, point), margin));
                }
            } else if (erasing) {
                EraseAt(point);
            } else if (cropping) {
                cropEnd = point;
                canvas.Invalidate();
            }
        }

        void CanvasUp(MouseEventArgs e) {
            if (e.Button != MouseButtons.Left || current == null) return;
            if (drawing != null) {
                var shape = drawing;
                drawing = null;
                bool tiny = (shape.Kind == "rect" || shape.Kind == "arrow") && SegmentDistance(shape.Points[0], shape.Points[1], shape.Points[1]) * zoom < 3f;
                if (tiny) { InvalidateShape(shape); return; }
                var shapes = new List<Shape>(current.Shapes);
                shapes.Add(shape);
                Push(new State { Image = current.Image, Shapes = shapes });
            } else if (erasing) {
                erasing = false;
            } else if (cropping) {
                cropping = false;
                var rect = CropRect();
                var area = Rectangle.FromLTRB((int)Math.Round(rect.Left), (int)Math.Round(rect.Top), (int)Math.Round(rect.Right), (int)Math.Round(rect.Bottom));
                if (area.Width >= 4 && area.Height >= 4 && area.Size != current.Image.Size) ApplyCrop(area);
                else canvas.Invalidate();
            }
        }

        void EraseAt(PointF point) {
            var shapes = current.Shapes;
            for (int i = shapes.Count - 1; i >= 0; i--) {
                if (!Hit(shapes[i], point, 6f / zoom)) continue;
                var remaining = new List<Shape>(shapes);
                remaining.RemoveAt(i);
                var next = new State { Image = current.Image, Shapes = remaining };
                if (erased) {
                    current = next;
                    Changed();
                } else {
                    erased = true;
                    Push(next);
                }
                return;
            }
        }

        void ApplyCrop(Rectangle area) {
            var image = SnipImage.Crop(current.Image, area);
            if (image == null) { canvas.Invalidate(); return; }
            images.Add(image);
            var shapes = new List<Shape>();
            foreach (var shape in current.Shapes) {
                var moved = new Shape { Kind = shape.Kind, Color = shape.Color, Width = shape.Width, Points = new List<PointF>() };
                foreach (var point in shape.Points) moved.Points.Add(new PointF(point.X - area.X, point.Y - area.Y));
                shapes.Add(moved);
            }
            Push(new State { Image = image, Shapes = shapes });
            UpdateLayout();
        }

        void PaintCanvas(PaintEventArgs e) {
            if (current == null) return;
            var graphics = e.Graphics;
            graphics.DrawImage(View(), e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);
            if (drawing != null) {
                var state = graphics.Save();
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.ScaleTransform(zoom, zoom);
                Draw(graphics, drawing);
                graphics.Restore(state);
            }
            if (cropping) {
                var rect = CropRect();
                var area = new RectangleF(rect.X * zoom, rect.Y * zoom, rect.Width * zoom, rect.Height * zoom);
                using (var region = new Region(new Rectangle(Point.Empty, canvas.Size))) {
                    region.Exclude(area);
                    using (var dim = new SolidBrush(Color.FromArgb(120, 0, 0, 0))) graphics.FillRegion(dim, region);
                }
                using (var pen = new Pen(Color.White, 1f)) {
                    pen.DashStyle = DashStyle.Dash;
                    graphics.DrawRectangle(pen, area.X, area.Y, Math.Max(0f, area.Width - 1), Math.Max(0f, area.Height - 1));
                }
            }
        }

        public bool Save() {
            return SaveTo(FilePath);
        }

        bool SaveTo(string path) {
            try {
                var folder = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);
                using (var flat = Flatten()) SnipImage.Save(flat, path);
            } catch (Exception error) {
                MessageBox.Show(this, "Could not save the snip:\n" + error.Message, "Snip", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            FilePath = path;
            saved = current;
            SetMessage("Saved: " + path);
            UpdateState();
            return true;
        }

        void SaveAs() {
            using (var dialog = new SaveFileDialog()) {
                dialog.Title = "Save snip as";
                dialog.Filter = "PNG image (*.png)|*.png|JPEG image (*.jpg)|*.jpg";
                dialog.FilterIndex = SnipImage.IsJpeg(FilePath) ? 2 : 1;
                dialog.AddExtension = true;
                dialog.OverwritePrompt = true;
                try { dialog.InitialDirectory = Path.GetDirectoryName(FilePath); } catch (Exception) { }
                dialog.FileName = Path.GetFileNameWithoutExtension(FilePath);
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                string path = dialog.FileName;
                string extension = (Path.GetExtension(path) ?? "").ToLowerInvariant();
                if (extension != ".png" && extension != ".jpg" && extension != ".jpeg") path += dialog.FilterIndex == 2 ? ".jpg" : ".png";
                SaveTo(path);
            }
        }

        void CopyImage() {
            bool copied;
            using (var flat = Flatten()) copied = SnipImage.Copy(flat);
            SetMessage(copied ? "Copied to the clipboard." : "Could not copy to the clipboard; another application may be using it.");
        }

        public bool ConfirmDiscard() {
            if (!Modified) return true;
            if (!Visible) ShowEditor();
            var answer = MessageBox.Show(this, "Save the changes to " + Path.GetFileName(FilePath) + "?", "Snip", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (answer == DialogResult.Cancel) return false;
            return answer == DialogResult.No || Save();
        }

        protected override void OnFormClosing(FormClosingEventArgs e) {
            base.OnFormClosing(e);
            if (Prompt && e.CloseReason == CloseReason.UserClosing && !ConfirmDiscard()) e.Cancel = true;
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
            switch (keyData) {
                case Keys.Control | Keys.C: CopyImage(); return true;
                case Keys.Control | Keys.S: Save(); return true;
                case Keys.Control | Keys.Shift | Keys.S: SaveAs(); return true;
                case Keys.Control | Keys.Z: Undo(); return true;
                case Keys.Control | Keys.Y:
                case Keys.Control | Keys.Shift | Keys.Z: Redo(); return true;
                case Keys.Control | Keys.N: RequestSnip("rect"); return true;
                case Keys.Control | Keys.D0: SetFit(!fit); return true;
                case Keys.Escape:
                    if (cropping) { cropping = false; canvas.Invalidate(); return true; }
                    if (drawing != null) { InvalidateShape(drawing); drawing = null; return true; }
                    break;
            }
            for (int i = 0; i < ToolKeys.Length; i++) {
                if (keyData == ToolKeys[i]) { SelectTool(ToolIds[i]); return true; }
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void Dispose(bool disposing) {
            if (disposing) {
                DropCache();
                foreach (var image in images) image.Dispose();
                images.Clear();
                foreach (var swatch in swatches) swatch.Dispose();
                swatches.Clear();
            }
            base.Dispose(disposing);
        }
    }
}
'@
    }
}

function New-MenuHotKey {
    Initialize-DesktopTools
    $key = New-Object ScrcpyMonitor.MenuHotKey
    if (-not $key.Registered) {
        $key.Dispose()
        Write-Log 'Could not register Ctrl+Alt+M to show the tray menu; another application may be using it.'
        return $null
    }
    $key.add_Pressed({ Invoke-Safely { Show-TrayMenu } })
    return $key
}

function Show-TrayMenu {
    if (-not $script:Tray) { Show-Panel; return }
    $method = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance, NonPublic')
    if ($method) { [void]$method.Invoke($script:Tray, $null) }
    else { $script:Tray.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position) }
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

function New-PanelMenuItem([System.Windows.Forms.ToolStripMenuItem]$Parent, [string]$Text, [scriptblock]$OnClick) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Tag = $OnClick
    $item.add_Click({
        param($sender, $e)
        Invoke-Safely { & $sender.Tag; Update-TrayText; Update-Panel }
    })
    [void]$Parent.DropDownItems.Add($item)
    $item
}

function New-Panel {
    Add-Type -Namespace ScrcpyMonitor -Name Window -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool ShutdownBlockReasonCreate(System.IntPtr hWnd, string reason);
[DllImport("user32.dll")] public static extern bool ShutdownBlockReasonDestroy(System.IntPtr hWnd);
[DllImport("kernel32.dll")] public static extern bool SetProcessShutdownParameters(uint level, uint flags);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint processId);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr handler, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
'@
    [void][ScrcpyMonitor.Window]::SetProcessShutdownParameters(0x3FF, 0)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($script:UpdateConfig) { "Scrcpy Monitor $($script:UpdateConfig.Display)" } else { 'Scrcpy Monitor' }
    $form.Size = New-Object System.Drawing.Size(950, 380)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 260)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    if ($script:Icon) { $form.Icon = $script:Icon }

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.Sorting = [System.Windows.Forms.SortOrder]::Ascending
    if (-not ('ScrcpyMonitor.ListSorter' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
namespace ScrcpyMonitor {
    public class ListSorter : System.Collections.IComparer {
        public int Column;
        public bool Descending;
        static string Text(System.Windows.Forms.ListViewItem item, int column) {
            return column < item.SubItems.Count ? item.SubItems[column].Text : "";
        }
        public int Compare(object x, object y) {
            var a = (System.Windows.Forms.ListViewItem)x;
            var b = (System.Windows.Forms.ListViewItem)y;
            int result = string.Compare(Text(a, Column), Text(b, Column), System.StringComparison.CurrentCultureIgnoreCase);
            if (result == 0 && Column != 0) result = string.Compare(Text(a, 0), Text(b, 0), System.StringComparison.CurrentCultureIgnoreCase);
            return Descending ? -result : result;
        }
    }
}
'@
    }
    $list.ListViewItemSorter = New-Object ScrcpyMonitor.ListSorter
    $list.add_ColumnClick({
        param($sender, $e)
        Invoke-Safely {
            $sorter = $sender.ListViewItemSorter
            if ($sorter.Column -eq $e.Column) { $sorter.Descending = -not $sorter.Descending } else { $sorter.Column = $e.Column; $sorter.Descending = $false }
            Update-SortHeaders $sender
            $sender.Sort()
        }
    })
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    [void]$list.Columns.Add('Device', 250)
    [void]$list.Columns.Add('Connection', 85)
    [void]$list.Columns.Add('Status', 170)
    [void]$list.Columns.Add('Recording', 165)
    [void]$list.Columns.Add('Device logs', 230)
    foreach ($column in $list.Columns) { $column.Tag = $column.Text }
    Update-SortHeaders $list
    $list.add_SelectedIndexChanged({ Invoke-Safely { Update-PanelButtons } })
    $form.Controls.Add($list)

    $deviceButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $deviceButtons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $deviceButtons.AutoSize = $true
    $deviceButtons.WrapContents = $false
    $deviceButtons.Padding = New-Object System.Windows.Forms.Padding(4)
    $form.Controls.Add($deviceButtons)

    $menuBar = New-Object System.Windows.Forms.MenuStrip
    $menuBar.Dock = [System.Windows.Forms.DockStyle]::Top
    $form.Controls.Add($menuBar)
    $form.MainMenuStrip = $menuBar

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.SizingGrip = $false
    $statusStrip.ShowItemToolTips = $true
    $status = New-Object System.Windows.Forms.ToolStripStatusLabel
    $status.Spring = $true
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $status.ToolTipText = 'Click to change the recordings folder'
    $status.add_Click({ Invoke-Safely { [void](Select-RecordFolder) } })
    [void]$statusStrip.Items.Add($status)
    $scan = New-Object System.Windows.Forms.ToolStripStatusLabel
    $scan.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    [void]$statusStrip.Items.Add($scan)
    $script:PanelScan = $scan
    $form.Controls.Add($statusStrip)

    $script:PanelList = $list
    $script:PanelStatus = $status
    $script:PanelToggle = New-PanelButton $deviceButtons 'Start recording' {
        $selected = Get-SelectedSessions | Where-Object { -not $_.UserClosed }
        $toStart = @($selected | Where-Object { -not $_.Recording })
        if ($toStart.Count -gt 0) { if (Confirm-RecordSpace) { foreach ($s in $toStart) { Start-Recording $s } } }
        else { foreach ($s in $selected) { Stop-Recording $s } }
    }
    $script:PanelCombine = New-PanelButton $deviceButtons 'Record combined' {
        if (Confirm-RecordSpace) { Start-CombinedRecording @(Get-SelectedSessions | Where-Object { -not $_.UserClosed -and -not $script:Standby.ContainsKey($_.Serial) }) }
    }
    $script:PanelLogs = New-PanelButton $deviceButtons 'Start device logs' { Switch-DeviceLog @(Get-SelectedSessions) }
    $script:PanelOpen = New-PanelButton $deviceButtons 'Open window' { Open-Window @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelClose = New-PanelButton $deviceButtons 'Stop and close' { Close-Device @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelDisconnect = New-PanelButton $deviceButtons 'Disconnect' { Disconnect-Device @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelSwitch = New-PanelButton $deviceButtons 'Switch to USB' { Switch-Connection @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    [void](New-PanelButton $deviceButtons 'Connect Wi-Fi device...' { Show-ConnectDialog })
    $script:PanelScanNow = New-PanelButton $deviceButtons 'Refresh' { Invoke-Refresh }
    $list.add_DoubleClick({ Invoke-Safely { $script:PanelToggle.PerformClick() } })

    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&File'
    $recordingMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Recording'
    $logsMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Logs'
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Help'
    $windowMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Window'
    [void]$menuBar.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($fileMenu, $recordingMenu, $logsMenu, $windowMenu, $helpMenu))
    $script:PanelLogsStartAll = New-PanelMenuItem $logsMenu 'Start device logs on all devices' { foreach ($s in (Get-TargetSessions @())) { Start-DeviceLog $s } }
    $script:PanelLogsStopAll = New-PanelMenuItem $logsMenu 'Stop device logs on all devices' { Stop-AllLogs @() }
    [void]$logsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $script:PanelOpenDeviceLog = New-PanelMenuItem $logsMenu 'Open device log of selected device' { Open-DeviceLog @(Get-SelectedSessions) }
    [void](New-PanelMenuItem $logsMenu 'Open device logs folder' { Open-DeviceLogFolder })
    [void](New-PanelMenuItem $logsMenu 'Change device logs folder...' { [void](Select-DeviceLogFolder) })
    [void](New-PanelMenuItem $logsMenu 'Choose apps for per-app logs...' { Select-LogApps })
    [void](New-PanelMenuItem $windowMenu 'Arrange windows' { Invoke-ArrangeWindows })
    $script:PanelTrayMenuItem = New-PanelMenuItem $windowMenu 'Show tray menu' { [void]$script:Panel.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Invoke-Safely { Show-TrayMenu } }) }
    $script:PanelTrayMenuItem.Visible = $false
    [void](New-PanelMenuItem $fileMenu 'Open recordings folder' { Open-RecordFolder })
    [void](New-PanelMenuItem $fileMenu 'Change recordings folder...' { [void](Select-RecordFolder) })
    [void](New-PanelMenuItem $fileMenu 'Open log' { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$script:LogPath`"" })
    [void]$fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](New-PanelMenuItem $fileMenu 'Exit' { $script:ExitRequested = $true })
    $script:PanelStartAll = New-PanelMenuItem $recordingMenu 'Start all' { if (Confirm-RecordSpace) { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s } } }
    $script:PanelStopAll = New-PanelMenuItem $recordingMenu 'Stop all' { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s } }
    [void]$recordingMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-ScreenRecordMenu $recordingMenu.DropDownItems)
    [void](Add-SnipMenu $recordingMenu.DropDownItems)
    [void](New-PanelMenuItem $helpMenu 'User guide' { Show-Guide })
    [void]$helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    if ($script:UpdateConfig) {
        [void](New-PanelMenuItem $helpMenu 'Check for updates' { Start-UpdateCheck $true })
        $script:PanelAutoUpdate = New-PanelMenuItem $helpMenu 'Check for updates automatically' { Set-AutoUpdateCheck (-not $script:AutoUpdateCheck) }
        $script:PanelAutoUpdate.Checked = $script:AutoUpdateCheck
        [void]$helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    [void](New-PanelMenuItem $helpMenu 'About' { Show-About })
    $minWidth = [Math]::Max(560, $deviceButtons.PreferredSize.Width + $form.Width - $form.ClientSize.Width)
    $form.MinimumSize = New-Object System.Drawing.Size($minWidth, 260)
    if ($form.Width -lt $minWidth) { $form.Width = $minWidth }

    $form.add_FormClosing({
        param($sender, $e)
        if ($script:Exiting) { return }
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) {
            Invoke-Safely { Save-RecordingsForSessionEnd $sender }
            $script:ExitRequested = $true
            return
        }
        $e.Cancel = $true
        $script:ExitRequested = $true
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
$script:DeviceLogDir = [string](Get-Setting 'DeviceLogDir')
if (-not $script:DeviceLogDir) {
    $script:DeviceLogDir = if ($portable) { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'scrcpy Logs' } else { 'D:\Charles Manalo\Logs' }
}
$script:LogApps = ConvertTo-LogApps (Get-Setting 'LogApps')
$script:AppsScan = $null
$script:PaPackage = 'com.global.wwca'
$script:PiaPackage = 'com.global.integrated'
$script:AppVersions = @{}
$script:VersionScan = $null
$script:VersionScanAt = [datetime]::MinValue

[void](Invoke-Hidden $script:Adb @('start-server') 15000)

if ($List) {
    $devices = Get-AdbDevices
    if ($devices.Count -eq 0) { Write-Host 'No devices found.' }
    foreach ($key in ($devices.Keys | Sort-Object)) {
        $model = if ($devices[$key] -eq 'device') { Get-DeviceProp $key 'ro.product.model' } else { '' }
        Write-Host ('{0,-30} {1,-9} {2,-14} {3}' -f $key, (Get-ConnectionType $key), $devices[$key], $model)
    }
    exit 0
}

$createdMutex = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdMutex)
if (-not $createdMutex) {
    if ($NoPanel) {
        Show-Error 'scrcpy monitor is already running. Use -Command StartRecording, StopRecording, StartLogs, StopLogs, ShowPanel, Snip or Exit to control it.'
        exit 1
    }
    $request = Send-MonitorRequest 'OpenWindows' @()
    $deadline = (Get-Date).AddMinutes(15)
    $acquired = $false
    while (-not $acquired -and (Test-Path -LiteralPath $request) -and (Get-Date) -lt $deadline) {
        try { $acquired = $script:Mutex.WaitOne(1000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    }
    if (-not $acquired) { exit 0 }
}

Get-ChildItem -LiteralPath $script:RequestDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $script:ControlDir -File | Remove-Item -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Sessions = @{}
$script:Merges = New-Object System.Collections.ArrayList
$script:Combines = New-Object System.Collections.ArrayList
$script:Labels = New-Object System.Collections.ArrayList
$script:CombineHandovers = New-Object System.Collections.ArrayList
$script:CombineEncoderArgs = $null
$script:FpsPassthroughArgs = $null
$script:Stops = New-Object System.Collections.ArrayList
$script:LogHandovers = @{}
$script:ScreenRec = $null
$script:ScreenKeys = $null
$script:ScreenTimer = $null
$script:ScreenDda = $null
$script:DiskLow = 2GB
$script:DiskCritical = 500MB
$script:DiskFree = -1L
$script:DiskCheckedDir = $null
$script:DiskNextCheck = [datetime]::MinValue
$script:DiskWarned = $false
$script:DiskPrompting = $false
$script:DiskConfirmedAt = [datetime]::MinValue
$script:DiskRefusedAt = [datetime]::MinValue
$script:Fso = $null
$script:Connects = New-Object System.Collections.ArrayList
$script:ConnectFailures = New-Object System.Collections.ArrayList
$script:ConnectPrompting = $false
$script:Discovery = $null
$script:NextDiscovery = Get-Date
$script:DiscoveryRetry = @{}
$script:DiscoveryStatus = 'Wi-Fi scan: waiting'
$script:Probe = $null
$script:ProbeRequested = $true
$script:Scanning = $false
$script:ScanFound = New-Object System.Collections.Generic.HashSet[string]
$script:KnownWifiPath = Join-Path $env:LOCALAPPDATA 'scrcpy-monitor\wifi-devices.json'
$script:KnownWifi = Read-KnownWifi
$script:ScanPortsPath = Join-Path $env:LOCALAPPDATA 'scrcpy-monitor\scan-ports.json'
$script:ScanPorts = Read-ScanPorts
$script:DelayedConnects = @{}
$script:MovedUsb = @{}
$script:RemovedSerials = New-Object System.Collections.Generic.HashSet[string]
$script:ClosedSerials = @{}
$script:ClosedByUser = $false
$script:PowerWatchCommand = 'while [ -z $(getprop sys.shutdown.requested)$(getprop sys.powerctl) ]; do sleep 1; done; echo $(getprop sys.shutdown.requested)/$(getprop sys.powerctl)'
$script:Standby = @{}
$script:WifiSerials = @{}
$script:Exiting = $false
$script:ExitRequested = $false
$script:SessionEnding = $false
$script:ArrangeRequestedAt = $null
$script:ArrangeFollowUp = $false
$script:ArrangeArea = $null
$script:AutoArrange = -not @($ScrcpyArgs | Where-Object { $_ -match '^(--window-(x|y|width|height)|--fullscreen|-f)(=|$)' }).Count
$script:OpenWindowsRequested = $false
$script:RecordOnStart = [bool]$Record
$script:Tray = $null
$script:Panel = $null
$script:PanelList = $null
$script:PanelPending = $false
$script:About = $null
$script:Guide = $null
$script:ScrcpyVersion = $null
$script:Author = 'Charles Manalo'
$script:DefaultRepo = 'cktmanalo/scrcpy'
$script:UpdateConfig = Get-UpdateConfig
$script:UpdateCheck = $null
$script:UpdateStatus = ''
$script:AvailableUpdate = $null
$script:Updating = $false
$script:Updater = $null
$script:AutoUpdateCheck = (Get-Setting 'AutoUpdateCheck') -ne $false
$script:PanelAutoUpdate = $null
$iconPath = Join-Path $script:IconDir 'icon.ico'
$script:Icon = if (Test-Path -LiteralPath $iconPath) { New-Object System.Drawing.Icon $iconPath } else { $null }

Write-Log "Monitor started (scrcpy: $script:Scrcpy, adb: $script:Adb, devices: $(if ($Serial.Count) { $Serial -join ', ' } else { 'all connected' }), recordings: $RecordDir)"

if (-not $NoPanel) { $script:Panel = New-Panel }

if (-not $NoTray) {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = if ($script:Icon) { $script:Icon } else { [System.Drawing.SystemIcons]::Application }
    $script:Tray.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
    $script:Tray.ContextMenuStrip.add_Opening({ param($sender, $e) Invoke-Safely { Update-TrayMenu }; $e.Cancel = $sender.Items.Count -eq 0 })
    $script:Tray.add_DoubleClick({ Invoke-Safely { if ($script:Panel) { Show-Panel } else { Open-RecordFolder } } })
    $script:Tray.Text = 'Scrcpy Monitor'
    $script:Tray.Visible = $true
}

$script:MenuKey = $null
$script:SnipKey = $null
$script:Snipping = $false
$script:SnipEditors = New-Object System.Collections.ArrayList
if ($script:Tray -or $script:Panel) {
    try { $script:MenuKey = New-MenuHotKey } catch { Write-Log "Could not set up Ctrl+Alt+M to show the tray menu: $($_.Exception.Message)" }
    if (Test-SnipPrintScreen) {
        try { [void](Enable-SnipKey) } catch { Write-Log "Could not set up Print Screen to snip: $($_.Exception.Message)" }
    }
}
if ($script:Panel -and $script:Tray) {
    if ($script:MenuKey) { $script:PanelTrayMenuItem.ShortcutKeyDisplayString = 'Ctrl+Alt+M' }
    $script:PanelTrayMenuItem.Visible = $true
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
    Invoke-Safely { Update-DiskSpace }
    Invoke-Safely { Update-Stops }
    Invoke-Safely { Update-PartStarts }
    Invoke-Safely { Complete-UpdateCheck }
    Invoke-Safely { Complete-LogAppsScan }
    Invoke-Safely { Complete-VersionScan }
    Invoke-Safely { Start-VersionScan }
    Invoke-Safely { Update-UpdaterState }
    Invoke-Safely { Show-ConnectFailures }
    $script:FastTimerTicks++
    if ($script:FastTimerTicks % 3 -eq 0) { Invoke-Safely { Update-Panel } }
})
$script:FastTimer.Start()

$script:PanelPending = [bool]$script:Panel
Invoke-Safely { Show-UpdateInstalled }
if (-not $NoUpdateCheck -and $script:AutoUpdateCheck) { Invoke-Safely { Start-UpdateCheck $false } }

try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
} finally {
    $script:Timer.Dispose()
    $script:FastTimer.Dispose()
    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
    Write-Log 'Monitor stopped.'
}
