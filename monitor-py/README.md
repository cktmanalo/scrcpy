# Scrcpy Monitor (Python / PySide6)

Cross-platform port of `scrcpy-monitor.ps1` for macOS, Linux and Windows. It mirrors every connected adb device in its own scrcpy window and keeps the window open across reboots and reconnects with the fork's `--reconnect` option. Device windows open centered without overlapping, at 100% when they fit (macOS and Linux; on Windows use the ps1 for window arranging). It records each device in parts with a separate `scrcpy --no-window --record` process; with ffmpeg, each saved recording gets a header with the device name above the screen. The in-window record button uses `--record-control`. "Record combined" in the control panel also joins the recordings of the selected devices into one grid video under `Combined/` once all of them stop; each screen has a header with its device name, and every screen is scaled by the same factor so smaller devices keep their real size and proportions instead of being stretched. The app also handles Wi-Fi devices, USB/Wi-Fi switching, USB-priority standby and self-update from the `cktmanalo/scrcpy` GitHub releases.

All features of the Windows tray app are available on every platform.

## Run from source

```sh
cd monitor-py
python3 -m pip install -r requirements.txt
python3 main.py                                   # all devices
python3 main.py --serial 192.168.68.103:5555      # only one device
python3 main.py --command show-panel              # talk to the running instance
python3 main.py --help
```

Options:

| Option | Purpose |
| --- | --- |
| `--serial S` | Monitor only these devices. Repeat the option or separate serials with commas. |
| `--scrcpy PATH`, `--adb PATH` | Use these tool paths instead of looking them up. |
| `--record`, `--record-dir`, `--record-encoder`, `--record-arg`, `--keep-parts` | Recording options. `--record` starts recording every device right away. |
| `--port-base N` | First local port for scrcpy sessions. Each session uses a block of 4 ports: the window uses `N:N+1` and the recorder `N+2:N+3`. |
| `--poll-seconds`, `--no-discovery`, `--no-update-check`, `--no-tray`, `--no-panel`, `--list` | See `--help`. |
| `--command start-recording\|stop-recording\|show-panel\|exit` | Sends a command to the running instance. |

Options the monitor does not recognize, and everything after `--`, are passed to scrcpy.

Only one instance runs at a time; it uses `QLocalServer`. A second launch asks the running instance to show the panel and show again any device you closed, as the ps1 does. If the running instance is exiting, the second launch waits for it to finish and then starts.

## Control panel and device list

Global actions are in the panel's menu bar: **File** (Open recordings folder, Change recordings folder, Open log, Exit), **Recording** (Start all, Stop all), **Window** (Arrange windows) and **Help** (User guide, Check for updates, Check for updates automatically, About). **Help > User guide** shows the how-to guide for the current OS inside the app (`scrcpy-monitor-guide.html` on Windows, `scrcpy-monitor-guide-macos-linux.html` on macOS and Linux, bundled with the packaged app). On macOS these menus appear in the top screen menu bar, and Qt moves About and Exit (as Quit) into the application menu. Click a column header to sort the list.

- A restarting device stays in the list as "Device restarting" and reconnects in the same window. The monitor detects a restart from the power menu or `svc power reboot`; a restart started with `adb reboot` is not detected, so that device is removed and reappears when it is back.
- A device that is turned off is removed right away. One that is unplugged or drops off Wi-Fi is removed after 30 seconds. A device is never removed while it is recording.
- Closing a device window, or **Stop and close** in the panel or tray menu, stops that device and removes it from the list. **Refresh** shows it again.

## Device windows

Device windows are arranged as in the Windows ps1 on macOS and Linux (the Python build on Windows leaves them where scrcpy opens them), on the screen where the control panel is (the primary screen when the panel is hidden): one device is centered, and several devices are laid out side by side, or in rows, around the center without overlapping. A window shows the device at full resolution (100%) when it fits; a larger device screen is scaled down to fit, never cropped. The windows are arranged again whenever a device window opens or closes; minimized, maximized and fullscreen windows are left as they are. **Window > Arrange windows** in the panel, or **Arrange device windows** in the tray menu, arranges them on demand. Passing `--window-x`, `--window-y`, `--window-width`, `--window-height`, `--fullscreen` or `-f` turns automatic arranging off.

