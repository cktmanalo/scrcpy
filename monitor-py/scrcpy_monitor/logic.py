import ipaddress
import math
import re
from datetime import datetime, timezone

DEFAULT_SCAN_PORTS = (5555, 5037)
PORT_BASE = 27200
PORT_RANGE = 2000
PORT_STEP = 4

_DEVICE_LINE = re.compile(
    r'^(\S+)\s+(device|offline|unauthorized|recovery|sideload|bootloader|authorizing|connecting|no permissions.*)$')
_MDNS_LINE = re.compile(r'^\s*(\S+)\s+_adb\._tcp\.?\s+(\S+:\d+)\s*$')
_VERSION_TAG = re.compile(r'^(?:qa-)?v?(\d+(?:\.\d+)+)(?:-(\d+)-g[0-9a-f]+)?(?:-dirty)?$')
_INVALID_NAME_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def parse_adb_devices(output):
    devices = {}
    for line in (output or '').splitlines():
        match = _DEVICE_LINE.match(line.rstrip('\r'))
        if match:
            devices[match.group(1)] = match.group(2)
    return devices


def parse_mdns_services(output):
    found = []
    for line in (output or '').splitlines():
        match = _MDNS_LINE.match(line)
        if match:
            found.append((match.group(1), match.group(2)))
    return found


def connection_type(serial):
    if re.match(r'^emulator-\d+$', serial):
        return 'Emulator'
    if re.search(r':\d+$', serial) or re.search(r'\._adb(-tls-connect)?\._tcp', serial):
        return 'Wi-Fi'
    return 'USB'


def is_ipv4_address(address):
    return bool(re.match(r'^\d+\.\d+\.\d+\.\d+:\d+$', address or ''))


def split_address(address):
    return re.sub(r':\d+$', '', address), re.sub(r'^.*:', '', address)


def safe_name(name):
    text = _INVALID_NAME_CHARS.sub('_', name or '')
    text = re.sub(r'\s+', '_', text)
    return text.strip('_. ')


def connect_failure_reason(address, output):
    ip, port = split_address(address)
    output = output or ''
    if re.search(r'10061|refused', output, re.I):
        return (f'The device at {ip} answered, but port {port} is not open for ADB. Check the port number and that '
                f'ADB over Wi-Fi is turned on for this port on the device (for example adb tcpip {port}).')
    if re.search(r'11001|resolve|no such host|not known', output, re.I):
        return f'The address {ip} could not be found. Check the IP address.'
    if re.search(r'authenticat|unauthorized', output, re.I):
        return 'Unlock the device and accept the "Allow debugging" prompt, then try again.'
    if not output or re.search(r'10060|10065|10051|timed out|did not properly respond|unreachable|failed to connect',
                               output, re.I):
        return (f'No device answered at {address}. Check that the IP address and port are correct, the device is '
                f'turned on and on the same network as this computer, and ADB over Wi-Fi is turned on.')
    return output


def display_version(tag):
    tag = tag or ''
    match = _VERSION_TAG.match(tag)
    if match:
        return f'{match.group(1)}.{match.group(2) or "0"}'
    return re.sub(r'^qa-', '', tag)


def free_port_block(used, base=PORT_BASE, span=PORT_RANGE, step=PORT_STEP):
    used = set(used)
    for port in range(base, base + span, step):
        if port not in used:
            return port
    return base


def has_port_arg(arguments):
    return any(re.match(r'^(--port|-p)', arg) for arg in arguments)


def is_connected_output(output):
    return bool(re.match(r'^(already )?connected to ', output or ''))


def scan_ports(saved, known_wifi):
    ports = []
    for port in list(DEFAULT_SCAN_PORTS) + list(saved) + [int(split_address(a)[1]) for a in known_wifi]:
        if port not in ports:
            ports.append(port)
    return ports


def probe_hosts(ip, prefix):
    if prefix < 22 or prefix > 30:
        prefix = 24
    network = ipaddress.ip_network(f'{ip}/{prefix}', strict=False)
    return [str(host) for host in network.hosts()]


