import argparse
import getpass
import json
import os
import re
import signal
import sys
import time
from pathlib import Path

from . import logic
from .system import (FROZEN, IS_LINUX, IS_MAC, IS_WINDOWS, Paths, bin_dirs, find_icon_dir, find_library_dir,
                     find_resource, find_server, find_tool, log, read_json, run_hidden, set_log_path)

COMMANDS = {'exit': 'exit', 'showpanel': 'show-panel', 'startrecording': 'start-recording',
            'stoprecording': 'stop-recording'}


def server_name():
    try:
        user = getpass.getuser()
    except Exception:
        user = 'user'
    return 'scrcpy-monitor-py-' + re.sub(r'[^A-Za-z0-9_.-]', '_', user)


def parse_args(argv):
    passthrough = []
    if '--' in argv:
        index = argv.index('--')
        argv, passthrough = argv[:index], argv[index + 1:]
    parser = argparse.ArgumentParser(
        prog='scrcpy-monitor',
        description='Mirror every connected Android device in its own scrcpy window and record it on demand. '
                    'Unknown options are passed to scrcpy.')
    parser.add_argument('--serial', action='append', default=[],
                        help='monitor only these devices (repeat or separate with commas)')
    parser.add_argument('--scrcpy', help='path to the scrcpy executable')
    parser.add_argument('--adb', help='path to the adb executable')
    parser.add_argument('--record', action='store_true', help='start recording every device right away')
    parser.add_argument('--record-dir', help='folder for recordings')
    parser.add_argument('--record-encoder', default='auto', help='video encoder for recordings (default: auto)')
    parser.add_argument('--record-arg', action='append', default=[], help='extra scrcpy argument for recordings')
    parser.add_argument('--keep-parts', action='store_true', help='keep the recording parts after joining them')
    parser.add_argument('--command', help='send a command to the running monitor: '
                                          'start-recording, stop-recording, show-panel or exit')
    parser.add_argument('--list', action='store_true', help='list the connected devices and exit')
    parser.add_argument('--no-tray', action='store_true', help='do not show the tray icon')
    parser.add_argument('--no-panel', action='store_true', help='do not create the control panel')
    parser.add_argument('--no-update-check', action='store_true', help='do not check for updates at startup')
    parser.add_argument('--no-discovery', action='store_true', help='do not scan the network for Wi-Fi devices')
    parser.add_argument('--poll-seconds', type=float, default=2, help='device poll interval (default: 2)')
    parser.add_argument('--port-base', type=int, default=logic.PORT_BASE,
                        help=f'first local port for scrcpy sessions (default: {logic.PORT_BASE})')
    args, extra = parser.parse_known_args(argv)
    args.scrcpy_args = extra + passthrough
    args.serials = [s.strip() for value in args.serial for s in value.split(',') if s.strip()]
    if args.command:
        command = COMMANDS.get(re.sub(r'[-_\s]', '', args.command.lower()))
        if not command:
            parser.error(f'unknown command: {args.command}')
        args.command = command
    if args.poll_seconds <= 0:
        parser.error('--poll-seconds must be positive')
    if not 1024 <= args.port_base <= 65535 - logic.PORT_RANGE:
        parser.error('--port-base is out of range')
    return args


def send_request(command, serials=(), reply_timeout=5000):
    from PySide6.QtNetwork import QLocalSocket
    socket = QLocalSocket()
    socket.connectToServer(server_name())
    if not socket.waitForConnected(1000):
        return None
    socket.write(json.dumps({'command': command, 'serials': list(serials)}).encode('utf-8') + b'\n')
    socket.flush()
    socket.waitForBytesWritten(1000)
    reply = b''
    deadline = time.monotonic() + reply_timeout / 1000
    while b'\n' not in reply and time.monotonic() < deadline:
        if not socket.waitForReadyRead(200) and socket.state() != QLocalSocket.LocalSocketState.ConnectedState:
            break
        reply += bytes(socket.readAll())
    socket.disconnectFromServer()
    return reply.decode('utf-8', 'replace').strip() or 'ok'


