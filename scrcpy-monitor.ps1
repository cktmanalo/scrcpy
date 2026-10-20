<#
.SYNOPSIS
    Mirrors one or more adb devices with the scrcpy built in this repository, keeps each window open while
    the device restarts, and records the screen on demand.

.DESCRIPTION
    One scrcpy window is opened per device with --reconnect, so the window stays open while the device
    restarts and mirroring resumes in the same window. Every scrcpy process runs without a console window.
    Closing a scrcpy window stops monitoring that device; the monitor exits once every window is closed.

    Recording runs in a separate hidden scrcpy process that can be started and stopped at any time from the
    tray icon or with -Command. A device restart while recording continues the recording in a new part, and
    the parts are joined into one MP4 with ffmpeg when the recording stops:
        <RecordDir>\<Device Name>\Screen_Recording_<Device Name>_<yyyyMMdd_HHmmss>.mp4
    If the device cannot run a second hardware video encoder, the recorder switches to a software encoder.

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
    [string]$RecordDir = 'D:\Charles Manalo\Recordings',
    [string]$RecordEncoder = 'auto',
    [string[]]$RecordArgs,
    [switch]$KeepParts,
    [ValidateSet('StartRecording', 'StopRecording', 'Exit')]
    [string]$Command,
    [switch]$List,
    [switch]$NoTray,
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 2,
    [Parameter(DontShow)]
    [int]$SendCtrlC,
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
$script:LogDir = Join-Path $script:StateDir 'logs'
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

[void](New-Item -ItemType Directory -Force -Path $script:RequestDir, $script:LogDir)

