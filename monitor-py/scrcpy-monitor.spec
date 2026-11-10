# PyInstaller spec for scrcpy monitor.
#   macOS:   dist/Scrcpy Monitor.app (menu bar only, LSUIElement)
#   Linux:   dist/scrcpy-monitor/ (scrcpy-monitor, bin/, install.sh, scrcpy-monitor.desktop)
#   Windows: dist/scrcpy-monitor/ (scrcpy-monitor.exe, bin/)
# Put scrcpy, scrcpy-server, adb (and optionally ffmpeg, ffprobe, lib/) in monitor-py/bin/ and
# optionally write monitor-py/update.json before running: pyinstaller --noconfirm scrcpy-monitor.spec
import json
import os
import sys
from pathlib import Path

ROOT = Path(SPECPATH).resolve()
REPO = ROOT.parent
IS_MAC = sys.platform == 'darwin'
IS_WINDOWS = sys.platform == 'win32'
NAME = 'scrcpy-monitor'
APP_NAME = 'Scrcpy Monitor'

sys.path.insert(0, str(ROOT))
from scrcpy_monitor.logic import display_version


def optional(source, destination):
    return [(str(source), destination)] if Path(source).exists() else []


datas = []
bin_dir = ROOT / 'bin'
if bin_dir.is_dir() and any(bin_dir.iterdir()):
    datas.append((str(bin_dir), 'bin'))
else:
    print(f'WARNING: {bin_dir} is empty or missing; the app will look for scrcpy and adb at run time.')
datas += optional(ROOT / 'update.json', '.')
datas += optional(REPO / ('scrcpy-monitor-guide.html' if IS_WINDOWS else 'scrcpy-monitor-guide-macos-linux.html'), '.')
for icon in ('scrcpy.png', 'disconnected.png'):
    datas += optional(REPO / 'app' / 'data' / icon, 'icons')
if sys.platform.startswith('linux'):
    datas += optional(ROOT / 'install.sh', '.')
    datas += optional(ROOT / 'scrcpy-monitor.desktop', '.')

version = 'dev'
try:
    version = json.loads((ROOT / 'update.json').read_text(encoding='utf-8-sig')).get('Version') or 'dev'
except (OSError, ValueError):
    pass
short_version = display_version(version) if version != 'dev' else '0.0.0'
short_version = '.'.join(short_version.split('.')[:3]) if short_version[:1].isdigit() else '0.0.0'

icon = None
if IS_MAC and (ROOT / 'icon.icns').is_file():
    icon = str(ROOT / 'icon.icns')
elif IS_WINDOWS and (REPO / 'app' / 'data' / 'icon.ico').is_file():
    icon = str(REPO / 'app' / 'data' / 'icon.ico')

a = Analysis(
    [str(ROOT / 'main.py')],
    pathex=[str(ROOT)],
    datas=datas,
    excludes=['tkinter'],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=NAME,
    console=False,
    icon=icon,
    upx=False,
    argv_emulation=False,
    contents_directory='_internal' if IS_MAC else '.',
)

coll = COLLECT(exe, a.binaries, a.datas, name=NAME, upx=False)

output = Path(DISTPATH) / NAME
if IS_MAC:
    app = BUNDLE(
        coll,
        name=f'{APP_NAME}.app',
        icon=icon,
        bundle_identifier='io.github.cktmanalo.scrcpy-monitor',
        version=short_version,
        info_plist={
            'CFBundleName': APP_NAME,
            'CFBundleDisplayName': APP_NAME,
            'CFBundleShortVersionString': short_version,
            'CFBundleVersion': display_version(version) if version != 'dev' else '0',
            'LSUIElement': True,
            'LSMinimumSystemVersion': '11.0',
            'NSHighResolutionCapable': True,
        },
    )
    output = Path(DISTPATH) / f'{APP_NAME}.app'

if not IS_WINDOWS:
    for path in output.rglob('*'):
        if path.is_file() and 'bin' in path.relative_to(output).parts and path.name != 'scrcpy-server':
            path.chmod(path.stat().st_mode | 0o755)
    for script in output.rglob('install.sh'):
        script.chmod(script.stat().st_mode | 0o755)