def run_command(args):
    from PySide6.QtCore import QCoreApplication
    QCoreApplication(sys.argv[:1])
    if send_request(args.command, args.serials) is None:
        print('scrcpy monitor is not running.')
        return 1
    print(f'Sent {args.command} to the running scrcpy monitor.')
    return 0


def restore_library_path():
    if not (FROZEN and IS_LINUX):
        return
    original = os.environ.pop('LD_LIBRARY_PATH_ORIG', None)
    if original is not None:
        os.environ['LD_LIBRARY_PATH'] = original
    else:
        os.environ.pop('LD_LIBRARY_PATH', None)


def build_env(scrcpy, adb, server, icon_dir):
    env = os.environ.copy()
    env['ADB'] = adb
    if server:
        env['SCRCPY_SERVER_PATH'] = server
    if icon_dir:
        env['SCRCPY_ICON_DIR'] = icon_dir
    library = find_library_dir(scrcpy)
    if library:
        name = 'PATH' if IS_WINDOWS else 'DYLD_FALLBACK_LIBRARY_PATH' if IS_MAC else 'LD_LIBRARY_PATH'
        env[name] = library + (os.pathsep + env[name] if env.get(name) else '')
    return env


def resolve_icon_dir(scrcpy):
    found = find_icon_dir(scrcpy)
    if found:
        return found
    for folder in [p.parent / 'icons' for p in bin_dirs()]:
        if (folder / 'scrcpy.png').is_file():
            return str(folder)
    return None