`windowing.py` moves the scrcpy windows:

- **Linux:** Xlib through ctypes. It finds each window by `_NET_WM_PID` and moves it with `_NET_MOVERESIZE_WINDOW`, or with `XMoveResizeWindow` when the window manager does not support it. On a Wayland session that has XWayland (`DISPLAY` is set), the monitor starts scrcpy with `SDL_VIDEO_DRIVER=x11`, because native Wayland windows cannot be moved by another app. Under fractional scaling, XWayland windows can look slightly blurry. Without X11 or XWayland, windows open where the compositor puts them.
- **macOS:** the Accessibility API. Allow Scrcpy Monitor (or Terminal, when running from source) in **System Settings > Privacy & Security > Accessibility**. Until it is allowed, windows open where macOS puts them, and **Arrange windows** shows the permission prompt.

## Tool lookup

For `scrcpy`, `adb` and the optional `ffmpeg`/`ffprobe`, the first match wins:

1. `bin/` next to the executable, in the PyInstaller bundle (`sys._MEIPASS`), or in `Contents/Resources/bin` of the .app.
2. The `SCRCPY` and `ADB` environment variables, or `--scrcpy`/`--adb`.
3. `PATH`.
4. Platform fallbacks:
   - macOS: `/opt/homebrew/bin`, `/usr/local/bin`.
   - Linux: `/usr/bin`, `/usr/local/bin`.
   - Windows: `D:\Charles Manalo\scrcpy\x\app\scrcpy.exe` (the dev build) and `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`.

If `scrcpy-server` sits next to the scrcpy binary, the monitor sets `SCRCPY_SERVER_PATH` for scrcpy, the same way the ps1 uses `-ScrcpyEnvironment`. If `bin/lib` exists, it is added to `DYLD_FALLBACK_LIBRARY_PATH` on macOS, `LD_LIBRARY_PATH` on Linux, or `PATH` on Windows.

## Files

| | macOS | Linux (XDG vars respected) | Windows |
| --- | --- | --- | --- |
| Settings, Wi-Fi devices, `scan-ports.json` | `~/Library/Application Support/Scrcpy Monitor` | `~/.local/share/scrcpy-monitor` | `%LOCALAPPDATA%\scrcpy-monitor-py` |
| Log | `~/Library/Logs/Scrcpy Monitor` | `~/.local/state/scrcpy-monitor/logs` | `%TEMP%\scrcpy-monitor-py` |
| Recordings (default) | `~/Movies/Scrcpy Recordings` | `~/Videos/Scrcpy Recordings` | `~/Videos/scrcpy Recordings` |

The Windows folders are named `scrcpy-monitor-py` so they don't clash with the PowerShell monitor.

`scan-ports.json` lists the ports used by the LAN scan; the default is `[5555, 5037]`.

## Version and updates

`update.json` sits next to the app. In the .app it is in `Contents/Resources`. The CI writes it before running PyInstaller:

```json
{"Repo":"cktmanalo/scrcpy","Version":"qa-v5.0.1-11-g<hash>","Built":"<iso>"}
```

A tag such as `qa-v5.0.1-11-g<hash>` is displayed as `5.0.1.11`. If the file is missing, the version is `dev` and the update check is off, as in the ps1.

The update check reads the latest release of the repo and picks the asset for the current platform:

- macOS: `scrcpy-monitor-macos-<arm64|x86_64>-<tag>.zip`, chosen with `platform.machine()`. It contains `Scrcpy Monitor.app`.
- Linux: `scrcpy-monitor-linux-x86_64-<tag>.tar.gz`. It contains the folder `scrcpy-monitor/`.
- Windows: the Python build only reports the update and opens the release page. The PowerShell package updates itself.

