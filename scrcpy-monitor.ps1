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
    Recording, Window and Help menus, and a column header click sorts the device list.

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

    The recordings folder is -RecordDir if given, else the folder chosen from the tray icon, else the
    default. When scrcpy.exe is next to this script (portable package), scrcpy, adb and ffmpeg are used from
    this folder.

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
        RecorderFailures   = 0
        NextRecordAttempt  = Get-Date
        SoftwareEncoder    = $(if ($RecordEncoder -eq 'auto') { Get-CachedEncoder $DeviceSerial } else { $null })
        ControlPath        = Join-Path $script:ControlDir "$(ConvertTo-SafeName $DeviceSerial).state"
        Stopping           = $false
        RecordPending      = $script:RecordOnStart
        CombineMember      = $null
        PartStarts         = @{}
        PartStartPending   = $false
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
                [void](Invoke-Adb @('-s', $Session.Serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP') 3000)
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
    Remove-Item -LiteralPath $Label.Temp -Force -ErrorAction SilentlyContinue
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
        Remove-Item -LiteralPath $label.Temp -Force -ErrorAction SilentlyContinue
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
            'ShowPanel' {
                if ($script:Panel) { Show-Panel }
                else { Show-Notification 'scrcpy monitor is already running (see the tray icon).' }
            }
            'OpenWindows' { $script:OpenWindowsRequested = $true }
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
    if (-not ($script:Panel -and $script:Panel.Visible) -and $script:ClosedByUser -and -not $opened.Count -and -not ($tracked | Where-Object { $_.MovedTo }) -and -not (Test-CombineActive) -and -not $script:Labels.Count) {
        Write-Log 'All scrcpy windows were closed.'
        Stop-Monitor
        return
    }
    Update-Arrange
    Update-TrayText
}

function Update-TrayText {
    if (-not $script:Tray) { return }
    $recording = @($script:Sessions.Values | Where-Object { $_.Recording }).Count
    $text = if ($recording) { "Scrcpy Monitor - recording $recording device(s)" } else { 'Scrcpy Monitor' }
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
    $startAll.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s }; Update-TrayText } })
    $stopAll = $menu.Items.Add('Stop recording on all devices')
    $stopAll.Enabled = @($sessions | Where-Object { $_.Recording }).Count -gt 0
    $stopAll.add_Click({ Invoke-Safely { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s }; Update-TrayText } })
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
    $changeFolder.add_Click({ Invoke-Safely { Select-RecordFolder } })
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
        "- Click a column header to sort the list; global actions are in the File, Recording, Window and Help menus.`n" +
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
        Invoke-Safely { Stop-AdbJobs }
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-PowerWatch $session } }
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-Recording $session } }
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
        Invoke-Safely { Update-Combines 120000 }
        Invoke-Safely { Stop-Combines }
        Invoke-Safely { Update-Labels 120000 -Force }
        Invoke-Safely { Stop-Labels }
    } finally {
        if ($script:Tray) {
            $script:Tray.Visible = $false
            $script:Tray.Dispose()
        }
        if ($script:Panel) { $script:Panel.Dispose() }
        $script:AppContext.ExitThread()
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
    try {
        $dialog.Description = 'Choose the folder where recordings are saved'
        if (Test-Path -LiteralPath $RecordDir) { $dialog.SelectedPath = $RecordDir }
        $owner = if ($script:Panel -and $script:Panel.Visible) { $script:Panel } else { $null }
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:RecordDir = $dialog.SelectedPath
    } finally {
        $dialog.Dispose()
    }
    Set-Setting 'RecordDir' $RecordDir
    Write-Log "Recordings folder changed to $RecordDir"
    Update-Panel
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
    if ($owner) { return [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Scrcpy Monitor', $Buttons, $Icon) }
    [System.Windows.Forms.MessageBox]::Show($Text, 'Scrcpy Monitor', $Buttons, $Icon)
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
    $text = 'REC {0:hh\:mm\:ss}' -f ((Get-Date) - $Session.RecordingStartedAt)
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
    $list.BeginUpdate()
    try {
        foreach ($session in @($script:Sessions.Values)) {
            $index = $list.Items.IndexOfKey($session.Serial)
            if ($index -lt 0) {
                $item = $list.Items.Add($session.Serial, $session.Title, -1)
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add('')
            } else {
                $item = $list.Items[$index]
            }
            $texts = @($session.Title, $session.Connection, (Get-SessionStatus $session), (Get-SessionRecordingText $session))
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
    $status = "Recordings: $RecordDir"
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
    Add-Type -Namespace ScrcpyMonitor -Name Window -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);'
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($script:UpdateConfig) { "Scrcpy Monitor $($script:UpdateConfig.Display)" } else { 'Scrcpy Monitor' }
    $form.Size = New-Object System.Drawing.Size(720, 380)
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
    $status = New-Object System.Windows.Forms.ToolStripStatusLabel
    $status.Spring = $true
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
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
        if ($toStart.Count -gt 0) { foreach ($s in $toStart) { Start-Recording $s } }
        else { foreach ($s in $selected) { Stop-Recording $s } }
    }
    $script:PanelCombine = New-PanelButton $deviceButtons 'Record combined' {
        Start-CombinedRecording @(Get-SelectedSessions | Where-Object { -not $_.UserClosed -and -not $script:Standby.ContainsKey($_.Serial) })
    }
    $script:PanelOpen = New-PanelButton $deviceButtons 'Open window' { Open-Window @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelClose = New-PanelButton $deviceButtons 'Stop and close' { Close-Device @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelDisconnect = New-PanelButton $deviceButtons 'Disconnect' { Disconnect-Device @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    $script:PanelSwitch = New-PanelButton $deviceButtons 'Switch to USB' { Switch-Connection @(Get-SelectedSessions | ForEach-Object { $_.Serial }) }
    [void](New-PanelButton $deviceButtons 'Connect Wi-Fi device...' { Show-ConnectDialog })
    $script:PanelScanNow = New-PanelButton $deviceButtons 'Refresh' { Invoke-Refresh }
    $list.add_DoubleClick({ Invoke-Safely { $script:PanelToggle.PerformClick() } })

    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&File'
    $recordingMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Recording'
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Help'
    $windowMenu = New-Object System.Windows.Forms.ToolStripMenuItem '&Window'
    [void]$menuBar.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($fileMenu, $recordingMenu, $windowMenu, $helpMenu))
    [void](New-PanelMenuItem $windowMenu 'Arrange windows' { Invoke-ArrangeWindows })
    [void](New-PanelMenuItem $fileMenu 'Open recordings folder' { Open-RecordFolder })
    [void](New-PanelMenuItem $fileMenu 'Change recordings folder...' { Select-RecordFolder })
    [void](New-PanelMenuItem $fileMenu 'Open log' { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$script:LogPath`"" })
    [void]$fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](New-PanelMenuItem $fileMenu 'Exit' { $script:ExitRequested = $true })
    $script:PanelStartAll = New-PanelMenuItem $recordingMenu 'Start all' { foreach ($s in (Get-TargetSessions @())) { Start-Recording $s } }
    $script:PanelStopAll = New-PanelMenuItem $recordingMenu 'Stop all' { foreach ($s in (Get-TargetSessions @())) { Stop-Recording $s } }
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
        Show-Error 'scrcpy monitor is already running. Use -Command StartRecording, StopRecording, ShowPanel or Exit to control it.'
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
    $script:Tray.ContextMenuStrip.add_Opening({ Invoke-Safely { Update-TrayMenu } })
    $script:Tray.add_DoubleClick({ Invoke-Safely { if ($script:Panel) { Show-Panel } else { Open-RecordFolder } } })
    $script:Tray.Text = 'Scrcpy Monitor'
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
    Invoke-Safely { Update-PartStarts }
    Invoke-Safely { Complete-UpdateCheck }
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
