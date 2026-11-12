<#
.SYNOPSIS
    Builds a portable ZIP of scrcpy and scrcpy-monitor for QA and other users (no installation needed).

.DESCRIPTION
    Builds the release build directory, then collects scrcpy.exe, scrcpy-server, the MSYS2 DLLs it needs,
    ffmpeg/ffprobe (to join recordings), adb, the monitor scripts and a README into
    dist\scrcpy-monitor-portable-<version>\ and zips it.

    The package checks -UpdateRepo for new releases. -Publish uploads the ZIP and both user guides as the latest GitHub release of
    -UpdateRepo (tag qa-<version>), so every installed package offers to update itself. Publishing needs a
    clean working tree, HEAD pushed to origin and the GitHub CLI (gh) signed in.

.EXAMPLE
    .\package-portable.ps1
.EXAMPLE
    .\package-portable.ps1 -NoBuild -AdbDir C:\platform-tools
.EXAMPLE
    .\package-portable.ps1 -Publish -Notes 'Fix recording after reboot'
#>
[CmdletBinding()]
param(
    [string]$BuildDir = 'x',
    [string]$MsysRoot = 'D:\msys64',
    [string]$AdbDir = (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools'),
    [string]$OutDir = 'dist',
    [string]$UpdateRepo = 'cktmanalo/scrcpy',
    [string]$Notes,
    [switch]$NoBuild,
    [switch]$NoZip,
    [switch]$Publish
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
$mingwBin = Join-Path $MsysRoot 'mingw64\bin'
$buildPath = if ([System.IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $root $BuildDir }
$outPath = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }

function Invoke-Msys([string]$Command) {
    $env:MSYSTEM = 'MINGW64'
    $env:CHERE_INVOKING = '1'
    Push-Location -LiteralPath $root
    try {
        $output = & $bash -lc $Command
        if ($LASTEXITCODE) { throw "MSYS2 command failed ($LASTEXITCODE): $Command`n$($output -join "`n")" }
        $output
    } finally {
        Pop-Location
    }
}

function ConvertTo-MsysPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    '/' + $full.Substring(0, 1).ToLowerInvariant() + ($full.Substring(2) -replace '\\', '/')
}

function Copy-Required([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Missing file: $Source" }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw "MSYS2 not found in '$MsysRoot' (use -MsysRoot)." }
if (-not (Test-Path -LiteralPath (Join-Path $AdbDir 'adb.exe') -PathType Leaf)) { throw "adb.exe not found in '$AdbDir' (use -AdbDir)." }

$version = (& git -C $root describe --tags --first-parent --match 'v[0-9]*' --always --dirty 2>$null)
if (-not $version) { $version = Get-Date -Format 'yyyyMMdd' }
$tag = "qa-$version"
$displayVersion = if ($version -match '^v?(\d+(?:\.\d+)+)(?:-(\d+)-g[0-9a-f]+)?(?:-dirty)?$') { '{0}.{1}' -f $Matches[1], $(if ($Matches[2]) { $Matches[2] } else { '0' }) } else { $version }

if ($Publish) {
    if ($NoZip) { throw '-Publish needs the ZIP; remove -NoZip.' }
    if (-not $UpdateRepo) { throw '-Publish needs -UpdateRepo.' }
    if ($version -like '*-dirty') { throw 'Commit your changes before publishing.' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required to publish.' }
    $head = (& git -C $root rev-parse HEAD)
    if (-not (& git -C $root branch -r --contains $head | Where-Object { $_.Trim() -like 'origin/*' })) {
        throw "Push the current branch to origin before publishing ($head is not on origin)."
    }
}

if (-not $NoBuild) {
    Write-Host "Building $buildPath..."
    [void](Invoke-Msys "ninja -C '$(ConvertTo-MsysPath $buildPath)'")
}

$scrcpy = Join-Path $buildPath 'app\scrcpy.exe'
$server = Join-Path $buildPath 'server\scrcpy-server'
if (-not (Test-Path -LiteralPath $scrcpy) -or -not (Test-Path -LiteralPath $server)) { throw "scrcpy is not built in '$buildPath'." }

$name = "scrcpy-monitor-portable-$version"
$package = Join-Path $outPath $name
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }
[void](New-Item -ItemType Directory -Force -Path $package)

Write-Host 'Collecting files...'
Copy-Required $scrcpy $package
Copy-Required $server $package
foreach ($file in 'icon.ico', 'scrcpy.png', 'disconnected.png') { Copy-Required (Join-Path $root "app\data\$file") $package }
foreach ($file in 'scrcpy-monitor.ps1', 'scrcpy-monitor.vbs', 'scrcpy-monitor-guide.docx', 'scrcpy-monitor-guide.html') { Copy-Required (Join-Path $root $file) $package }
Copy-Required (Join-Path $root 'LICENSE') $package
foreach ($file in 'ffmpeg.exe', 'ffprobe.exe') { Copy-Required (Join-Path $mingwBin $file) $package }
foreach ($file in 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll') { Copy-Required (Join-Path $AdbDir $file) $package }

$binaries = @((Join-Path $package 'scrcpy.exe'), (Join-Path $mingwBin 'ffmpeg.exe'), (Join-Path $mingwBin 'ffprobe.exe')) | ForEach-Object { ConvertTo-MsysPath $_ }
$quoted = ($binaries | ForEach-Object { "'$_'" }) -join ' '
$dlls = @(Invoke-Msys "ldd $quoted" | ForEach-Object {
    if ($_ -match '=>\s+/mingw64/bin/(\S+\.dll)') { $Matches[1] }
} | Sort-Object -Unique)
if ($dlls.Count -eq 0) { throw 'ldd found no MSYS2 DLL dependency.' }
foreach ($dll in $dlls) { Copy-Required (Join-Path $mingwBin $dll) $package }

if ($UpdateRepo) {
    @{ Repo = $UpdateRepo; Version = $tag; Built = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $package 'update.json') -Encoding ASCII
}

@'
Option Explicit

Dim fso, shell, folder, link
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
folder = fso.GetParentFolderName(WScript.ScriptFullName)

Set link = shell.CreateShortcut(fso.BuildPath(shell.SpecialFolders("Desktop"), "scrcpy monitor.lnk"))
link.TargetPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\wscript.exe")
link.Arguments = """" & fso.BuildPath(folder, "scrcpy-monitor.vbs") & """"
link.WorkingDirectory = folder
link.IconLocation = fso.BuildPath(folder, "icon.ico") & ",0"
link.Description = "Mirror and record Android devices with scrcpy"
link.Save

MsgBox "The ""scrcpy monitor"" shortcut was added to your desktop.", vbInformation, "scrcpy monitor"
'@ | Set-Content -LiteralPath (Join-Path $package 'Create Desktop Shortcut.vbs') -Encoding ASCII

@"
scrcpy monitor (portable) - $version
=====================================

Mirror one or more Android devices, keep each window open while the device restarts, arrange the
windows without overlapping, and record the screen (recordings continue across device restarts;
Record combined joins several devices into one video that keeps the proportions of each device).

See Help > "User guide" in the control panel (scrcpy-monitor-guide.html) or scrcpy-monitor-guide.docx
in this folder for the full how-to guide.

SETUP (once)
  1. Extract the whole ZIP to a folder of your choice (for example C:\Tools\scrcpy-monitor).
     Do not run it from inside the ZIP.
  2. On each device: enable Developer options > USB debugging, connect it with USB and accept the
     "Allow USB debugging" prompt.
  3. Optional: double-click "Create Desktop Shortcut.vbs" to add a "scrcpy monitor" desktop shortcut.

START
  Double-click "scrcpy-monitor.vbs" (or the desktop shortcut).
  A window opens for every connected device (USB or Wi-Fi/TCP), and the "scrcpy monitor" control
  panel appears as soon as the first device screen starts sharing. Running it again while it is
  already running shows the control panel and shows again any device you closed.
  The Connection column shows whether each device uses USB or Wi-Fi. Click a column header to sort
  the list. Global actions are in the File, Recording, Window and Help menus of the control panel.

DEVICE WINDOWS
  Device windows are arranged on the screen where the control panel is: one device is centered, and
  several devices are placed side by side (or in rows) around the center without overlapping. Each
  window is shown at the device's full resolution (100%) when it fits; a larger device screen is scaled
  down to fit, never cropped. The windows are arranged again whenever a device window opens or closes;
  minimized, maximized and fullscreen windows are left as they are. To put windows back after moving
  them, use Window > "Arrange windows" in the control panel (or "Arrange device windows" in the tray
  menu). Starting the monitor with --window-x, --window-y, --window-width, --window-height or
  --fullscreen turns automatic arranging off.

WI-FI
  - "Switch to Wi-Fi" (device on USB): turns on ADB over Wi-Fi and mirrors the device over Wi-Fi.
    You can then unplug the cable. "Switch to USB" (Wi-Fi device, cable plugged in) does the reverse.
  - "Connect Wi-Fi device..." (control panel or tray menu): connects a device by IP address and port.
    Pick a port or type any port; a port that works is remembered and added to "Refresh".
  - "Refresh": shows closed devices again, and finds devices on the local network with ADB over
    Wi-Fi turned on and connects them.
  - If a connection fails, a message explains why (no device at that address, port not open, or
    debugging not allowed) and "Retry" reopens the dialog with the same IP address and port.
  - "Disconnect" ends a Wi-Fi connection; "Reconnect" connects it again. Wi-Fi devices are
    remembered and reconnected automatically.
  - A device connected over both USB and Wi-Fi is mirrored over USB (unless it is already recording
    over Wi-Fi); the other entry shows "Standby (using ...)". If USB is unplugged for 30 seconds,
    Wi-Fi takes over the mirroring; a recording over USB waits for the cable instead. If Wi-Fi is
    lost for 30 seconds while USB is connected, its recording is saved and a new one starts over USB.

RECORD
  - Click the round button in the top-right corner of a device window (red dot = start, white square =
    stop), or press Alt+E in that window.
  - Or use the control panel: select devices, then "Start recording"/"Stop recording", or
    Recording > "Start all" and "Stop all".
  - Or right-click the tray icon.
  If the device restarts while recording, the recording continues automatically; the parts are
  joined into a single MP4 when the recording stops. Each saved recording has a header with the
  device name above the screen, added with ffmpeg a few seconds after you stop (the status bar shows
  "Adding device name header to <n> recording(s)..."). If it cannot be added, the recording is kept
  without it.

  Recordings are saved as:
    <Recordings folder>\<Device Name>\Screen_Recording_<Device Name>_<yyyyMMdd_HHmmss>.mp4
  The default folder is "Videos\scrcpy Recordings". Use File > "Change recordings folder..." in the
  control panel to change it, and File > "Open recordings folder" to open it.

RECORD COMBINED
  Select two or more devices in the control panel and click "Record combined". Each device is recorded
  and saved as above; when all of them have stopped (stop them together or one by one), their recordings
  are also joined into one video laid out like the arranged device windows (at most 2560x1440):
    <Recordings folder>\Combined\Screen_Recording_Combined_<yyyyMMdd_HHmmss>.mp4
  Each screen has a header with its device name. Every device keeps its own proportions and relative size:
  a smaller screen (for example P630) is not stretched to match the others. A device that stops early or   restarts shows the gray background
    under its header until the others stop. The combined video has no audio, and devices are synchronized to about one second. Exit waits up to 2 minutes for
  the combined video; if it is not finished by then, it is cancelled.

DEVICE LIST
  A restarting device stays in the list as "Device restarting" and reconnects in the same window.
  A device that is turned off is removed; one that is unplugged or drops off Wi-Fi is removed after
  30 seconds (not while recording). A restart started with "adb reboot" is not detected, so that
  device is removed and reappears when it is back.

CLOSE
  Closing a device window, or "Stop and close" in the control panel or tray menu, stops that device
  and removes it from the list ("Refresh" shows it again). Closing the control panel exits the monitor,
  the same as "Exit": recordings in progress are stopped and saved and every device window is closed.
  The monitor also exits once every device window is closed and any combined recording is saved.

UPDATES
  At startup, and when you click Help > "Check for updates" in the control panel (or the tray menu), the
  monitor checks https://github.com/$UpdateRepo/releases for a newer version. Accept the prompt to
  download it; the monitor stops (saving any recording), updates this folder and restarts, then shows
  "Updated to scrcpy monitor <version>". If you decline, the status bar shows "Update <version>
  available" and About offers "Install update". Turn off Help > "Check for updates automatically" to
  skip the startup check. Your settings are kept.

TROUBLESHOOTING
  - No device listed: check the USB cable and USB debugging authorization ("adb.exe devices" in this
    folder lists the devices).
  - Status "Allow USB debugging on device": unlock the device and tap "Allow" on the USB
    debugging prompt. A requested recording starts automatically once allowed.
  - Wi-Fi device stays "Device restarting" or is removed after a reboot: most devices turn off ADB
    over Wi-Fi when they restart. Connect it with USB and use "Switch to Wi-Fi" again.
  - File > "Open log" in the control panel shows what happened; per-device logs are in
    %TEMP%\scrcpy-monitor\logs. "About" shows the version to include when reporting a problem.
  - If Windows blocks the files after downloading the ZIP: right-click the ZIP > Properties >
    Unblock, then extract it again.

scrcpy is licensed under the Apache License 2.0 (see LICENSE). adb, FFmpeg and the bundled
libraries are distributed under their own licenses.
"@ | Set-Content -LiteralPath (Join-Path $package 'README-QA.txt') -Encoding UTF8

$size = (Get-ChildItem -LiteralPath $package -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("Package: {0} ({1} files, {2:N0} MB)" -f $package, @(Get-ChildItem -LiteralPath $package -File).Count, ($size / 1MB))

if (-not $NoZip) {
    $zip = "$package.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($package, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host ("ZIP: {0} ({1:N0} MB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1MB))
}

if ($Publish) {
    $notesFile = Join-Path $env:TEMP "scrcpy-monitor-notes-$PID.txt"
    $text = if ($Notes) { $Notes } else { (& git -C $root log -1 --format=%s) }
    Set-Content -LiteralPath $notesFile -Value $text -Encoding UTF8
    try {
        Write-Host "Publishing $tag to $UpdateRepo..."
        & gh release create $tag $zip (Join-Path $root 'scrcpy-monitor-guide.docx') (Join-Path $root 'scrcpy-monitor-guide-macos-linux.docx') --repo $UpdateRepo --target $head --title "scrcpy monitor $displayVersion" --notes-file $notesFile --latest
        if ($LASTEXITCODE) { throw "gh release create failed ($LASTEXITCODE)." }
    } finally {
        Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
    }
}
