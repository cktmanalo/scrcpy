<#
.SYNOPSIS
    Builds a portable ZIP of scrcpy and scrcpy-monitor for QA and other users (no installation needed).

.DESCRIPTION
    Builds the release build directory, then collects scrcpy.exe, scrcpy-server, the MSYS2 DLLs it needs,
    ffmpeg/ffprobe (to join recordings), adb, the monitor scripts and a README into
    dist\scrcpy-monitor-portable-<version>\ and zips it.

    The package checks -UpdateRepo for new releases. -Publish uploads the ZIP as the latest GitHub release of
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

$version = (& git -C $root describe --tags --always --dirty 2>$null)
if (-not $version) { $version = Get-Date -Format 'yyyyMMdd' }
$tag = "qa-$version"

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
foreach ($file in 'scrcpy-monitor.ps1', 'scrcpy-monitor.vbs') { Copy-Required (Join-Path $root $file) $package }
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

Mirror one or more Android devices, keep each window open while the device restarts, and record the
screen (recordings continue across device restarts).

SETUP (once)
  1. Extract the whole ZIP to a folder of your choice (for example C:\Tools\scrcpy-monitor).
     Do not run it from inside the ZIP.
  2. On each device: enable Developer options > USB debugging, connect it with USB and accept the
     "Allow USB debugging" prompt.
  3. Optional: double-click "Create Desktop Shortcut.vbs" to add a "scrcpy monitor" desktop shortcut.

START
  Double-click "scrcpy-monitor.vbs" (or the desktop shortcut).
  A window opens for every connected device. The monitor runs in the background with a tray icon
  (notification area); no other window is shown.
  Running it again while it is already running reopens any device window you closed.

RECORD
  - Click the round button in the top-right corner of a device window (red dot = start, white square =
    stop), or press Alt+E in that window.
  - Or right-click the tray icon: pick a device > Start/Stop recording, or "Start/Stop recording on all
    devices".
  If the device restarts while recording, the recording continues automatically; the parts are
  joined into a single MP4 when the recording stops.

  Recordings are saved as:
    <Recordings folder>\<Device Name>\Screen_Recording_<Device Name>_<yyyyMMdd_HHmmss>.mp4
  The default folder is "Videos\scrcpy Recordings". Right-click the tray icon > "Change recordings
  folder..." to change it, and "Open recordings folder" (or double-click the tray icon) to open it.

CLOSE
  Closing a device window stops mirroring that device (right-click the tray icon > the device >
  "Open window" to reopen it). When every device window is closed, the monitor exits.
  Right-click the tray icon > "Exit" also quits. Exiting stops and saves any recording in progress.
  An optional "Control panel" with the same actions is in the tray icon menu.

UPDATES
  At startup, and when you click "Check for updates" in the tray icon menu, the
  monitor checks https://github.com/$UpdateRepo/releases for a newer version. Accept the prompt to
  download it; the monitor stops (saving any recording), updates this folder and restarts.
  Your recordings folder setting is kept.

TROUBLESHOOTING
  - No device listed: check the USB cable and USB debugging authorization ("adb.exe devices" in this
    folder lists the devices).
  - Right-click the tray icon > "Open log" shows what happened; per-device logs are in
    %TEMP%\scrcpy-monitor\logs.
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
        & gh release create $tag $zip --repo $UpdateRepo --target $head --title "scrcpy monitor $tag" --notes-file $notesFile --latest
        if ($LASTEXITCODE) { throw "gh release create failed ($LASTEXITCODE)." }
    } finally {
        Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
    }
}
