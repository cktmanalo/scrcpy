import os
import queue
import re
import select
import socket
import subprocess
import threading
import time
import traceback
import uuid
from datetime import datetime, timedelta
from pathlib import Path

from . import logic
from .logic import connection_type, safe_name
from .system import (IS_WINDOWS, BackgroundCommand, ScrcpyProcess, hidden_kwargs, kill_process, kill_tree,
                     list_processes, log, pid_alive, read_json, run_hidden, send_interrupt, stop_gracefully,
                     write_json)


def _seconds(delta):
    return delta.total_seconds()


class Session:
    def __init__(self, serial, port, control_path, software_encoder, record_pending):
        now = datetime.now()
        self.serial = serial
        self.port = port
        self.safe_serial = safe_name(serial)
        self.name = None
        self.title = serial
        self.connection = connection_type(serial)
        self.last_state = None
        self.booted_at = None
        self.next_connect = now
        self.connector = None
        self.user_closed = False
        self.disconnected = False
        self.missing_since = None
        self.pending_action = None
        self.moved_to = None
        self.move_address = None
        self.move_deadline = now
        self.display = None
        self.display_started_at = None
        self.window_shown = False
        self.next_wake = now
        self.display_failures = 0
        self.next_display_attempt = now
        self.recording = False
        self.recording_started_at = None
        self.recording_base = None
        self.parts = []
        self.recorder = None
        self.recorder_started_at = None
        self.recorder_part = None
        self.recorder_log = None
        self.recorder_failures = 0
        self.next_record_attempt = now
        self.software_encoder = software_encoder
        self.control_path = control_path
        self.stopping = False
        self.record_pending = record_pending
        self.combine_member = None
        self.part_starts = {}
        self.part_start_pending = False


class SessionView:
    __slots__ = ('serial', 'title', 'connection', 'status', 'recording_text', 'recording', 'user_closed',
                 'disconnected', 'standby', 'last_state', 'moved_to', 'stopping')

    def __init__(self, **values):
        for key, value in values.items():
            setattr(self, key, value)


class Snapshot:
    def __init__(self, sessions=(), **values):
        self.sessions = list(sessions)
        self.discovery_status = values.get('discovery_status', 'Wi-Fi scan: waiting')
        self.scan_enabled = values.get('scan_enabled', False)
        self.record_dir = values.get('record_dir', '')
        self.merges = values.get('merges', 0)
        self.combines = values.get('combines', 0)
        self.combine_active = values.get('combine_active', False)
        self.connecting = values.get('connecting', [])
        self.exiting = values.get('exiting', False)
        self.scan_ports = values.get('scan_ports', list(logic.DEFAULT_SCAN_PORTS))
        self.discovery_off = values.get('discovery_off', False)


class Options:
    def __init__(self, **values):
        self.serials = []
        self.record = False
        self.record_dir = None
        self.record_encoder = 'auto'
        self.record_args = []
        self.keep_parts = False
        self.no_discovery = False
        self.scrcpy_args = []
        self.port_base = logic.PORT_BASE
        self.poll_seconds = 2
        self.__dict__.update(values)


class Tools:
    def __init__(self, scrcpy, adb, ffmpeg, ffprobe, env):
        self.scrcpy = scrcpy
        self.adb = adb
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.env = env


class Probe:
    def __init__(self, targets):
        self.targets = list(targets)
        self.open = []
        self.cancelled = False
        self.done = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            for start in range(0, len(self.targets), 400):
                if self.cancelled:
                    break
                self._batch(self.targets[start:start + 400])
        finally:
            self.done.set()

    def _batch(self, batch):
        pending = {}
        for address in batch:
            ip, port = address.rsplit(':', 1)
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setblocking(False)
            try:
                sock.connect_ex((ip, int(port)))
                pending[sock] = address
            except OSError:
                sock.close()
        deadline = time.monotonic() + 1.5
        try:
            while pending and not self.cancelled:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                sockets = list(pending)
                _, writable, failed = select.select([], sockets, sockets, min(remaining, 0.5))
                for sock in set(writable) | set(failed):
                    address = pending.pop(sock, None)
                    if address is None:
                        continue
                    if sock in writable and sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0:
                        self.open.append(address)
                    sock.close()
        finally:
            for sock in pending:
                sock.close()

    def complete(self):
        return list(self.open) if self.done.is_set() else None

    def stop(self):
        self.cancelled = True


def local_networks():
    from PySide6.QtNetwork import QAbstractSocket, QNetworkInterface
    skip = re.compile(r'virtualbox|vmware|vethernet|hyper-v|docker|^veth|^br-|wsl|tailscale|zerotier|^utun|^awdl|^llw',
                      re.I)
    networks = []
    for nic in QNetworkInterface.allInterfaces():
        flags = nic.flags()
        if not (flags & QNetworkInterface.InterfaceFlag.IsUp) or not (flags & QNetworkInterface.InterfaceFlag.IsRunning):
            continue
        if flags & QNetworkInterface.InterfaceFlag.IsLoopBack:
            continue
        if nic.type() in (QNetworkInterface.InterfaceType.Loopback, QNetworkInterface.InterfaceType.Virtual):
            continue
        if skip.search(nic.humanReadableName()) or skip.search(nic.name()):
            continue
        for entry in nic.addressEntries():
            address = entry.ip()
            if address.protocol() != QAbstractSocket.NetworkLayerProtocol.IPv4Protocol:
                continue
            text = address.toString()
            if text.startswith('169.254.') or text.startswith('127.'):
                continue
            networks.append((text, entry.prefixLength()))
    return networks


