import errno
import os
import subprocess
import threading
import time
from collections import OrderedDict
from datetime import datetime
from pathlib import Path

from . import logic
from .system import hidden_kwargs, kill_process

APP_FILES_OPEN = 32
APP_FILES_MAX = 500


class LogcatCapture:
    def __init__(self, adb, serial, path, label, env=None, apps=()):
        self.adb = adb
        self.serial = serial
        self.path = str(path)
        self.label = label
        self.env = env
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._file = open(self.path, 'a', encoding='utf-8')
        self.started_at = datetime.now()
        self.state = 'Waiting for device'
        self.error = None
        self.entries = 0
        self._lock = threading.Lock()
        self._children = []
        self._children_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._pids = {}
        self._missing_pids = set()
        self._pids_at = 0.0
        self._reading = serial
        self._entry_open = False
        self._entry_emitted = False
        self._entry_skipped = False
        self._entry_lines = []
        self._entry = None
        self._pending_blanks = 0
        self._indent = ''
        self._filtering = False
        self._last_key = None
        self._last_key_count = 0
        self._seen_at_last_key = 0
        self._app_files = OrderedDict()
        self._app_started = set()
        self._app_failed = set()
        self._apps = frozenset(apps)
        self._entry_app = None
        self._version_lock = threading.Lock()
        self._version_text = None
        self._version_pending = False
        self._status_time = datetime.min
        self._stopped_pids = set()

    @property
    def failed(self):
        return self.error is not None

    @property
    def size(self):
        try:
            return os.path.getsize(self.path)
        except OSError:
            return 0

    def set_apps(self, apps):
        self._apps = frozenset(apps)

    def note_versions(self, versions, force):
        text = logic.app_version_text(versions)
        with self._version_lock:
            if text is None:
                if force:
                    self._version_pending = True
                return
            if not force and not self._version_pending and text == self._version_text:
                return
            self._version_pending = False
            self._version_text = text
            self._marker('APP VERSIONS: ' + text)

    def _is_tracked(self, package):
        return package in (logic.PA_PACKAGE, logic.PIA_PACKAGE) or package in self._apps

    def _note_app_event(self, name):
        moment, pid, _, _, tag = self._entry
        if not self._entry_lines or moment < self._status_time:
            return
        found = logic.parse_app_event(tag, self._entry_lines[0])
        if found is None:
            return
        what, process, pid_text, reason = found
        process = process or name
        pid_text = pid_text or (str(pid) if what == 'APP CRASHED' else '')
        has_pid = pid_text.isdigit()
        if what == 'APP STARTED' and has_pid:
            self._pids[int(pid_text)] = process
            self._missing_pids.discard(int(pid_text))
        if not process or ':' in process or not self._is_tracked(process):
            return
        if what == 'APP STARTED' and has_pid:
            self._stopped_pids.discard(int(pid_text))
        elif what == 'APP STOPPED' and has_pid:
            if int(pid_text) in self._stopped_pids:
                return
            self._stopped_pids.add(int(pid_text))
        self._marker(f'{what}: {logic.app_label(process)}' + (f', pid {pid_text}' if has_pid else '')
                     + (f' - {reason}' if reason else ''))

    def _device_now(self, device):
        moment = logic.parse_device_time(self._run_adb(['-s', device, 'shell', "date '+%m-%d %H:%M:%S'"], 5),
                                         datetime.now())
        return moment or datetime.min

    def start(self):
        self._marker('LOGGING STARTED: ' + self.label)
        self._thread = threading.Thread(target=self._run, name=f'logcat {self.serial}', daemon=True)
        self._thread.start()
        threading.Thread(target=self._flush_loop, name=f'logcat flush {self.serial}', daemon=True).start()

    def request_stop(self):
        self._stop.set()
        self._kill_children()

    def stop(self):
        self.request_stop()
        if self._thread:
            self._thread.join(5)
        with self._lock:
            if not self._file:
                return
            text = 'LOGGING STOPPED' + (': ' + self.error if self.error else '')
            marker = logic.log_marker(text, datetime.now()) + '\n'
            for app in list(self._app_started):
                self._write_app(app, marker)
            while self._app_files:
                self._close_handle(self._app_files.popitem()[1])
            try:
                self._file.write(marker)
                self._file.flush()
            except (OSError, ValueError):
                pass
            try:
                self._file.close()
            except (OSError, ValueError):
                pass
            self._file = None

    def _marker(self, text):
        line = logic.log_marker(text, datetime.now())
        self._write(line)
        with self._lock:
            if not self._file:
                return
            for app in list(self._app_started):
                self._write_app(app, line + '\n')

    def _write(self, text, app=None):
        with self._lock:
            if not self._file:
                return
            try:
                self._file.write(text + '\n')
            except (OSError, ValueError) as error:
                self._fail(error)
                return
            if app:
                self._write_app(app, text + '\n')

    def _write_app(self, app, text):
        if self._open_app(app):
            self._write_app_file(app, text)

    def _open_app(self, app):
        handle = self._app_files.get(app)
        if handle:
            self._app_files.move_to_end(app)
            return handle
        if app in self._app_failed or (app not in self._app_started and len(self._app_started) >= APP_FILES_MAX):
            return None
        while len(self._app_files) >= APP_FILES_OPEN:
            self._close_handle(self._app_files.popitem(last=False)[1])
        try:
            path = logic.app_log_path(self.path, app)
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            handle = open(path, 'a', encoding='utf-8')
        except OSError as error:
            if error.errno not in (errno.EMFILE, errno.ENFILE):
                self._app_failed.add(app)
            return None
        except ValueError:
            self._app_failed.add(app)
            return None
        self._app_files[app] = handle
        if app not in self._app_started:
            self._app_started.add(app)
            self._write_app_file(app, logic.log_marker('LOGGING STARTED: ' + self.label, datetime.now()) + '\n')
        return self._app_files.get(app)

    def _write_app_file(self, app, text):
        handle = self._app_files.get(app)
        if not handle:
            return
        try:
            handle.write(text)
        except (OSError, ValueError):
            self._close_app(app)

    def _close_app(self, app):
        self._app_failed.add(app)
        self._close_handle(self._app_files.pop(app, None))

    @staticmethod
    def _close_handle(handle):
        if handle:
            try:
                handle.close()
            except (OSError, ValueError):
                pass

    def _flush_loop(self):
        while not self._stop.wait(1):
            with self._lock:
                if not self._file:
                    return
                try:
                    self._file.flush()
                except (OSError, ValueError) as error:
                    self._fail(error)
                for app, handle in list(self._app_files.items()):
                    try:
                        handle.flush()
                    except (OSError, ValueError):
                        self._close_app(app)

    def _fail(self, error):
        if self.error is None:
            self.error = str(error)
        self._stop.set()
        self._kill_children()

    def _kill_children(self):
        with self._children_lock:
            for child in list(self._children):
                if child.poll() is None:
                    kill_process(child)

    def _start_adb(self, args):
        with self._children_lock:
            if self._stop.is_set():
                return None
            process = subprocess.Popen([self.adb] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, env=self.env, **hidden_kwargs())
            self._children.append(process)
            return process

    def _release(self, process):
        with self._children_lock:
            if process in self._children:
                self._children.remove(process)
        if process.poll() is None:
            kill_process(process)
        try:
            process.wait(2)
        except subprocess.TimeoutExpired:
            pass
        try:
            process.stdout.close()
        except (OSError, ValueError):
            pass

    def _run_adb(self, args, timeout):
        try:
            process = self._start_adb(args)
        except OSError:
            return ''
        if not process:
            return ''
        try:
            output, _ = process.communicate(timeout=timeout)
            return (output or b'').decode('utf-8', 'replace')
        except (subprocess.TimeoutExpired, OSError, ValueError):
            return ''
        finally:
            self._release(process)

    def _run(self):
        last_boot = None
        announced = False
        quick_exits = 0
        try:
            while not self._stop.is_set():
                self.state = 'Waiting for device'
                current = self.serial
                if self._run_adb(['-s', current, 'get-state'], 5).strip() != 'device':
                    self._stop.wait(2)
                    continue
                boot = logic.boot_id(self._run_adb(['-s', current, 'shell', 'cat /proc/sys/kernel/random/boot_id'],
                                                   5))
                if self._stop.is_set():
                    break
                same_boot = last_boot is not None and (not boot or not last_boot or boot == last_boot)
                restarted = last_boot is not None and not same_boot
                if restarted:
                    self._marker('DEVICE RESTARTED: ' + current)
                elif announced:
                    self._marker('DEVICE RECONNECTED: ' + current)
                announced = False
                versions = logic.parse_app_versions(self._run_adb(['-s', current, 'shell', logic.VERSION_COMMAND], 10))
                if self._stop.is_set():
                    break
                self.note_versions(versions, restarted)
                if not same_boot:
                    self._last_key = None
                    self._last_key_count = 0
                    self._pids.clear()
                    self._missing_pids.clear()
                    self._stopped_pids.clear()
                self._filtering = same_boot and self._last_key is not None
                self._seen_at_last_key = 0
                last_boot = boot
                self._reading = current
                self._status_time = self._device_now(current)
                if self._stop.is_set():
                    break
                running = self._refresh_pids()
                if self._stop.is_set():
                    break
                self._marker('APP STATUS: ' + (logic.app_status_text(running, self._apps) if running
                                               else 'unknown (could not read the process list)'))
                self.state = 'Logging'
                began = time.monotonic()
                before = self.entries
                self._read_logcat()
                if self._stop.is_set():
                    break
                self.state = 'Waiting for device'
                if time.monotonic() - began >= 3 or self.entries != before:
                    self._marker('DEVICE DISCONNECTED: ' + current)
                    announced = True
                    quick_exits = 0
                else:
                    quick_exits += 1
                self._stop.wait(min(1 + quick_exits, 10))
        except Exception as error:
            if not self._stop.is_set():
                self._fail(error)
        finally:
            self.state = 'Stopped'

    def _read_logcat(self):
        process = self._start_adb(['-s', self._reading, 'logcat', '-v', 'long'])
        if not process:
            return
        self._entry_open = False
        self._pending_blanks = 0
        try:
            for raw in process.stdout:
                if self._stop.is_set():
                    break
                self._handle_line(raw.decode('utf-8', 'replace').rstrip('\r\n'))
        except (OSError, ValueError):
            pass
        finally:
            self._end_entry()
            self._release(process)

    def _handle_line(self, line):
        header = logic.parse_logcat_header(line, datetime.now()) if line.startswith('[ ') else None
        if header:
            self._end_entry()
            self._entry = header
            self._entry_lines = []
            self._entry_open = True
            self._entry_emitted = False
            self._entry_skipped = False
            self._pending_blanks = 0
            return
        if not self._entry_open:
            return
        if not line:
            if not self._entry_emitted:
                self._emit()
            self._pending_blanks += 1
            return
        if not self._entry_emitted:
            self._entry_lines.append(line)
            return
        if line.startswith(('--------- beginning of ', '--------- switch to ')):
            self._pending_blanks = 0
            return
        if not self._entry_skipped:
            self._write('\n' * self._pending_blanks + self._indent + line, self._entry_app)
        self._pending_blanks = 0

    def _end_entry(self):
        if self._entry_open and not self._entry_emitted:
            self._emit()
        self._entry_open = False
        self._pending_blanks = 0

    def _emit(self):
        self._entry_emitted = True
        moment, pid, tid, level, tag = self._entry
        if self._filtering:
            if moment < self._last_key or (moment == self._last_key
                                           and self._seen_at_last_key < self._last_key_count):
                if moment == self._last_key:
                    self._seen_at_last_key += 1
                self._entry_skipped = True
                return
            self._filtering = False
        if moment == self._last_key:
            self._last_key_count += 1
        else:
            self._last_key = moment
            self._last_key_count = 1
        name = self._app_name(pid)
        self._entry_app = logic.log_app(name, self._apps)
        prefix = logic.logcat_prefix(moment, pid, tid, tag, name, level)
        self._indent = ' ' * len(prefix)
        if not self._entry_lines:
            self._write(prefix.rstrip(), self._entry_app)
        else:
            self._write(prefix + ('\n' + self._indent).join(self._entry_lines), self._entry_app)
        self.entries += 1
        self._note_app_event(name)

    def _app_name(self, pid):
        name = self._pids.get(pid)
        if name is not None:
            return name
        if pid in self._missing_pids or time.monotonic() - self._pids_at < 2:
            return ''
        self._refresh_pids()
        name = self._pids.get(pid)
        if name is not None:
            return name
        self._missing_pids.add(pid)
        return ''

    def _refresh_pids(self):
        self._pids_at = time.monotonic()
        text = self._run_adb(['-s', self._reading, 'shell', 'ps -A -o PID,NAME'], 10)
        if len(text.split('\n')) <= 3:
            text = self._run_adb(['-s', self._reading, 'shell', 'ps'], 10)
        names = logic.parse_process_names(text)
        self._pids.update(names)
        if names:
            self._missing_pids.clear()
        self._pids_at = time.monotonic()
        return names