def list_devices(adb):
    run_hidden([adb, 'start-server'], 15)
    devices = logic.parse_adb_devices(run_hidden([adb, 'devices'], 10))
    if not devices:
        print('No devices found.')
    for serial in sorted(devices):
        state = devices[serial]
        model = run_hidden([adb, '-s', serial, 'shell', 'getprop', 'ro.product.model'], 5).strip() \
            if state == 'device' else ''
        print(f'{serial:<30} {logic.connection_type(serial):<9} {state:<14} {model}')
    return 0


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.command:
        return run_command(args)
    restore_library_path()
    paths = Paths()
    paths.create()
    set_log_path(paths.log_file)

    app = None
    if not args.list:
        from PySide6.QtWidgets import QApplication
        app = QApplication(sys.argv[:1])
        app.setApplicationName('Scrcpy Monitor')
        app.setQuitOnLastWindowClosed(False)

    def fail(text):
        log(f'ERROR: {text}')
        if app is None:
            print(text, file=sys.stderr)
        else:
            from PySide6.QtWidgets import QMessageBox
            QMessageBox.critical(None, 'Scrcpy Monitor', text)
        return 1

    scrcpy = find_tool('scrcpy', 'SCRCPY', args.scrcpy)
    if not scrcpy:
        return fail('scrcpy not found. Put it in the bin folder next to the app, set SCRCPY, add it to PATH or '
                    'pass --scrcpy.')
    adb = find_tool('adb', 'ADB', args.adb)
    if not adb:
        return fail('adb not found. Put it in the bin folder next to the app, set ADB, add platform-tools to PATH '
                    'or pass --adb.')
    server = find_server(scrcpy)
    portable = IS_WINDOWS or any(Path(scrcpy).resolve().parent == p.resolve() for p in bin_dirs() if p.is_dir())
    if not server and portable:
        return fail(f"scrcpy-server is missing from '{Path(scrcpy).parent}'. Extract the whole package again.")
    if any(re.match(r'^(--record(=|$)|-r)', a) for a in args.scrcpy_args):
        return fail('Use --record (or the record button) to record instead of passing --record to scrcpy.')
    if args.list:
        return list_devices(adb)

    from .engine import Engine, Options, Tools
    from .ui import Controller
    from .updater import VersionInfo
    from PySide6.QtNetwork import QLocalServer

    if send_request('ping', reply_timeout=2000) is not None:
        if args.no_panel:
            return fail('scrcpy monitor is already running. Use --command start-recording, stop-recording, '
                        'show-panel or exit to control it.')
        reply = send_request('open-windows')
        if reply != 'exiting':
            return 0
        deadline = time.monotonic() + 15 * 60
        while send_request('ping', reply_timeout=2000) is not None:
            if time.monotonic() > deadline:
                return 0
            time.sleep(1)

    icon_dir = resolve_icon_dir(scrcpy)
    tools = Tools(scrcpy, adb, find_tool('ffmpeg', 'FFMPEG'), find_tool('ffprobe', 'FFPROBE'),
                  build_env(scrcpy, adb, server, icon_dir))
    if not tools.ffmpeg:
        log('WARNING: ffmpeg not found; recording parts are kept as separate files.')
    record_dir = args.record_dir
    if not record_dir:
        settings = read_json(paths.settings, {})
        record_dir = settings.get('RecordDir') if isinstance(settings, dict) else None
    record_dir = str(Path(record_dir or paths.default_record_dir).expanduser())

    for item in paths.control.glob('*'):
        try:
            item.unlink()
        except OSError:
            pass

    options = Options(serials=args.serials, record=args.record, record_dir=record_dir,
                      record_encoder=args.record_encoder, record_args=args.record_arg, keep_parts=args.keep_parts,
                      no_discovery=args.no_discovery, scrcpy_args=args.scrcpy_args, port_base=args.port_base,
                      poll_seconds=args.poll_seconds)
    engine = Engine(options, paths, tools)
    version = VersionInfo()
    args.icon_path = find_resource('icon.png') or (Path(icon_dir) / 'scrcpy.png' if icon_dir else None)
    controller = Controller(app, engine, paths, version, args)

    server_socket = QLocalServer()
    server_socket.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
    QLocalServer.removeServer(server_name())
    if not server_socket.listen(server_name()):
        log(f'WARNING: single-instance server failed: {server_socket.errorString()}')

    def on_connection():
        while server_socket.hasPendingConnections():
            connection = server_socket.nextPendingConnection()
            connection.setProperty('buffer', b'')

            def on_ready(conn=connection):
                data = bytes(conn.property('buffer') or b'') + bytes(conn.readAll())
                conn.setProperty('buffer', data)
                if b'\n' not in data:
                    return
                try:
                    request = json.loads(data.split(b'\n', 1)[0].decode('utf-8'))
                except ValueError:
                    log('Ignoring an invalid request.')
                    conn.disconnectFromServer()
                    return
                exiting = engine.exiting or controller.exit_requested
                conn.write(b'exiting\n' if exiting else b'ok\n')
                conn.flush()
                command = str(request.get('command') or '')
                serials = [str(s) for s in request.get('serials') or [] if s]
                if command != 'ping' and not exiting:
                    log(f'Request: {command} {" ".join(serials)}'.strip())
                    controller.handle_request(command, serials)

            connection.readyRead.connect(on_ready)
            connection.disconnected.connect(connection.deleteLater)

    server_socket.newConnection.connect(on_connection)

    if not IS_WINDOWS:
        signal.signal(signal.SIGTERM, lambda *_: controller.request_exit())
    signal.signal(signal.SIGINT, lambda *_: controller.request_exit())

    devices = ', '.join(args.serials) if args.serials else 'all connected'
    log(f'Monitor started (scrcpy: {scrcpy}, adb: {adb}, devices: {devices}, recordings: {record_dir}, '
        f'version: {version.version})')
    engine.start()
    controller.start()
    try:
        app.exec()
    finally:
        server_socket.close()
        log('Monitor stopped.')
    # PySide6 can crash while Python tears down Qt objects at exit, so skip interpreter finalization.
    os._exit(0)