def parse_wifi_address(output):
    interface = ''
    candidates = []
    for line in (output or '').splitlines():
        match = re.match(r'^\d+:\s+([^:@\s]+)', line)
        if match:
            interface = match.group(1)
            continue
        match = re.match(r'^\s+inet (\d+\.\d+\.\d+\.\d+)/', line)
        if not match:
            continue
        ip = match.group(1)
        if ip.startswith('127.') or re.match(r'^(lo|rmnet|dummy|tun|p2p|ccmni)', interface):
            continue
        candidates.append((interface, ip))
    ordered = ([c for c in candidates if c[0].startswith('wlan')] + [c for c in candidates if c[0].startswith('eth')]
               + candidates)
    return ordered[0][1] if ordered else None


def parse_software_encoder(output, codec):
    fallback = None
    pattern = re.compile(r'--video-codec=' + re.escape(codec) + r'\s+--video-encoder=(\S+)')
    for line in (output or '').splitlines():
        match = pattern.search(line)
        if not match or '(alias' in line:
            continue
        encoder = match.group(1)
        if '(sw)' in line:
            return encoder
        if not fallback and '(hw)' not in line and re.match(r'^(OMX\.google\.|c2\.android\.)', encoder):
            fallback = encoder
    return fallback


def known_software_encoder(codec, sdk):
    known = {'h264': ('c2.android.avc.encoder', 'OMX.google.h264.encoder'), 'h265': ('c2.android.hevc.encoder', None)}
    if codec not in known or not sdk:
        return None
    return known[codec][0] if sdk >= 29 else known[codec][1]


def _seconds_since(moment, now):
    return (now - moment).total_seconds() if moment else 0


def usb_priority(devices, sessions, wifi_serials, moved_usb, now, serial_filter=()):
    standby = {}
    handovers = []
    if serial_filter:
        return standby, handovers
    known = list(dict.fromkeys(list(devices) + list(sessions)))
    if not any(connection_type(s) == 'USB' for s in known):
        return standby, handovers
    for address in [s for s in known if connection_type(s) == 'Wi-Fi']:
        usb_serial = wifi_serials.get(address)
        if not usb_serial or usb_serial in moved_usb:
            continue
        usb_session = sessions.get(usb_serial)
        wifi = sessions.get(address)
        usb_online = devices.get(usb_serial) == 'device'
        wifi_online = devices.get(address) == 'device'
        if not usb_online and not (usb_session and not usb_session.user_closed):
            continue
        if (wifi and (wifi.moved_to or wifi.user_closed)) or (usb_session and usb_session.moved_to):
            continue
        usb_preferred = (usb_online or not wifi_online or usb_session is None or usb_session.recording
                         or not usb_session.missing_since or _seconds_since(usb_session.missing_since, now) < 30)
        wifi_recording = bool(wifi and wifi.recording)
        if (wifi_recording and usb_online and not wifi_online and wifi.missing_since
                and _seconds_since(wifi.missing_since, now) >= 30):
            handovers.append((address, usb_serial))
            wifi_recording = False
        if usb_preferred and not wifi_recording:
            standby[address] = usb_serial
        elif not (usb_session and (usb_session.user_closed or usb_session.recording)):
            standby[usb_serial] = address
    return standby, handovers


def moved_away(serial, devices, moved_usb, sessions, now):
    address = moved_usb.get(serial)
    if not address:
        return False, False
    wifi = sessions.get(address)
    if wifi:
        wifi_lost = (devices.get(address) != 'device' and bool(wifi.missing_since)
                     and _seconds_since(wifi.missing_since, now) >= 30 and devices.get(serial) == 'device')
        if not wifi.disconnected and not wifi_lost:
            return True, False
    elif devices.get(address) == 'device':
        return True, False
    return False, True


