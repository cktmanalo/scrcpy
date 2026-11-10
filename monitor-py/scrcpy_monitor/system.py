import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

IS_WINDOWS = sys.platform == 'win32'
IS_MAC = sys.platform == 'darwin'
IS_LINUX = sys.platform.startswith('linux')
APP_NAME = 'Scrcpy Monitor'
SOURCE_DIR = Path(__file__).resolve().parent.parent
FROZEN = bool(getattr(sys, 'frozen', False))
CREATE_NO_WINDOW = 0x08000000


def system_name():
    if IS_WINDOWS:
        return 'windows'
    if IS_MAC:
        return 'darwin'
    return 'linux'


def _xdg(name, default):
    value = os.environ.get(name)
    return Path(value) if value and os.path.isabs(value) else Path.home() / default


def _linux_videos_dir():
    value = os.environ.get('XDG_VIDEOS_DIR')
    if not value:
        try:
            config = _xdg('XDG_CONFIG_HOME', '.config') / 'user-dirs.dirs'
            for line in config.read_text(encoding='utf-8').splitlines():
                match = re.match(r'^\s*XDG_VIDEOS_DIR\s*=\s*"?(.*?)"?\s*$', line)
                if match:
                    value = match.group(1).replace('$HOME', str(Path.home()))
        except OSError:
            pass
    if value and os.path.isabs(value) and Path(value) != Path.home():
        return Path(value)
    return Path.home() / 'Videos'


class Paths:
    def __init__(self):
        home = Path.home()
        if IS_WINDOWS:
            local = Path(os.environ.get('LOCALAPPDATA') or home / 'AppData' / 'Local')
            temp = Path(os.environ.get('TEMP') or local / 'Temp')
            self.data = local / 'scrcpy-monitor-py'
            self.state = temp / 'scrcpy-monitor-py'
            self.logs = self.state / 'logs'
            self.log_file = self.state / 'scrcpy-monitor.log'
            self.default_record_dir = home / 'Videos' / 'scrcpy Recordings'
        elif IS_MAC:
            self.data = home / 'Library' / 'Application Support' / APP_NAME
            self.state = self.data / 'state'
            self.logs = home / 'Library' / 'Logs' / APP_NAME
            self.log_file = self.logs / 'scrcpy-monitor.log'
            self.default_record_dir = home / 'Movies' / 'Scrcpy Recordings'
        else:
            self.data = _xdg('XDG_DATA_HOME', '.local/share') / 'scrcpy-monitor'
            self.state = _xdg('XDG_STATE_HOME', '.local/state') / 'scrcpy-monitor'
            self.logs = self.state / 'logs'
            self.log_file = self.logs / 'scrcpy-monitor.log'
            self.default_record_dir = _linux_videos_dir() / 'Scrcpy Recordings'
        self.control = self.state / 'control'
        self.settings = self.data / 'settings.json'
        self.known_wifi = self.data / 'wifi-devices.json'
        self.scan_ports = self.data / 'scan-ports.json'
        self.encoder_cache = self.state / 'encoders.json'
        self.update_dir = self.state / 'update'

    def create(self):
        for folder in (self.data, self.state, self.logs, self.control):
            folder.mkdir(parents=True, exist_ok=True)


_log_lock = threading.Lock()
_log_path = None


def set_log_path(path):
    global _log_path
    _log_path = path


def log(message):
    line = f'{datetime.now():%Y-%m-%d %H:%M:%S} {message}'
    with _log_lock:
        if _log_path:
            try:
                with open(_log_path, 'a', encoding='utf-8') as handle:
                    handle.write(line + '\n')
            except OSError:
                pass
        try:
            if sys.stdout:
                print(line, flush=True)
        except (OSError, ValueError):
            pass


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8-sig') as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    with open(temp, 'w', encoding='utf-8') as handle:
        json.dump(value, handle, indent=2)
    os.replace(temp, path)


def get_setting(path, name):
    settings = read_json(path, {})
    return settings.get(name) if isinstance(settings, dict) else None


def set_setting(path, name, value):
    settings = read_json(path, {})
    if not isinstance(settings, dict):
        settings = {}
    settings[name] = value
    write_json(path, settings)


def exe_name(name):
    return name + '.exe' if IS_WINDOWS else name


def mac_bundle_path():
    if not (IS_MAC and FROZEN):
        return None
    path = Path(sys.executable).resolve()
    for parent in path.parents:
        if parent.suffix == '.app':
            return parent
    return None


def resource_dirs():
    dirs = []
    if FROZEN:
        meipass = getattr(sys, '_MEIPASS', None)
        if meipass:
            dirs.append(Path(meipass))
        exe_dir = Path(sys.executable).resolve().parent
        dirs.append(exe_dir)
        bundle = mac_bundle_path()
        if bundle:
            dirs += [bundle / 'Contents' / 'Resources', bundle / 'Contents' / 'Frameworks']
    dirs.append(SOURCE_DIR)
    unique = []
    for folder in dirs:
        if folder not in unique:
            unique.append(folder)
    return unique