class Engine:
    def __init__(self, options, paths, tools):
        self.options = options
        self.paths = paths
        self.tools = tools
        self.serial_filter = list(options.serials)
        self.record_dir = options.record_dir
        self.queue = queue.Queue()
        self.ui_events = queue.Queue()
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self._run, name='engine', daemon=True)
        self._tick_queued = False
        self._fast_queued = False
        self._queue_lock = threading.Lock()
        self.panel_visible = False
        self.has_panel = True
        self.panel_pending = False
        self.sessions = {}
        self.merges = []
        self.combines = []
        self.combine_handovers = []
        self.combine_encoder = None
        self.stops = []
        self.connects = []
        self.discovery = None
        self.next_discovery = datetime.now()
        self.discovery_retry = {}
        self.discovery_status = 'Wi-Fi scan: waiting'
        self.probe = None
        self.probe_requested = True
        self.scanning = False
        self.scan_found = set()
        self.known_wifi = self._read_known_wifi()
        self.saved_scan_ports = self._read_scan_ports()
        self.delayed_connects = {}
        self.moved_usb = {}
        self.removed_serials = set()
        self.standby = {}
        self.wifi_serials = {}
        self.exiting = False
        self.open_windows_requested = False
        self.scrcpy_version = ''
        self.snapshot = Snapshot(record_dir=str(self.record_dir))

    def start(self):
        self.thread.start()

    def post(self, action):
        self.queue.put(action)

    def post_tick(self):
        with self._queue_lock:
            if self._tick_queued:
                return
            self._tick_queued = True
        self.queue.put('tick')

    def post_fast(self):
        with self._queue_lock:
            if self._fast_queued:
                return
            self._fast_queued = True
        self.queue.put('fast')

    request_tick = post_tick

    def _run(self):
        try:
            self.adb(['start-server'], 15)
            first = [line for line in run_hidden([self.tools.scrcpy, '--version'], 5, self.tools.env).splitlines()
                     if line.startswith('scrcpy ')]
            match = re.match(r'^scrcpy\s+(\S+)', first[0]) if first else None
            self.scrcpy_version = match.group(1) if match else ''
        except Exception:
            log('ERROR: ' + traceback.format_exc())
        while True:
            item = self.queue.get()
            try:
                if item == 'tick':
                    with self._queue_lock:
                        self._tick_queued = False
                    self.tick()
                elif item == 'fast':
                    with self._queue_lock:
                        self._fast_queued = False
                    if not self.exiting:
                        self.invoke_control_requests()
                        self.update_stops()
                        self.update_part_starts()
                elif item == 'exit':
                    self.stop_monitor()
                elif callable(item):
                    if not self.exiting:
                        item()
            except Exception:
                log('ERROR: ' + traceback.format_exc())
            if self.finished.is_set():
                break
            self.publish()

    def notify(self, message, icon='info'):
        log(message)
        self.ui_events.put(('notify', message, icon))

    def message(self, text, icon='warning'):
        self.ui_events.put(('message', text, icon))

    def confirm(self, text, action):
        self.ui_events.put(('confirm', text, action))

    def adb(self, args, timeout=10):
        return run_hidden([self.tools.adb] + list(args), timeout)

    def get_devices(self):
        return logic.parse_adb_devices(self.adb(['devices']))

    def get_prop(self, serial, name):
        return self.adb(['-s', serial, 'shell', 'getprop', name], 5).strip()

    def record_codec(self):
        codec = 'h264'
        for arg in self.options.record_args:
            match = re.match(r'^--video-codec=(\S+)$', arg)
            if match:
                codec = match.group(1)
        return codec

    def encoder_cache_keys(self, serial, model=None):
        codec = self.record_codec()
        keys = [f'{serial}|{codec}']
        if model and model != serial:
            keys.append(f'model:{model}|{codec}')
        return keys

    def get_cached_encoder(self, serial, model=None):
        cache = read_json(self.paths.encoder_cache, {}) or {}
        if not isinstance(cache, dict):
            return None
        for key in self.encoder_cache_keys(serial, model):
            if cache.get(key):
                return str(cache[key])
        return None

    def set_cached_encoder(self, serial, encoder, model=None):
        cache = read_json(self.paths.encoder_cache, {}) or {}
        if not isinstance(cache, dict):
            cache = {}
        for key in self.encoder_cache_keys(serial, model):
            if encoder:
                cache[key] = encoder
            else:
                cache.pop(key, None)
        try:
            write_json(self.paths.encoder_cache, cache)
        except OSError:
            pass

    def get_software_encoder(self, serial):
        codec = self.record_codec()
        output = run_hidden([self.tools.scrcpy, '-s', serial, '--list-encoders'], 30, self.tools.env, True)
        encoder = logic.parse_software_encoder(output, codec)
        if encoder:
            return encoder
        tail = ' | '.join([line for line in output.splitlines() if line][-5:])
        log(f'[{serial}] Could not list encoders: {tail}')
        try:
            sdk = int(self.get_prop(serial, 'ro.build.version.sdk'))
        except ValueError:
            sdk = 0
        return logic.known_software_encoder(codec, sdk)

    def test_video_file(self, path):
        try:
            if Path(path).stat().st_size < 1024:
                return False
        except OSError:
            return False
        if not self.tools.ffprobe:
            return True
        output = run_hidden([self.tools.ffprobe, '-v', 'error', '-show_entries', 'format=duration', '-of',
                             'default=nw=1:nk=1', str(path)], 30).strip()
        try:
            return float(output) > 0
        except ValueError:
            return False

    def new_session(self, serial):
        port = logic.free_port_block([s.port for s in self.sessions.values()], self.options.port_base)
        encoder = self.get_cached_encoder(serial) if self.options.record_encoder == 'auto' else None
        control = str(self.paths.control / f'{safe_name(serial)}.state')
        session = Session(serial, port, control, encoder, self.options.record)
        self.sessions[serial] = session
        self.set_record_state(session)
        return session

    def set_record_state(self, session):
        try:
            Path(session.control_path).write_text('1' if session.recording else '0', encoding='ascii')
        except OSError as error:
            log(f'[{session.serial}] Could not write {session.control_path}: {error}')

    def invoke_control_requests(self):
        for session in list(self.sessions.values()):
            path = Path(session.control_path + '.request')
            if not path.exists():
                continue
            try:
                request = path.read_text(encoding='utf-8', errors='replace').strip()
                path.unlink()
            except OSError:
                continue
            log(f'[{session.serial}] Record button: {request}')
            if request == 'start':
                self.start_recording(session)
            elif request == 'stop':
                self.stop_recording(session)
            self.set_record_state(session)

    def test_device_ready(self, session, devices):
        if devices.get(session.serial) != 'device':
            return False
        if self.get_prop(session.serial, 'sys.boot_completed') != '1':
            return False
        if not session.booted_at:
            session.booted_at = datetime.now()
        if not session.name:
            model = self.get_prop(session.serial, 'ro.product.model')
            session.name = model or session.serial
            session.title = f'{model} ({session.serial})' if model else session.serial
        return True

    def stop_orphan_servers(self, serial):
        pattern = re.compile(r'"?-s"?\s+"?' + re.escape(serial) + r'"?\s+"?shell"?\s.*app_process.*scid=([0-9a-f]+)')
        try:
            processes = list_processes()
        except Exception:
            return
        by_pid = {p[0]: p for p in processes}
        for pid, ppid, command in processes:
            if not IS_WINDOWS:
                first = command.split(None, 1)[0] if command.strip() else ''
                if Path(first).name != 'adb':
                    continue
            match = pattern.search(command)
            if not match:
                continue
            if IS_WINDOWS:
                orphan = not pid_alive(ppid)
            else:
                parent = by_pid.get(ppid)
                orphan = ppid <= 1 or not parent or 'scrcpy' not in parent[2]
            if not orphan:
                continue
            scid = match.group(1)
            log(f'[{serial}] Killing orphaned scrcpy server (adb pid {pid}).')
            kill_tree(pid)
            for line in self.adb(['forward', '--list'], 5).splitlines():
                forward = re.match(r'^\S+\s+(tcp:\d+)\s+localabstract:scrcpy_' + scid + r'$', line.strip())
                if forward:
                    self.adb(['-s', serial, 'forward', '--remove', forward.group(1)], 5)

    def start_scrcpy(self, args, log_file):
        return ScrcpyProcess([self.tools.scrcpy] + args, str(log_file), self.tools.env)

    def start_display(self, session):
        scrcpy_args = self.options.scrcpy_args
        args = ['-s', session.serial, '--reconnect', f'--record-control={session.control_path}']
        if not any(a.startswith('--window-title') for a in scrcpy_args):
            args.append(f'--window-title={session.title}')
        if not logic.has_port_arg(scrcpy_args):
            args.append(f'--port={session.port}:{session.port + 1}')
        args += scrcpy_args
        log_file = self.paths.logs / f'{session.safe_serial}-display.log'
        self.stop_orphan_servers(session.serial)
        log(f'[{session.serial}] Starting scrcpy window: {subprocess.list2cmdline(args)}')
        session.display = self.start_scrcpy(args, log_file)
        session.display_started_at = datetime.now()
        session.window_shown = False
        session.next_wake = datetime.now() + timedelta(seconds=5)
        if self.panel_pending:
            self.panel_pending = False
            self.ui_events.put(('show_panel',))

    def update_display(self, session, devices, ready):
        now = datetime.now()
        if session.display:
            if not session.display.exited:
                if session.window_shown:
                    return
                if session.display.shown:
                    session.window_shown = True
                    return
                if now >= session.next_wake:
                    session.next_wake = now + timedelta(seconds=10)
                    log(f'[{session.serial}] No video yet; waking the device screen.')
                    self.adb(['-s', session.serial, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'], 3)
                return
            exit_code = session.display.returncode
            ran = _seconds(now - session.display_started_at)
            session.display = None
            if exit_code == 0:
                session.user_closed = True
                log(f'[{session.serial}] scrcpy window closed by user; no longer monitoring.')
                self.stop_recording(session)
                return
            if ran >= 30:
                session.display_failures = 0
            session.display_failures += 1
            delay = 2 if exit_code == 2 else min(5 * session.display_failures, 30)
            session.next_display_attempt = now + timedelta(seconds=delay)
            log(f'[{session.serial}] scrcpy window exited with code {exit_code}; retrying in {delay}s '
                f'(log: {self.paths.logs / (session.safe_serial + "-display.log")}).')
        if now < session.next_display_attempt:
            return
        if ready[0] is None:
            ready[0] = self.test_device_ready(session, devices)
        if not ready[0]:
            return
        try:
            self.start_display(session)
        except Exception as error:
            session.display_failures += 1
            session.next_display_attempt = now + timedelta(seconds=min(5 * session.display_failures, 30))
            log(f'[{session.serial}] Failed to start scrcpy: {error}')

    def start_recording(self, session):
        if session.recording or session.user_closed or session.serial in self.standby:
            return
        session.recording = True
        session.recording_started_at = datetime.now()
        session.recording_base = None
        session.parts = []
        session.recorder_failures = 0
        session.next_record_attempt = datetime.now()
        self.set_record_state(session)
        for old in self.paths.logs.glob(f'{session.safe_serial}-record*.log'):
            try:
                old.unlink()
            except OSError:
                pass
        self.notify(f'Recording requested for {session.title}.')

    def start_recorder_part(self, session):
        if not session.recording_base:
            device_name = safe_name(session.name or '') or session.safe_serial
            folder = Path(self.record_dir) / device_name
            folder.mkdir(parents=True, exist_ok=True)
            stem = f'Screen_Recording_{device_name}_{session.recording_started_at:%Y%m%d_%H%M%S}'
            base = folder / stem
            suffix = 2
            while (Path(f'{base}.mp4').exists() or Path(f'{base}_part01.mp4').exists()
                   or any(s is not session and s.recording_base == str(base) for s in self.sessions.values())):
                base = folder / f'{stem}_{suffix}'
                suffix += 1
            session.recording_base = str(base)
        if self.options.record_encoder == 'auto' and not session.software_encoder:
            session.software_encoder = self.get_cached_encoder(session.serial, session.name)
        number = len(session.parts) + 1
        part = f'{session.recording_base}_part{number:02d}.mp4'
        args = ['-s', session.serial, '--no-window', '--no-playback', '--no-control', f'--record={part}',
                '--record-format=mp4']
        if self.options.record_encoder != 'auto':
            args.append(f'--video-encoder={self.options.record_encoder}')
        elif session.software_encoder:
            args.append(f'--video-encoder={session.software_encoder}')
        if not logic.has_port_arg(self.options.record_args):
            args.append(f'--port={session.port + 2}:{session.port + 3}')
        args += self.options.record_args
        session.recorder_log = str(self.paths.logs / f'{session.safe_serial}-record-part{number:02d}.log')
        self.stop_orphan_servers(session.serial)
        log(f'[{session.serial}] Starting recorder: {subprocess.list2cmdline(args)}')
        session.recorder = self.start_scrcpy(args, session.recorder_log)
        session.recorder_started_at = datetime.now()
        session.recorder_part = part
        session.parts.append(part)
        if session.combine_member:
            session.part_starts[part] = session.recorder_started_at
            session.part_start_pending = True

    def update_part_starts(self):
        for session in [s for s in self.sessions.values() if s.part_start_pending]:
            part = session.recorder_part
            if not session.combine_member or not part or part not in session.part_starts:
                session.part_start_pending = False
                continue
            try:
                if Path(part).stat().st_size > 0:
                    session.part_starts[part] = datetime.now()
                    session.part_start_pending = False
            except FileNotFoundError:
                pass
            except OSError:
                session.part_start_pending = False

    def test_encoder_failure(self, session):
        if self.options.record_encoder != 'auto' or session.software_encoder:
            return False
        if _seconds(datetime.now() - session.recorder_started_at) > 60:
            return False
        try:
            return 'CodecException' in Path(session.recorder_log).read_text(encoding='utf-8', errors='replace')
        except OSError:
            return False

    def remove_recorder_part(self, session):
        if session.recorder_part in session.parts:
            session.parts.remove(session.recorder_part)
        try:
            Path(session.recorder_part).unlink()
        except OSError:
            pass

    def update_recorder(self, session, devices, ready):
        now = datetime.now()
        if session.recorder:
            recorder = session.recorder
            encoder_failed = self.test_encoder_failure(session)
            stalled = (not encoder_failed and not recorder.exited
                       and _seconds(now - session.recorder_started_at) > 20 and not Path(session.recorder_part).exists())
            if not recorder.exited and not encoder_failed and not stalled:
                return
            if not recorder.exited:
                kill_tree(recorder.pid)
                recorder.wait(5)
            exit_code = recorder.returncode if recorder.exited else -1
            ran = _seconds(now - session.recorder_started_at)
            session.recorder = None
            if stalled:
                self.remove_recorder_part(session)
                session.recorder_failures += 1
                session.next_record_attempt = now + timedelta(seconds=min(3 * session.recorder_failures, 30))
                log(f'[{session.serial}] Recorder did not start recording within 20s; retrying.')
            elif encoder_failed:
                self.remove_recorder_part(session)
                encoder = self.get_software_encoder(session.serial)
                if encoder:
                    session.software_encoder = encoder
                    self.set_cached_encoder(session.serial, encoder, session.name)
                    session.next_record_attempt = now
                    log(f'[{session.serial}] Hardware encoder busy; recording with software encoder {encoder}.')
                else:
                    session.recorder_failures += 1
                    session.next_record_attempt = now + timedelta(seconds=min(5 * session.recorder_failures, 30))
                    log(f'[{session.serial}] Hardware encoder busy and no software encoder found yet; retrying.')
            elif exit_code == 1:
                if ran >= 30:
                    session.recorder_failures = 0
                session.recorder_failures += 1
                if session.recorder_failures == 5:
                    if session.software_encoder:
                        session.software_encoder = None
                        self.set_cached_encoder(session.serial, None, session.name)
                    self.notify(f'Recording for {session.title} keeps failing; still retrying '
                                f'(log: {session.recorder_log}).', 'warning')
                session.next_record_attempt = now + timedelta(seconds=min(3 * session.recorder_failures, 30))
                log(f'[{session.serial}] Recorder failed (code {exit_code}); retrying.')
            else:
                session.booted_at = None
                session.next_record_attempt = now
                log(f'[{session.serial}] Recorder exited with code {exit_code}; recording resumes in a new part when '
                    f'the device is ready.')
        if not session.recording or session.stopping or now < session.next_record_attempt:
            return
        if not session.display or _seconds(now - session.display_started_at) < 5:
            return
        if ready[0] is None:
            ready[0] = self.test_device_ready(session, devices)
        if not ready[0]:
            return
        if not session.booted_at or _seconds(now - session.booted_at) < 4:
            return
        try:
            self.start_recorder_part(session)
        except Exception as error:
            session.recorder_failures += 1
            session.next_record_attempt = now + timedelta(seconds=5 * session.recorder_failures)
            log(f'[{session.serial}] Failed to start recorder: {error}')

    def stop_recording(self, session):
        if not session.recording:
            return
        session.recording = False
        self.set_record_state(session)
        stop = {'session': session, 'recorder': session.recorder, 'helper': None,
                'deadline': datetime.now() + timedelta(seconds=30), 'killed': False, 'title': session.title,
                'base': session.recording_base, 'parts': list(session.parts), 'member': session.combine_member,
                'starts': session.part_starts}
        session.recorder = None
        session.parts = []
        session.combine_member = None
        session.part_starts = {}
        session.part_start_pending = False
        session.stopping = True
        if stop['recorder'] and not stop['recorder'].exited:
            stop['helper'] = send_interrupt(stop['recorder'].process)
        self.stops.append(stop)
        self.update_stops()

    def update_stops(self, timeout=0):
        deadline = time.monotonic() + timeout
        while True:
            for stop in list(self.stops):
                now = datetime.now()
                helper = stop['helper']
                if helper and helper.poll() is not None:
                    stop['helper'] = None
                recorder = stop['recorder']
                if recorder and not recorder.exited:
                    if now < stop['deadline']:
                        continue
                    if not stop['killed']:
                        log(f'Process {recorder.pid} did not stop gracefully; killing it.')
                        kill_tree(recorder.pid)
                        stop['killed'] = True
                        stop['deadline'] = now + timedelta(seconds=5)
                        continue
                if stop['helper']:
                    kill_process(stop['helper'])
                self.stops.remove(stop)
                if not any(s['session'] is stop['session'] for s in self.stops):
                    stop['session'].stopping = False
                self.complete_recording(stop['title'], stop['base'], stop['parts'], stop['member'], stop['starts'])
            if not self.stops or time.monotonic() >= deadline:
                break
            time.sleep(0.2)

    def complete_recording(self, title, base, all_parts, member=None, part_starts=None):
        parts = [p for p in all_parts if p and self.test_video_file(p)]
        for part in all_parts:
            if part and part not in parts:
                try:
                    Path(part).unlink()
                except OSError:
                    pass
        segments = self.combine_segments(parts, part_starts) if member else []
        if not base or not parts:
            self.notify(f'Recording stopped for {title}; nothing was recorded.')
            if member:
                self.complete_combine_member(member, [])
            return
        output = f'{base}.mp4'
        if len(parts) == 1:
            try:
                Path(parts[0]).replace(output)
                self.notify(f'Recording saved: {output}')
                for segment in segments:
                    segment['path'] = output
            except OSError as error:
                self.notify(f'Could not save {output}: {error}', 'warning')
            if member:
                self.complete_combine_member(member, segments)
            return
        if not self.tools.ffmpeg:
            self.notify(f'Recording saved in {len(parts)} parts next to {output} (ffmpeg not found to join them).')
            if member:
                self.complete_combine_member(member, segments)
            return
        steps = []
        temps = []
        for part in parts:
            temp = re.sub(r'\.mp4$', '_fixed.mp4', part)
            steps.append(['-hide_banner', '-loglevel', 'error', '-y', '-i', part, '-map', '0:v?', '-map', '0:a?',
                          '-c', 'copy', temp])
            temps.append(temp)
        list_file = self.paths.state / f'concat-{uuid.uuid4().hex}.txt'
        lines = ["file '" + temp.replace("'", "'\\''") + "'" for temp in temps]
        list_file.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        steps.append(['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(list_file),
                      '-c', 'copy', '-movflags', '+faststart', output])
        merge = {'process': None, 'steps': steps, 'parts': parts, 'temps': temps, 'output': output,
                 'list_file': list_file, 'member': member, 'segments': segments}
        try:
            merge['process'] = self.start_merge_step(merge)
        except OSError as error:
            log(f'Failed to start ffmpeg: {error}')
        self.merges.append(merge)
        log(f'Joining {len(parts)} parts into {output}')

    def start_merge_step(self, merge):
        args = merge['steps'].pop(0)
        return subprocess.Popen([self.tools.ffmpeg] + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, **hidden_kwargs())

    def update_merges(self, timeout=0):
        deadline = time.monotonic() + timeout
        for merge in list(self.merges):
            exit_code = -1
            while merge['process']:
                try:
                    merge['process'].wait(max(0.0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    break
                exit_code = merge['process'].returncode
                merge['process'] = None
                if exit_code != 0 or not merge['steps']:
                    break
                try:
                    merge['process'] = self.start_merge_step(merge)
                except OSError as error:
                    exit_code = -1
                    log(f'Failed to start ffmpeg: {error}')
            if merge['process']:
                continue
            self.merges.remove(merge)
            for path in [merge['list_file']] + merge['temps']:
                try:
                    Path(path).unlink()
                except OSError:
                    pass
            if exit_code == 0 and not merge['steps'] and self.test_video_file(merge['output']):
                if not self.options.keep_parts:
                    for part in merge['parts']:
                        try:
                            Path(part).unlink()
                        except OSError:
                            pass
                self.notify(f'Recording saved: {merge["output"]}')
                if merge['member']:
                    position = 0.0
                    for segment in merge['segments']:
                        segment['path'] = merge['output']
                        segment['position'] = position
                        position += segment['duration']
                    self.complete_combine_member(merge['member'], merge['segments'])
            else:
                try:
                    Path(merge['output']).unlink()
                except OSError:
                    pass
                self.notify(f'Could not join recording parts (ffmpeg exit code {exit_code}); the parts were kept '
                            f'next to {merge["output"]}.', 'warning')
                if merge['member']:
                    self.complete_combine_member(merge['member'], merge['segments'])

    def video_duration(self, path):
        if not self.tools.ffprobe:
            return 0.0
        output = run_hidden([self.tools.ffprobe, '-v', 'error', '-show_entries', 'format=duration', '-of',
                             'default=nw=1:nk=1', str(path)], 30).strip()
        try:
            return float(output)
        except ValueError:
            return 0.0

    def video_size(self, path):
        output = run_hidden([self.tools.ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                             'stream=width,height', '-of', 'csv=p=0:s=x', str(path)], 30).strip()
        match = re.match(r'^(\d+)x(\d+)', output)
        if match and int(match.group(1)) > 0 and int(match.group(2)) > 0:
            return int(match.group(1)), int(match.group(2))
        return 1080, 1920

    def combine_segments(self, parts, part_starts):
        return [{'path': part, 'position': 0.0, 'duration': self.video_duration(part),
                 'start': (part_starts or {}).get(part)} for part in parts]

    def start_combined_recording(self, serials):
        group = {'requested_at': datetime.now(), 'members': [], 'finished': False}
        started = []
        candidates = [self.sessions[s] for s in serials if s in self.sessions]
        for session in sorted(candidates, key=lambda s: s.title.lower()):
            if session.recording or session.stopping:
                continue
            self.start_recording(session)
            if not session.recording:
                continue
            member = {'group': group, 'title': session.title, 'segments': [], 'open': 1, 'done': False}
            group['members'].append(member)
            session.combine_member = member
            session.part_starts = {}
            session.part_start_pending = False
            started.append(session)
        if len(group['members']) >= 2:
            self.notify(f'Combined recording started for {len(group["members"])} devices. One video with all screens '
                        f'is saved after they all stop.')
            return
        group['finished'] = True
        for session in started:
            session.combine_member = None
        if started:
            self.notify(f'Record combined needs at least two devices; recording {started[0].title} on its own.')

    def complete_combine_member(self, member, segments):
        try:
            if member['done']:
                return
            member['segments'] += [s for s in segments if s and s['path'] and s['duration'] > 0]
            member['open'] -= 1
            if member['open'] > 0:
                return
            member['done'] = True
            group = member['group']
            if group['finished'] or any(not m['done'] for m in group['members']):
                return
            group['finished'] = True
            if not self.tools.ffmpeg or not self.tools.ffprobe:
                self.notify('Combined recording skipped: ffmpeg was not found. Each device recording was saved.',
                            'warning')
                return
            recorded = [m for m in group['members'] if m['segments']]
            if len(recorded) < 2:
                self.notify('Combined recording skipped: fewer than two devices recorded video. Each device '
                            'recording was saved.')
                return
            self.start_combine(group, recorded)
        except Exception:
            log('Combined recording failed: ' + traceback.format_exc())
            self.notify('Could not create the combined recording. Each device recording was saved.', 'warning')

    def join_combine_handover(self, session):
        for handover in [h for h in self.combine_handovers if h['session'] is session]:
            self.combine_handovers.remove(handover)
            member = handover['member']
            if session.recording and not session.combine_member and not member['group']['finished']:
                session.combine_member = member
                session.part_starts = {}
                session.part_start_pending = False
            else:
                self.complete_combine_member(member, [])

    def update_combine_handovers(self, release_all=False):
        now = datetime.now()
        for handover in list(self.combine_handovers):
            if not release_all and (now - handover['at']).total_seconds() < 60:
                continue
            self.combine_handovers.remove(handover)
            log(f'[{handover["session"].serial}] Recording did not continue over USB; the combined recording keeps '
                f'the Wi-Fi part only.')
            self.complete_combine_member(handover['member'], [])

    def combine_active(self):
        return bool(self.combines or self.combine_handovers
                    or any(s.combine_member for s in list(self.sessions.values()))
                    or any(s.get('member') for s in self.stops) or any(m.get('member') for m in self.merges))

    def get_combine_encoder_args(self):
        if not self.combine_encoder:
            encoders = run_hidden([self.tools.ffmpeg, '-hide_banner', '-encoders'], 15)
            args = logic.combine_encoder_args(encoders)
            if not encoders:
                return args
            self.combine_encoder = args
        return self.combine_encoder

    def start_combine(self, group, members):
        t0 = None
        for member in members:
            for segment in member['segments']:
                if not segment['start']:
                    segment['start'] = group['requested_at']
                if t0 is None or segment['start'] < t0:
                    t0 = segment['start']
        sizes = [self.video_size(m['segments'][0]['path']) for m in members]
        folder = Path(self.record_dir) / 'Combined'
        folder.mkdir(parents=True, exist_ok=True)
        stem = f'Screen_Recording_Combined_{group["requested_at"]:%Y%m%d_%H%M%S}'
        output = folder / f'{stem}.mp4'
        suffix = 2
        while output.exists() or any(c['output'] == str(output) for c in self.combines):
            output = folder / f'{stem}_{suffix}.mp4'
            suffix += 1
        temp = str(output)[:-4] + '_combining.mp4'
        args, total, count = logic.combine_command([m['segments'] for m in members], sizes, t0,
                                                   self.get_combine_encoder_args(), temp)
        if IS_WINDOWS and len(subprocess.list2cmdline(args)) > 30000:
            self.notify('Combined recording skipped: too many recording parts. Each device recording was saved.',
                        'warning')
            return
        log_file = self.paths.logs / f'combine-{datetime.now():%Y%m%d_%H%M%S}.log'
        env = dict(os.environ)
        env['FFREPORT'] = 'file=' + str(log_file).replace('\\', '/').replace(':', '\\:') + ':level=16'
        kwargs = hidden_kwargs()
        if IS_WINDOWS:
            kwargs['creationflags'] |= subprocess.BELOW_NORMAL_PRIORITY_CLASS
        process = subprocess.Popen([self.tools.ffmpeg] + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, env=env, **kwargs)
        if not IS_WINDOWS:
            try:
                os.setpriority(os.PRIO_PROCESS, process.pid, 10)
            except OSError:
                pass
        self.combines.append({'process': process, 'output': str(output), 'temp': temp, 'log': str(log_file),
                              'size': -1, 'progress_at': time.monotonic()})
        log(f'Combining {len(members)} device recordings ({count} part(s), {logic.format_seconds(total)}s) into '
            f'{output} (log: {log_file})')
        self.notify(f'Combining {len(members)} device recordings into one video...')

    def update_combines(self, timeout=0):
        deadline = time.monotonic() + timeout
        for combine in list(self.combines):
            process = combine['process']
            try:
                process.wait(max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    size = Path(combine['temp']).stat().st_size
                except OSError:
                    size = 0
                if size != combine['size']:
                    combine['size'] = size
                    combine['progress_at'] = time.monotonic()
                    continue
                if time.monotonic() - combine['progress_at'] < 300:
                    continue
                log('Combined recording made no progress for 5 minutes; stopping ffmpeg.')
                kill_tree(process.pid)
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    pass
            exit_code = process.returncode if process.returncode is not None else -1
            self.combines.remove(combine)
            if exit_code == 0 and self.test_video_file(combine['temp']):
                try:
                    Path(combine['temp']).replace(combine['output'])
                    try:
                        Path(combine['log']).unlink()
                    except OSError:
                        pass
                    self.notify(f'Combined recording saved: {combine["output"]}')
                except OSError as error:
                    self.notify(f'Combined recording saved as {combine["temp"]} (could not rename it: {error}).',
                                'warning')
            else:
                try:
                    Path(combine['temp']).unlink()
                except OSError:
                    pass
                self.notify(f'Could not create the combined recording (ffmpeg exit code {exit_code}; log: '
                            f'{combine["log"]}). Each device recording was saved.', 'warning')

    def stop_combines(self):
        for combine in list(self.combines):
            process = combine['process']
            try:
                if process.poll() is None:
                    kill_tree(process.pid)
                    process.wait(5)
            except Exception:
                pass
            self.combines.remove(combine)
            try:
                Path(combine['temp']).unlink()
            except OSError:
                pass
            log(f'Combined recording {combine["output"]} cancelled at exit; each device recording was saved.')
            self.notify('The combined recording was not finished before exit and was cancelled. Each device '
                        'recording was saved.', 'warning')

    def target_sessions(self, serials=()):
        active = [s for s in self.sessions.values() if not s.user_closed and s.serial not in self.standby]
        if not serials:
            return active
        return [s for s in active if s.serial in serials]

    def start_connect(self, address, manual):
        if any(job.address == address for job in self.connects):
            return
        try:
            job = BackgroundCommand([self.tools.adb, 'connect', address])
        except OSError as error:
            log(f'adb connect {address} failed: {error}')
            return
        job.address = address
        job.manual = manual
        self.connects.append(job)

    def update_connects(self, devices):
        for job in list(self.connects):
            output = job.complete()
            if output is None:
                continue
            self.connects.remove(job)
            log(f'adb connect {job.address}: {output}')
            connected = logic.is_connected_output(output)
            if connected and not job.manual and not output.startswith('already'):
                usb = [s for s, state in devices.items() if state == 'device' and connection_type(s) == 'USB'
                       and s not in self.moved_usb
                       and not (s in self.sessions and self.sessions[s].user_closed)]
                if usb and self.get_prop(job.address, 'ro.serialno') in usb:
                    log(f'{job.address} is a device already connected over USB; disconnecting the Wi-Fi connection.')
                    self.adb(['disconnect', job.address], 5)
                    devices.pop(job.address, None)
                    self.remove_known_wifi(job.address)
                    self.discovery_retry[job.address] = datetime.now() + timedelta(minutes=10)
                    continue
            if not job.manual:
                continue
            moving = next((s for s in self.sessions.values() if s.moved_to == 'Wi-Fi'
                           and s.move_address == job.address), None)
            if moving:
                if not connected:
                    self.undo_move(moving, f'adb connect failed ({output})')
                continue
            if connected:
                self.add_scan_port(int(logic.split_address(job.address)[1]))
                self.notify(f'Connected to {job.address}.')
            else:
                self.ui_events.put(('connect_failure', job.address, output))

    def stop_adb_jobs(self):
        for job in self.connects + ([self.discovery] if self.discovery else []):
            job.kill()
        self.connects = []
        self.discovery = None
        self.stop_probe()

    def discovery_disabled(self):
        return self.options.no_discovery or bool(self.serial_filter)

    def update_discovery(self, devices):
        if self.discovery_disabled():
            return
        now = datetime.now()
        if self.discovery:
            output = self.discovery.complete()
            if output is not None:
                self.discovery = None
                for name, address in logic.parse_mdns_services(output):
                    self.scan_found.add(address)
                    if any(name == f'adb-{serial}' for serial in devices):
                        continue
                    self.connect_found(address, name, devices, now)
        if self.probe:
            found = self.probe.complete()
            if found is not None:
                self.probe = None
                for address in found:
                    self.scan_found.add(address)
                    self.connect_found(address, 'port scan', devices, now)
        if self.discovery or self.probe:
            return
        if self.scanning:
            self.scanning = False
            kinds = [connection_type(s) for s, state in devices.items() if state == 'device']
            self.discovery_status = (f'Last scan {now:%H:%M:%S}: {kinds.count("Wi-Fi")} Wi-Fi, '
                                     f'{kinds.count("USB")} USB')
        if now < self.next_discovery:
            return
        self.next_discovery = now + timedelta(seconds=15)
        self.scan_found.clear()
        for address in list(self.known_wifi):
            self.connect_found(address, 'remembered', devices, now)
        try:
            self.discovery = BackgroundCommand([self.tools.adb, 'mdns', 'services'])
        except OSError as error:
            log(f'adb mdns services failed: {error}')
        if self.probe_requested:
            self.probe_requested = False
            try:
                self.start_probe()
            except Exception as error:
                log(f'Wi-Fi port scan failed: {error}')
        if self.discovery or self.probe:
            self.scanning = True
            if self.probe:
                self.discovery_status = 'Scanning for devices...'
        else:
            self.discovery_status = 'Wi-Fi scan: unavailable'

    def connect_found(self, address, source, devices, now):
        if address in devices or address in self.sessions:
            return
        if address in self.discovery_retry and now < self.discovery_retry[address]:
            return
        self.discovery_retry[address] = now + timedelta(seconds=60)
        log(f'Found Wi-Fi device {address} ({source}); connecting.')
        self.start_connect(address, False)

    def scan_ports(self):
        return logic.scan_ports(self.saved_scan_ports, self.known_wifi)

    def start_probe(self):
        ports = self.scan_ports()
        hosts = []
        own = set()
        for ip, prefix in local_networks():
            own.add(ip)
            hosts += logic.probe_hosts(ip, prefix)
        targets = []
        for host in dict.fromkeys(hosts):
            if host in own:
                continue
            targets += [f'{host}:{port}' for port in ports]
        targets += [a for a in self.known_wifi if logic.is_ipv4_address(a)]
        targets = list(dict.fromkeys(targets))
        log(f'Scanning {len(targets)} address(es) on port(s) {", ".join(map(str, ports))}.')
        self.probe = Probe(targets)

    def stop_probe(self):
        if self.probe:
            self.probe.stop()
            self.probe = None

    def _read_scan_ports(self):
        ports = []
        for value in read_json(self.paths.scan_ports, []) or []:
            try:
                port = int(str(value))
            except ValueError:
                continue
            if 1 <= port <= 65535 and port not in ports:
                ports.append(port)
        return ports

    def add_scan_port(self, port):
        if port in logic.DEFAULT_SCAN_PORTS or port in self.saved_scan_ports:
            return
        self.saved_scan_ports.append(port)
        log(f'Adding port {port} to the Wi-Fi scan.')
        try:
            write_json(self.paths.scan_ports, self.saved_scan_ports)
        except OSError as error:
            log(f'Could not save {self.paths.scan_ports}: {error}')

    def _read_known_wifi(self):
        result = []
        for value in read_json(self.paths.known_wifi, []) or []:
            if re.match(r'^\S+:\d+$', str(value)) and str(value) not in result:
                result.append(str(value))
        return result

    def update_known_wifi(self, devices):
        for address, state in devices.items():
            if state == 'device' and logic.is_ipv4_address(address) and address not in self.known_wifi:
                self.add_known_wifi(address)

    def add_known_wifi(self, address):
        if not address or address in self.known_wifi:
            return
        self.known_wifi.append(address)
        log(f'Remembering Wi-Fi device {address}.')
        self.save_known_wifi()

    def remove_known_wifi(self, address):
        if address not in self.known_wifi:
            return
        self.known_wifi.remove(address)
        log(f'Forgetting Wi-Fi device {address}.')
        self.save_known_wifi()

    def save_known_wifi(self):
        try:
            write_json(self.paths.known_wifi, self.known_wifi)
        except OSError as error:
            log(f'Could not save {self.paths.known_wifi}: {error}')

    def start_scan(self):
        if self.discovery_disabled() or self.discovery or self.probe:
            return
        self.discovery_retry.clear()
        self.next_discovery = datetime.now()
        self.probe_requested = True
        self.discovery_status = 'Scanning for devices...'
        log('Device scan requested.')
        self.request_tick()

    def tick(self):
        if self.exiting:
            return
        self.update_merges()
        self.update_combines()
        self.update_combine_handovers()
        now = datetime.now()
        devices = self.get_devices()
        self.removed_serials.clear()
        self.update_connects(devices)
        self.update_known_wifi(devices)
        self.update_discovery(devices)
        self.update_moves(devices)
        self.update_usb_priority(devices)
        for address, due in list(self.delayed_connects.items()):
            if now < due:
                continue
            del self.delayed_connects[address]
            self.connect_wifi_device(address)
        if self.serial_filter:
            targets = list(self.serial_filter)
        else:
            targets = list(dict.fromkeys(
                [s for s, state in devices.items() if state in ('device', 'unauthorized', 'authorizing')]
                + list(self.sessions)))
        targets = [t for t in targets if not self.test_moved_away(t, devices)]
        for serial in targets:
            if serial in self.removed_serials:
                continue
            session = self.sessions.get(serial) or self.new_session(serial)
            if session.pending_action and not session.stopping:
                self.invoke_pending_action(session)
            if session.user_closed:
                continue
            state = devices.get(serial, 'missing')
            if state != session.last_state:
                log(f'[{serial}] adb state: {state}')
                if state == 'device':
                    self.wifi_serials.pop(serial, None)
                session.last_state = state
            if state == 'device':
                session.missing_since = None
            elif not session.missing_since:
                session.missing_since = now
            if state != 'device':
                session.booted_at = None
            if session.connector and session.connector.poll() is not None:
                session.connector = None
                session.next_connect = now + timedelta(seconds=5)
            if (state != 'device' and not session.connector and re.match(r'^[^\s:]+:\d+$', serial)
                    and now >= session.next_connect):
                if state == 'offline':
                    self.adb(['disconnect', serial], 5)
                try:
                    session.connector = subprocess.Popen(
                        [self.tools.adb, 'connect', serial], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, **hidden_kwargs())
                except OSError as error:
                    log(f'adb connect {serial} failed: {error}')
            if serial in self.standby:
                if not session.name and state == 'device':
                    self.test_device_ready(session, devices)
                if session.display:
                    log(f'[{serial}] Standby: the device is mirrored over '
                        f'{connection_type(self.standby[serial])}.')
                self.stop_display(session)
                continue
            if session.record_pending and state == 'device':
                session.record_pending = False
                self.start_recording(session)
                self.join_combine_handover(session)
            ready = [None]
            self.update_display(session, devices, ready)
            if not session.user_closed:
                self.update_recorder(session, devices, ready)
        tracked = list(self.sessions.values())
        monitored = [s for s in tracked if not s.disconnected and s.name and s.serial not in self.standby]
        if self.open_windows_requested:
            self.open_windows_requested = False
            closed = [s.serial for s in tracked if s.user_closed and not s.disconnected]
            if closed:
                self.open_window(closed)
            if self.has_panel:
                self.ui_events.put(('show_panel',))
            elif not closed:
                self.notify('scrcpy monitor is already running. Use the tray icon for recording and settings.')
        if (not self.panel_visible and monitored and all(s.user_closed for s in monitored)
                and not any(s.moved_to for s in tracked) and not self.combine_active()):
            log('All scrcpy windows were closed.')
            self.stop_monitor()

    def open_window(self, serials):
        for serial in serials:
            session = self.sessions.get(serial)
            if not session or not session.user_closed:
                continue
            session.user_closed = False
            session.display_failures = 0
            session.next_display_attempt = datetime.now()
            if session.disconnected:
                session.disconnected = False
                session.pending_action = None
                session.moved_to = None
                session.next_connect = datetime.now()
                log(f'[{serial}] Reconnecting.')
            else:
                log(f'[{serial}] Reopening scrcpy window.')
        self.request_tick()

    def stop_display(self, session):
        if not session.display:
            return
        display = session.display
        if not display.exited:
            kill_tree(display.pid)
            display.wait(5)
        session.display = None
        session.window_shown = False

    def close_session(self, session, action):
        session.disconnected = True
        session.user_closed = True
        session.pending_action = action
        self.stop_recording(session)
        if session.connector:
            if session.connector.poll() is None:
                kill_process(session.connector)
            session.connector = None
        self.stop_display(session)

    def update_usb_priority(self, devices):
        self.standby = {}
        if self.serial_filter:
            return
        known = list(dict.fromkeys(list(devices) + list(self.sessions)))
        if not any(connection_type(s) == 'USB' for s in known):
            return
        for address in [s for s in known if connection_type(s) == 'Wi-Fi']:
            if address not in self.wifi_serials and devices.get(address) == 'device':
                self.wifi_serials[address] = self.get_prop(address, 'ro.serialno')
        standby, handovers = logic.usb_priority(devices, self.sessions, self.wifi_serials, self.moved_usb,
                                                datetime.now())
        for address, usb_serial in handovers:
            log(f'[{address}] Missing for 30 seconds; continuing the recording over USB ({usb_serial}).')
            wifi = self.sessions[address]
            if usb_serial in self.sessions and wifi.combine_member:
                wifi.combine_member['open'] += 1
                self.combine_handovers.append({'session': self.sessions[usb_serial], 'member': wifi.combine_member,
                                               'at': datetime.now()})
            self.stop_recording(wifi)
            if usb_serial in self.sessions:
                self.sessions[usb_serial].record_pending = True
        self.standby = standby

    def invoke_pending_action(self, session):
        action = session.pending_action
        session.pending_action = None
        serial = session.serial
        if action == 'disconnect':
            log(f'[{serial}] adb disconnect: {self.adb(["disconnect", serial], 5).strip()}')
        elif action == 'usb':
            output = self.adb(['-s', serial, 'usb'], 5).strip()
            log(f'[{serial}] adb usb: {output}')
            if 'restarting in USB mode' not in output:
                self.undo_move(session, f'adb usb failed ({output})')
                return
            self.adb(['disconnect', serial], 5)
            self.remove_known_wifi(serial)
            usb_session = self.sessions.get(session.move_address)
            if usb_session and usb_session.user_closed:
                self.open_window([usb_session.serial])
            session.move_deadline = datetime.now() + timedelta(seconds=30)
        elif action == 'tcpip':
            output = self.adb(['-s', serial, 'tcpip', '5555'], 5).strip()
            log(f'[{serial}] adb tcpip 5555: {output}')
            if 'restarting in TCP mode' not in output:
                self.undo_move(session, f'adb tcpip failed ({output})')
                return
            self.delayed_connects[session.move_address] = datetime.now() + timedelta(seconds=3)
            session.move_deadline = datetime.now() + timedelta(seconds=30)

    def remove_session(self, session):
        self.close_session(session, None)
        self.sessions.pop(session.serial, None)
        self.removed_serials.add(session.serial)

    def update_moves(self, devices):
        for session in [s for s in list(self.sessions.values()) if s.moved_to and not s.pending_action]:
            target = session.move_address
            if devices.get(target) == 'device':
                log(f'[{session.serial}] Switched to {session.moved_to} ({target}).')
                if session.moved_to == 'Wi-Fi':
                    self.moved_usb[session.serial] = target
                    self.add_known_wifi(target)
                self.remove_session(session)
                self.notify(f'{session.title} switched to {session.moved_to} ({target}).')
            elif datetime.now() >= session.move_deadline:
                self.undo_move(session, f'the device did not appear over {session.moved_to} within 30 seconds')

    def undo_move(self, session, reason):
        to = session.moved_to
        target = session.move_address
        log(f'[{session.serial}] Switch to {to} failed: {reason}')
        if to == 'Wi-Fi' and target:
            self.delayed_connects.pop(target, None)
            wifi = self.sessions.get(target)
            if wifi:
                self.remove_session(wifi)
            self.adb(['disconnect', target], 5)
        self.open_window([session.serial])
        self.notify(f'Could not switch {session.title} to {to}: {reason}. Restored the {session.connection} '
                    f'connection.', 'warning')

    def test_moved_away(self, serial, devices):
        away, forget = logic.moved_away(serial, devices, self.moved_usb, self.sessions, datetime.now())
        if forget:
            self.moved_usb.pop(serial, None)
        return away

    def get_wifi_address(self, serial):
        return logic.parse_wifi_address(self.adb(['-s', serial, 'shell', 'ip', '-f', 'inet', 'addr', 'show'], 5))

    def confirm_stop_recording(self, sessions, action_text, action):
        if not any(s.recording for s in sessions):
            action()
            return
        titles = ', '.join(s.title for s in sessions)
        self.confirm(f'{action_text} {titles}?\n\nThe recording in progress is stopped and saved.', action)

    def switch_connection(self, serials):
        sessions = [self.sessions[s] for s in serials if s in self.sessions]
        sessions = [s for s in sessions if not s.disconnected and s.last_state == 'device'
                    and s.connection in ('Wi-Fi', 'USB')]
        kinds = list(dict.fromkeys(s.connection for s in sessions))
        if len(kinds) != 1:
            return
        target = 'USB' if kinds[0] == 'Wi-Fi' else 'Wi-Fi'
        usb_serials = {}
        addresses = {}
        devices = self.get_devices()
        for session in list(sessions):
            if target == 'USB':
                usb_serial = self.get_prop(session.serial, 'ro.serialno')
                if usb_serial and devices.get(usb_serial) == 'device':
                    usb_serials[session.serial] = usb_serial
                    continue
                self.message(f'{session.title} is not connected over USB. Plug in its USB cable (and allow USB '
                             f'debugging) first, then try again.')
                sessions.remove(session)
                continue
            ip = self.get_wifi_address(session.serial)
            if ip:
                addresses[session.serial] = f'{ip}:5555'
                continue
            self.message(f'{session.title} is not connected to a Wi-Fi network. Connect it to the same network as '
                         f'this computer and try again.')
            sessions.remove(session)
        if not sessions:
            return
        self.confirm_stop_recording(sessions, f'Switch to {target}',
                                    lambda: self.execute_switch(sessions, target, usb_serials, addresses, devices))

    def execute_switch(self, sessions, target, usb_serials, addresses, devices):
        for session in sessions:
            if session.serial not in self.sessions or session.disconnected:
                continue
            session.moved_to = target
            if target == 'USB':
                usb_serial = usb_serials[session.serial]
                session.move_address = usb_serial
                self.moved_usb.pop(usb_serial, None)
                if self.serial_filter and usb_serial not in self.serial_filter:
                    self.serial_filter.append(usb_serial)
                log(f'[{session.serial}] Switching to USB ({usb_serial}).')
                self.close_session(session, 'usb')
            else:
                usb_serial = session.serial
                standby = next((a for a, u in self.standby.items() if u == usb_serial
                                and connection_type(a) == 'Wi-Fi' and devices.get(a) == 'device'), None)
                if standby:
                    session.move_address = standby
                    log(f'[{usb_serial}] Switching to Wi-Fi ({standby}, already connected).')
                    self.close_session(session, None)
                    session.move_deadline = datetime.now() + timedelta(seconds=30)
                    continue
                session.move_address = addresses[session.serial]
                log(f'[{session.serial}] Switching to Wi-Fi ({session.move_address}).')
                self.close_session(session, 'tcpip')
        self.request_tick()

    def disconnect_device(self, serials):
        sessions = [self.sessions[s] for s in serials if s in self.sessions]
        sessions = [s for s in sessions if s.connection == 'Wi-Fi' and not s.disconnected]
        if not sessions:
            return

        def run():
            for session in sessions:
                log(f'[{session.serial}] Disconnecting.')
                self.close_session(session, 'disconnect')
            self.request_tick()

        self.confirm_stop_recording(sessions, 'Disconnect', run)

    def connect_wifi_device(self, address):
        if not re.search(r':\d+$', address):
            address += ':5555'
        if self.serial_filter and address not in self.serial_filter:
            self.serial_filter.append(address)
        session = self.sessions.get(address)
        if session and session.user_closed:
            self.open_window([address])
            return
        log(f'Connecting to {address}.')
        self.start_connect(address, True)
        self.request_tick()

    def toggle_recording(self, serials):
        selected = [self.sessions[s] for s in serials if s in self.sessions and not self.sessions[s].user_closed]
        to_start = [s for s in selected if not s.recording]
        if to_start:
            for session in to_start:
                self.start_recording(session)
        else:
            for session in selected:
                self.stop_recording(session)

    def start_all(self, serials=()):
        for session in self.target_sessions(serials):
            self.start_recording(session)

    def stop_all(self, serials=()):
        for session in self.target_sessions(serials):
            self.stop_recording(session)

    def set_record_dir(self, folder):
        self.record_dir = folder
        log(f'Recordings folder changed to {folder}')

    def stop_monitor(self):
        if self.exiting:
            return
        self.exiting = True
        log('Stopping monitor.')
        self.publish()
        steps = [self.stop_adb_jobs]
        steps += [lambda s=s: self.stop_recording(s) for s in list(self.sessions.values())]
        steps.append(lambda: self.update_stops(45))
        steps.append(lambda: self.update_combine_handovers(True))
        steps += [lambda s=s: self.invoke_pending_action(s) for s in list(self.sessions.values()) if s.pending_action]
        steps += [lambda s=s: self._close_processes(s) for s in list(self.sessions.values())]
        steps.append(lambda: self.update_merges(600))
        steps.append(lambda: self.update_combines(120))
        steps.append(self.stop_combines)
        for step in steps:
            try:
                step()
            except Exception:
                log('ERROR: ' + traceback.format_exc())
        self.finished.set()

    def _close_processes(self, session):
        if session.connector:
            if session.connector.poll() is None:
                kill_process(session.connector)
            session.connector = None
        if session.display:
            stop_gracefully(session.display.process, 10)
            session.display = None

    def session_status(self, session):
        if session.moved_to:
            return f'Switching to {session.moved_to}...'
        if session.disconnected:
            return 'Disconnected'
        if session.user_closed:
            return 'Window closed'
        if session.serial in self.standby:
            return f'Standby (using {connection_type(self.standby[session.serial])})'
        if session.last_state == 'unauthorized':
            return 'Allow USB debugging on device'
        if session.last_state != 'device':
            return f'Waiting for device ({session.last_state or "missing"})'
        if session.display:
            return 'Mirroring' if session.window_shown else 'Waiting for video'
        return 'Opening window'

    def recording_text(self, session):
        if not session.recording:
            return 'Saving...' if session.stopping else ''
        text = 'REC ' + logic.format_elapsed(_seconds(datetime.now() - session.recording_started_at))
        if session.stopping:
            text += ' (saving previous)'
        elif not session.recorder:
            text += ' (waiting for device)'
        elif len(session.parts) > 1:
            text += f' (part {len(session.parts)})'
        if session.combine_member:
            text = 'REC combined ' + text[4:]
        return text

    def publish(self):
        views = []
        for session in list(self.sessions.values()):
            views.append(SessionView(
                serial=session.serial, title=session.title, connection=session.connection,
                status=self.session_status(session), recording_text=self.recording_text(session),
                recording=session.recording, user_closed=session.user_closed, disconnected=session.disconnected,
                standby=session.serial in self.standby, last_state=session.last_state, moved_to=session.moved_to,
                stopping=session.stopping))
        self.snapshot = Snapshot(
            views, discovery_status=self.discovery_status, record_dir=str(self.record_dir), merges=len(self.merges),
            combines=len(self.combines), combine_active=self.combine_active(),
            connecting=[job.address for job in self.connects if job.manual], exiting=self.exiting,
            scan_enabled=not (self.discovery_disabled() or self.discovery or self.probe),
            scan_ports=self.scan_ports(), discovery_off=self.discovery_disabled())