$Serial = @($Serial | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ScrcpyArgs = @($ScrcpyArgs | Where-Object { $_ -and $_ -ne '--' })
$RecordArgs = @($RecordArgs | Where-Object { $_ })

if ($Command) {
    $existing = $null
    if (-not [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$existing)) {
        Write-Host 'scrcpy monitor is not running.'
        exit 1
    }
    $existing.Dispose()
    $name = '{0:yyyyMMddHHmmssfff}-{1}' -f (Get-Date), [guid]::NewGuid().ToString('N')
    $temp = Join-Path $script:RequestDir "$name.tmp"
    @{ Command = $Command; Serial = $Serial } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination (Join-Path $script:RequestDir "$name.json")
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
    # A crashed scrcpy leaves its "adb shell app_process" running, which keeps the log file locked
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

function Stop-ScrcpyProcess([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 15000) {
    if ($Process.HasExited) { return $true }
    $helper = $null
    try {
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SendCtrlC {1}' -f $PSCommandPath, $Process.Id
        $helper = [System.Diagnostics.Process]::Start((New-HiddenStartInfo $script:PowerShellExe $arguments))
        [void]$helper.WaitForExit(15000)
    } catch {
        Write-Log "Could not send Ctrl+C to process $($Process.Id): $($_.Exception.Message)"
    } finally {
        if ($helper) { $helper.Dispose() }
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
    # Before Android 10 the encoder type is unknown, so also recognize the AOSP software encoders by name
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
    }
    $script:Sessions[$DeviceSerial] = $session
    if ($script:RecordOnStart) { Start-Recording $session }
    $session
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
    $arguments = @('-s', $Session.Serial, '--reconnect')
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
        # Right after a boot the server may never come up, leaving the client waiting forever
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

    if (-not $Session.Recording -or $now -lt $Session.NextRecordAttempt) { return }
    if (-not $Session.Display -or ($now - $Session.DisplayStartedAt).TotalSeconds -lt 5) { return }
    if ($null -eq $Ready.Value) { $Ready.Value = Test-DeviceReady $Session $Devices }
    if (-not $Ready.Value) { return }
    # Let the window reconnect first, so that both do not push the server at the same time
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
    if ($Session.Recorder) {
        [void](Stop-ScrcpyProcess $Session.Recorder)
        $Session.Recorder.Dispose()
        $Session.Recorder = $null
    }
    Complete-Recording $Session
}

function Complete-Recording($Session) {
    $parts = @($Session.Parts | Where-Object { Test-VideoFile $_ })
    foreach ($part in @($Session.Parts | Where-Object { $parts -notcontains $_ })) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    $Session.Parts.Clear()
    if (-not $Session.RecordingBase -or $parts.Count -eq 0) {
        Show-Notification "Recording stopped for $($Session.Title); nothing was recorded."
        return
    }

    $output = "$($Session.RecordingBase).mp4"
    if ($parts.Count -eq 1) {
        Move-Item -LiteralPath $parts[0] -Destination $output
        Show-Notification "Recording saved: $output"
        return
    }
    if (-not $script:Ffmpeg) {
        Show-Notification "Recording saved in $($parts.Count) parts next to $output (ffmpeg not found to join them)."
        return
    }

    # scrcpy adds the video and audio streams in arrival order, so normalize each part before concatenation
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
    if ($tracked.Count -gt 0 -and -not ($tracked | Where-Object { -not $_.UserClosed })) {
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
    try {
        foreach ($session in @($script:Sessions.Values)) { Invoke-Safely { Stop-Recording $session } }
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
        $script:AppContext.ExitThread()
    }
}

$RepoRoot = $PSScriptRoot
$buildPath = if ([System.IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $RepoRoot $BuildDir }
$script:Scrcpy = Join-Path $buildPath 'app\scrcpy.exe'
$script:Server = Join-Path $buildPath 'server\scrcpy-server'
$script:IconDir = Join-Path $RepoRoot 'app\data'
$script:PowerShellExe = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $script:Scrcpy -PathType Leaf) -or -not (Test-Path -LiteralPath $script:Server -PathType Leaf)) {
    Show-Error "scrcpy is not built in '$buildPath'. Build it first (meson setup $BuildDir ... then ninja -C $BuildDir) or pass -BuildDir."
    exit 1
}

$msysCandidates = if ($MsysBin) { @($MsysBin) } else { @('D:\msys64\mingw64\bin', 'C:\msys64\mingw64\bin') }
$script:MsysBinPath = $msysCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'SDL3.dll') } | Select-Object -First 1
if (-not $script:MsysBinPath) { Write-Log 'WARNING: MSYS2 mingw64\bin with SDL3.dll not found; scrcpy needs its DLLs in PATH.' }

$adbCandidates = @($env:ADB, (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
$script:Adb = Resolve-Tool $AdbPath $adbCandidates 'adb.exe'
if (-not $script:Adb) {
    Show-Error 'adb.exe not found. Add platform-tools to PATH or pass -AdbPath.'
    exit 1
}

$toolDir = if ($script:MsysBinPath) { $script:MsysBinPath } else { '' }
$script:Ffmpeg = Resolve-Tool $null @($(if ($toolDir) { Join-Path $toolDir 'ffmpeg.exe' })) 'ffmpeg.exe'
$script:Ffprobe = Resolve-Tool $null @($(if ($toolDir) { Join-Path $toolDir 'ffprobe.exe' })) 'ffprobe.exe'

if ($ScrcpyArgs | Where-Object { $_ -match '^(--record(=|$)|-r)' }) {
    Show-Error 'Use -Record (or the tray menu) to record instead of passing --record to scrcpy.'
    exit 1
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
    Show-Error 'scrcpy monitor is already running. Use -Command StartRecording, StopRecording or Exit to control it.'
    exit 1
}

Get-ChildItem -LiteralPath $script:RequestDir -File | Remove-Item -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:Sessions = @{}
$script:Merges = New-Object System.Collections.ArrayList
$script:Exiting = $false
$script:RecordOnStart = [bool]$Record
$script:Tray = $null

Write-Log "Monitor started (scrcpy: $script:Scrcpy, adb: $script:Adb, devices: $(if ($Serial.Count) { $Serial -join ', ' } else { 'all connected' }), recordings: $RecordDir)"

if (-not $NoTray) {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $iconPath = Join-Path $script:IconDir 'icon.ico'
    $script:Tray.Icon = if (Test-Path -LiteralPath $iconPath) { New-Object System.Drawing.Icon $iconPath } else { [System.Drawing.SystemIcons]::Application }
    $script:Tray.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
    $script:Tray.ContextMenuStrip.add_Opening({ Invoke-Safely { Update-TrayMenu } })
    $script:Tray.add_DoubleClick({ Invoke-Safely { Open-RecordFolder } })
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

try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
} finally {
    $script:Timer.Dispose()
    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
    Write-Log 'Monitor stopped.'
}