def update_asset_name(system, machine, tag):
    machine = (machine or '').lower()
    if system == 'darwin':
        arch = 'arm64' if machine in ('arm64', 'aarch64') else 'x86_64'
        return f'scrcpy-monitor-macos-{arch}-{tag}.zip'
    if system == 'linux':
        arch = {'amd64': 'x86_64', 'arm64': 'aarch64'}.get(machine, machine or 'x86_64')
        return f'scrcpy-monitor-linux-{arch}-{tag}.tar.gz'
    return None


def parse_iso_datetime(text):
    if not text:
        return None
    text = str(text).strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    text = re.sub(r'(\.\d{6})\d+', r'\1', text)
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value


def find_update(release, current_version, built, system, machine):
    if not release or not release.get('tag_name'):
        return None
    tag = str(release['tag_name'])
    if tag == current_version:
        return None
    asset = None
    expected = update_asset_name(system, machine, tag)
    if expected:
        asset = next((a for a in release.get('assets') or [] if a.get('name') == expected), None)
        if not asset:
            return None
    if built:
        published = parse_iso_datetime(release.get('published_at'))
        if published and published <= built:
            return None
    return {'tag': tag, 'url': asset.get('browser_download_url') if asset else None,
            'page': release.get('html_url') or '', 'notes': release.get('body') or ''}


def format_elapsed(seconds):
    seconds = max(0, int(seconds))
    return f'{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}'

def format_seconds(value):
    text = f'{value:.3f}'.rstrip('0').rstrip('.')
    return text if text not in ('', '-0') else '0'


def combine_grid(count):
    cols = count if count <= 3 else math.ceil(math.sqrt(count))
    return cols, math.ceil(count / cols)


def combine_cell(sizes, cols, rows):
    cell_h = min(1280.0, float(max(h for _, h in sizes)))
    cell_w = max(w * cell_h / h for w, h in sizes)
    scale = min(1.0, 3840 / (cols * cell_w), 2160 / (rows * cell_h))
    return max(16, int(cell_w * scale / 2) * 2), max(16, int(cell_h * scale / 2) * 2)


def combine_command(members, sizes, t0, encoder_args, output):
    cols, rows = combine_grid(len(members))
    cell_w, cell_h = combine_cell(sizes, cols, rows)
    chain = (f'scale={cell_w}:{cell_h}:force_original_aspect_ratio=decrease:force_divisible_by=2:eval=frame,'
             f'pad={cell_w}:{cell_h}:(ow-iw)/2:(oh-ih)/2:eval=frame,setsar=1')
    inputs, filters, overlays = [], [], []
    total = 0.0
    index = 0
    for number, segments in enumerate(members):
        x = number % cols * cell_w
        y = number // cols * cell_h
        for segment in segments:
            offset = max(0.0, (segment['start'] - t0).total_seconds())
            total = max(total, offset + segment['duration'])
            inputs += ['-reinit_filter', '0', '-ss', format_seconds(segment['position']), '-t',
                       format_seconds(segment['duration']), '-i', segment['path']]
            filters.append(f'[{index}:v]setpts=PTS-STARTPTS+{format_seconds(offset)}/TB,{chain}[v{index}]')
            overlays.append(f'[b{index}][v{index}]overlay=x={x}:y={y}:eof_action=pass[b{index + 1}]')
            index += 1
    graph = ';'.join([f'color=c=black:s={cols * cell_w}x{rows * cell_h}:r=30:d={format_seconds(total)}[b0]']
                     + filters + overlays)
    args = (['-hide_banner', '-nostdin', '-loglevel', 'error', '-y'] + inputs
            + ['-filter_complex', graph, '-map', f'[b{index}]', '-an'] + list(encoder_args)
            + ['-pix_fmt', 'yuv420p', '-r', '30', '-movflags', '+faststart', '-t', format_seconds(total), output])
    return args, total, index


def combine_encoder_args(encoders):
    if re.search(r'\slibx264\s', encoders or ''):
        return ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23']
    if re.search(r'\slibopenh264\s', encoders or ''):
        return ['-c:v', 'libopenh264', '-b:v', '8M']
    return ['-c:v', 'mpeg4', '-q:v', '4']