On macOS and Linux the update is downloaded to a temporary folder and unpacked: with `ditto -x -k` on macOS, and with `tarfile` on Linux. A detached `sh` script then does the following:

1. It waits for the monitor's PID to exit.
2. It swaps the installed `.app` or folder, keeping a backup that is restored if the swap fails.
3. On macOS, it runs `xattr -dr com.apple.quarantine`.
4. It relaunches the app: `open` on macOS, the executable on Linux.

The settings folder is not touched. Turn off **Help > Check for updates automatically** to skip the startup check; the choice is saved in the settings.

## Packaging (CI)

Before running PyInstaller, the CI fills `monitor-py/bin/`:

```
monitor-py/bin/scrcpy            (scrcpy.exe on Windows)
monitor-py/bin/scrcpy-server
monitor-py/bin/adb               (adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll on Windows)
monitor-py/bin/ffmpeg            optional, joins recording parts
monitor-py/bin/lib/...           optional shared libraries scrcpy needs
monitor-py/update.json           optional, version/update metadata
monitor-py/icon.icns             optional, macOS app icon
```

Then build:

```sh
cd monitor-py
python3 -m pip install -r requirements.txt pyinstaller
pyinstaller --noconfirm scrcpy-monitor.spec
```

The single spec handles all three platforms. The icons are taken from `../app/data`.

### macOS: `dist/Scrcpy Monitor.app`

```
Scrcpy Monitor.app/Contents/
  Info.plist                 LSUIElement = true (menu bar only, no Dock icon)
  MacOS/scrcpy-monitor
  Resources/bin/             scrcpy, scrcpy-server, adb, ffmpeg
  Resources/icons/
  Resources/update.json
```

Zip it with `ditto -c -k --keepParent "dist/Scrcpy Monitor.app" scrcpy-monitor-macos-$(uname -m)-<tag>.zip`.

The app is not signed or notarized. After downloading it, remove the quarantine flag before the first launch:

```sh
xattr -dr com.apple.quarantine "/Applications/Scrcpy Monitor.app"
```

As an alternative, right-click the app, choose Open, and confirm.

### Linux: `dist/scrcpy-monitor/`

```
scrcpy-monitor/
  scrcpy-monitor             executable
  bin/                       scrcpy, scrcpy-server, adb, ffmpeg
  icons/
  install.sh
  scrcpy-monitor.desktop
  update.json
```

Ship it as `tar -C dist -czf scrcpy-monitor-linux-x86_64-<tag>.tar.gz scrcpy-monitor`.

To install, extract the archive and run `./scrcpy-monitor/install.sh`. The script copies the folder to `~/.local/opt/scrcpy-monitor` and installs `scrcpy-monitor.desktop` into `~/.local/share/applications`. Run `install.sh --uninstall` to remove both.

Some desktops have no system tray, for example GNOME without the AppIndicator extension. There, the panel opens at startup.

You may need udev rules for USB debugging; `android-sdk-platform-tools-common` provides them on Debian/Ubuntu.

## Tests

```sh
cd monitor-py
python3 -m unittest discover -s tests -v
```

The tests cover the pure logic in `scrcpy_monitor/logic.py`:

- `adb devices` parsing;
- connect-failure reasons;
- version display;
- free port blocks;
- the USB-priority decision.

## Windows test plan

The PowerShell monitor may be running at the same time and uses ports 27200+. To avoid it, run against one device on a separate port range:

```powershell
cd "D:\Charles Manalo\scrcpy\monitor-py"
python -m unittest discover -s tests
python main.py --serial 192.168.68.103:5555 --port-base 28200
python main.py --command start-recording      # wait ~10 s
python main.py --command stop-recording       # the mp4 appears under Videos\scrcpy Recordings\<device>
python main.py --command exit
```

You can also use the in-window record button, or write `start` or `stop` to `%TEMP%\scrcpy-monitor-py\control\<serial>.state.request`.

Only stop processes by the PIDs you started. The PowerShell monitor's scrcpy windows must stay open.