def bin_dirs():
    return [folder / 'bin' for folder in resource_dirs()]


def find_resource(name):
    for folder in resource_dirs():
        candidate = folder / name
        if candidate.is_file():
            return candidate
    return None


def _usable(path):
    if not path or not os.path.isfile(path):
        return False
    if not IS_WINDOWS and not os.access(path, os.X_OK):
        try:
            os.chmod(path, os.stat(path).st_mode | 0o111)
        except OSError:
            return False
    return True


def platform_tool_dirs(name):
    if IS_MAC:
        return [Path('/opt/homebrew/bin'), Path('/usr/local/bin')]
    if IS_LINUX:
        return [Path('/usr/bin'), Path('/usr/local/bin')]
    dirs = []
    if name == 'scrcpy':
        dirs.append(Path(r'D:\Charles Manalo\scrcpy\x\app'))
    elif name == 'adb':
        local = os.environ.get('LOCALAPPDATA')
        if local:
            dirs.append(Path(local) / 'Android' / 'Sdk' / 'platform-tools')
    else:
        dirs += [Path(r'D:\msys64\mingw64\bin'), Path(r'C:\msys64\mingw64\bin')]
    return dirs


def find_tool(name, env_var=None, explicit=None):
    if explicit:
        return str(Path(explicit).resolve()) if _usable(explicit) else None
    file_name = exe_name(name)
    for folder in bin_dirs():
        if _usable(folder / file_name):
            return str(folder / file_name)
    if env_var and _usable(os.environ.get(env_var)):
        return str(Path(os.environ[env_var]).resolve())
    found = shutil.which(name)
    if found:
        return found
    for folder in platform_tool_dirs(name):
        if _usable(folder / file_name):
            return str(folder / file_name)
    return None


def find_server(scrcpy):
    explicit = os.environ.get('SCRCPY_SERVER_PATH')
    if explicit and os.path.isfile(explicit):
        return explicit
    folder = Path(scrcpy).resolve().parent
    for candidate in (folder / 'scrcpy-server', folder.parent / 'server' / 'scrcpy-server'):
        if candidate.is_file():
            return str(candidate)
    return None


def find_icon_dir(scrcpy):
    folder = Path(scrcpy).resolve().parent
    candidates = [folder] + [parent / 'app' / 'data' for parent in list(folder.parents)[:3]]
    for candidate in candidates:
        if (candidate / 'scrcpy.png').is_file():
            return str(candidate)
    return None


def find_library_dir(scrcpy):
    if IS_WINDOWS:
        folder = Path(scrcpy).resolve().parent
        for candidate in [folder] + platform_tool_dirs('ffmpeg'):
            if (candidate / 'SDL3.dll').is_file():
                return str(candidate)
        return None
    lib = Path(scrcpy).resolve().parent / 'lib'
    return str(lib) if lib.is_dir() else None


def hidden_kwargs(new_group=True):
    if IS_WINDOWS:
        return {'creationflags': CREATE_NO_WINDOW}
    return {'start_new_session': new_group}


def run_hidden(args, timeout=10, env=None, include_stderr=False):
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, **hidden_kwargs())
    except OSError as error:
        log(f'{args[0]} {" ".join(args[1:])} failed: {error}')
        return ''
    out, err = [], []
    readers = [threading.Thread(target=lambda: out.append(process.stdout.read()), daemon=True),
               threading.Thread(target=lambda: err.append(process.stderr.read()), daemon=True)]
    for reader in readers:
        reader.start()
    try:
        process.wait(timeout)
    except subprocess.TimeoutExpired:
        kill_process(process)
        return ''
    readers[0].join(2)
    if not out:
        return ''
    text = out[0].decode('utf-8', 'replace')
    if include_stderr:
        readers[1].join(2)
        if err:
            text += '\n' + err[0].decode('utf-8', 'replace')
    return text


def kill_process(process):
    try:
        process.kill()
    except OSError:
        pass


def kill_tree(pid):
    if IS_WINDOWS:
        run_hidden([os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'taskkill.exe'),
                    '/PID', str(pid), '/T', '/F'], 10)
        return
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def helper_command(*args):
    if FROZEN:
        return [sys.executable] + list(args)
    return [sys.executable, str(SOURCE_DIR / 'main.py')] + list(args)


def send_interrupt(process):
    if process.poll() is not None:
        return None
    if not IS_WINDOWS:
        try:
            os.kill(process.pid, signal.SIGINT)
        except OSError as error:
            log(f'Could not send SIGINT to process {process.pid}: {error}')
        return None
    try:
        return subprocess.Popen(helper_command('--send-ctrl-c', str(process.pid)), stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **hidden_kwargs())
    except OSError as error:
        log(f'Could not send Ctrl+C to process {process.pid}: {error}')
        return None


def send_ctrl_c_main(pid):
    import ctypes
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(ctypes.c_uint32(pid)):
        return 2
    kernel32.SetConsoleCtrlHandler(None, True)
    sent = kernel32.GenerateConsoleCtrlEvent(0, 0)
    time.sleep(0.2)
    kernel32.FreeConsole()
    return 0 if sent else 3


def stop_gracefully(process, timeout=15):
    if process.poll() is not None:
        return True
    helper = send_interrupt(process)
    if helper:
        try:
            helper.wait(15)
        except subprocess.TimeoutExpired:
            kill_process(helper)
    try:
        process.wait(timeout)
        return True
    except subprocess.TimeoutExpired:
        pass
    log(f'Process {process.pid} did not stop gracefully; killing it.')
    kill_tree(process.pid)
    try:
        process.wait(5)
    except subprocess.TimeoutExpired:
        pass
    return False


def has_visible_window(pid):
    if not IS_WINDOWS:
        return False
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    found = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def callback(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd) and not user32.GetWindow(hwnd, 4):
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(callback_type(callback), 0)
    return bool(found)


class ScrcpyProcess:
    SHOWN = re.compile(r'INFO: (Texture|Renderer)\b')

    def __init__(self, args, log_file, env):
        self.log_file = log_file
        self.output_shown = False
        self.process = None
        master = None
        if IS_WINDOWS:
            self.process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, env=env, **hidden_kwargs())
            source = self.process.stdout
        else:
            import pty
            master, slave = pty.openpty()
            try:
                self.process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, env=env,
                                                start_new_session=True)
            except OSError:
                os.close(master)
                raise
            finally:
                os.close(slave)
            source = master
        self.pid = self.process.pid
        threading.Thread(target=self._read, args=(source,), daemon=True).start()

    def _read(self, source):
        try:
            handle = open(self.log_file, 'wb')
        except OSError:
            handle = None
        pending = b''
        try:
            while True:
                try:
                    chunk = source.read1(4096) if hasattr(source, 'read1') else os.read(source, 4096)
                except (OSError, ValueError):
                    break
                if not chunk:
                    break
                if handle:
                    handle.write(chunk)
                    handle.flush()
                if not self.output_shown:
                    pending = (pending + chunk)[-4096:]
                    if self.SHOWN.search(pending.decode('utf-8', 'replace')):
                        self.output_shown = True
        finally:
            if handle:
                handle.close()
            if isinstance(source, int):
                try:
                    os.close(source)
                except OSError:
                    pass

    @property
    def shown(self):
        if self.output_shown:
            return True
        if IS_WINDOWS and self.process.poll() is None:
            try:
                self.output_shown = has_visible_window(self.pid)
            except (OSError, AttributeError, ValueError):
                pass
        return self.output_shown

    def poll(self):
        return self.process.poll()

    @property
    def exited(self):
        return self.process.poll() is not None

    @property
    def returncode(self):
        return self.process.returncode

    def wait(self, timeout):
        try:
            self.process.wait(timeout)
            return True
        except subprocess.TimeoutExpired:
            return False


class BackgroundCommand:
    def __init__(self, args, env=None):
        self.started = time.monotonic()
        self.output = []
        self.process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, env=env, **hidden_kwargs())
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            self.output.append(self.process.stdout.read())
        except (OSError, ValueError):
            pass

    def complete(self, timeout=20):
        if self.process.poll() is None:
            if time.monotonic() - self.started < timeout:
                return None
            kill_process(self.process)
            try:
                self.process.wait(2)
            except subprocess.TimeoutExpired:
                pass
        self.reader.join(1)
        return b''.join(self.output).decode('utf-8', 'replace').strip()

    def kill(self):
        if self.process.poll() is None:
            kill_process(self.process)


def list_processes():
    result = []
    if IS_WINDOWS:
        script = ("Get-CimInstance Win32_Process -Filter \"Name='adb.exe'\" | ForEach-Object { "
                  "'{0}`t{1}`t{2}' -f $_.ProcessId, $_.ParentProcessId, $_.CommandLine }")
        output = run_hidden(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script], 20)
    else:
        output = run_hidden(['ps', '-axww', '-o', 'pid=,ppid=,args='], 10)
    for line in output.splitlines():
        parts = line.split('\t', 2) if IS_WINDOWS else line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].strip().isdigit() and parts[1].strip().isdigit():
            result.append((int(parts[0]), int(parts[1]), parts[2]))
    return result


def pid_alive(pid):
    if IS_WINDOWS:
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(handle)
        return code.value == 259
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def open_path(path):
    from PySide6.QtCore import QUrl
    from PySide6.QtGui import QDesktopServices
    QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
