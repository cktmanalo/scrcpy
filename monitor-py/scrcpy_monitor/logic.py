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


def parse_version(text):
    if not re.match(r'^\s*\d+(\.\d+){1,3}\s*$', text or ''):
        return None
    parts = [int(p) for p in text.strip().split('.')]
    if any(p > 2147483647 for p in parts):
        return None
    return tuple(parts)


def is_newer_version(tag, current):
    latest = parse_version(display_version(tag))
    installed = parse_version(display_version(current))
    if latest is None or installed is None:
        return True
    return latest > installed


def parse_power_watch(output):
    match = re.match(r'^(.*)/([^/]*)$', (output or '').strip())
    if not match:
        return None
    requested, powerctl = match.group(1), match.group(2)
    if requested.startswith('1') or powerctl.lower().startswith('reboot'):
        return 'restarting'
    if requested.startswith('0') or powerctl.lower().startswith('shutdown'):
        return 'off'
    return None


def sort_key(texts, column):
    text = texts[column] if column < len(texts) else ''
    return text.casefold(), (texts[0].casefold() if column and texts else '')


def free_port_block(used, base=PORT_BASE, span=PORT_RANGE, step=PORT_STEP):
    used = set(used)
    for port in range(base, base + span, step):
        if port not in used:
            return port
    return base


def has_port_arg(arguments):
    return any(re.match(r'^(--port|-p)', arg) for arg in arguments)


def has_placement_arg(arguments):
    return any(re.match(r'^(--window-(x|y|width|height)|--fullscreen|-f)(=|$)', arg) for arg in arguments)


def window_layout(area, items, gap=8):
    left, top, area_width, area_height = area
    count = len(items)
    if not count:
        return None
    frame_height = max(item['frame_height'] for item in items)
    best, best_score = None, 0
    for rows in range(1, count + 1):
        columns = math.ceil(count / rows)
        if math.ceil(count / columns) != rows:
            continue
        groups = [items[start:start + columns] for start in range(0, count, columns)]
        height = (area_height - (rows + 1) * gap) / rows - frame_height
        for group in groups:
            aspect = frames = 0
            for item in group:
                aspect += item['aspect']
                frames += item['frame_width']
            height = min(height, (area_width - (len(group) + 1) * gap - frames) / aspect)
        if height < 50:
            continue
        score = 0
        for item in items:
            score += min(height, item['max_height']) ** 2 * item['aspect']
        if score > best_score * 1.001:
            best, best_score = (groups, height), score
    if not best:
        return None
    groups, height = best
    row_sizes = [[(round(min(height, item['max_height']) * item['aspect'] + item['frame_width']),
                   round(min(height, item['max_height']) + item['frame_height'])) for item in group]
                 for group in groups]
    total_height = sum(max(h for _, h in sizes) for sizes in row_sizes) + (len(groups) - 1) * gap
    y = top + (area_height - total_height) // 2
    rects = []
    for sizes in row_sizes:
        row_height = max(h for _, h in sizes)
        row_width = sum(w for w, _ in sizes) + (len(sizes) - 1) * gap
        x = left + (area_width - row_width) // 2
        for width, height in sizes:
            rects.append((x, y + (row_height - height) // 2, width, height))
            x += width + gap
        y += row_height + gap
    return rects


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


def usb_priority(devices, sessions, wifi_serials, moved_usb, now, serial_filter=(), skip=()):
    standby = {}
    handovers = []
    if serial_filter:
        return standby, handovers
    known = list(dict.fromkeys(list(devices) + list(sessions)))
    if not any(connection_type(s) == 'USB' for s in known):
        return standby, handovers
    for address in [s for s in known if connection_type(s) == 'Wi-Fi']:
        usb_serial = wifi_serials.get(address)
        if not usb_serial or usb_serial in moved_usb or address in skip:
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
    if tag == current_version or not is_newer_version(tag, current_version):
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


def combine_header_height(cell_h):
    return max(16, cell_h // 40 * 2)


def _even(value):
    return max(2, int(round(value / 2)) * 2)


def combine_layout(sizes, naturals=None, area=None, gap=8):
    area_w, area_h = (area[2], area[3]) if area and area[2] > 0 and area[3] > 0 else (1920, 1080)
    title = max(16, area_h // 36)
    items = []
    for number, (width, height) in enumerate(sizes):
        aspect = width / height
        natural = naturals[number] if naturals and number < len(naturals) and naturals[number] else 0
        if natural > 0:
            max_height = natural / max(1, aspect)
        else:
            max_height = height * min(1.0, max(1, area_w - 96) / width, max(1, area_h - 96) / height)
        items.append({'aspect': aspect, 'frame_width': 0, 'frame_height': title, 'max_height': max_height})
    rects = None
    for grow in (1, 2, 4, 8, 16):
        rects = window_layout((0, 0, area_w * grow, area_h * grow), items, gap)
        if rects:
            break
    if not rects:
        rects = [(n * 66, 0, 58, 50 + title) for n in range(len(sizes))]
    left = min(x for x, _, _, _ in rects)
    top = min(y for _, y, _, _ in rects)
    width = max(x + w for x, _, w, _ in rects) - left + 2 * gap
    height = max(y + h for _, y, _, h in rects) - top + 2 * gap
    ratio = max(h / max(1, rect[3] - title) for (_, h), rect in zip(sizes, rects))
    scale = min(max(1.0, ratio), 2560 / width, 1440 / height)
    for _ in range(8):
        header_h = _even(title * scale)
        tiles = []
        for x, y, w, h in rects:
            tile_x = _even((x - left + gap) * scale)
            tile_y = _even((y - top + gap) * scale) + header_h
            tiles.append((tile_x, tile_y, _even(w * scale), _even((h - title) * scale)))
        margin = _even(gap * scale)
        canvas_w = max(x + w for x, _, w, _ in tiles) + margin
        canvas_h = max(y + h for _, y, _, h in tiles) + margin
        if canvas_w <= 2560 and canvas_h <= 1440:
            break
        scale *= min(1.0, 2558 / canvas_w, 1438 / canvas_h)
    return canvas_w, canvas_h, header_h, tiles


def combine_chain(tile_w, tile_h):
    fit = f'min({tile_w}/iw,{tile_h}/ih)'
    return (f"scale=w='max(2,trunc(iw*{fit}/2)*2)':h='max(2,trunc(ih*{fit}/2)*2)':eval=frame,"
            f'pad={tile_w}:{tile_h}:(ow-iw)/2:(oh-ih)/2:eval=frame,setsar=1')


def combine_command(members, layout, t0, encoder_args, output, headers=()):
    canvas_w, canvas_h, header_h, tiles = layout
    inputs, filters, overlays = [], [], []
    total = 0.0
    index = 0
    for number, segments in enumerate(members):
        x, y, tile_w, tile_h = tiles[number]
        chain = combine_chain(tile_w, tile_h)
        for segment in segments:
            offset = max(0.0, (segment['start'] - t0).total_seconds())
            total = max(total, offset + segment['duration'])
            inputs += ['-reinit_filter', '0', '-ss', format_seconds(segment['position']), '-t',
                       format_seconds(segment['duration']), '-i', segment['path']]
            filters.append(f'[{index}:v]setpts=PTS-STARTPTS+{format_seconds(offset)}/TB,{chain}[v{index}]')
            overlays.append(f'[b{index}][v{index}]overlay=x={x}:y={y}:eof_action=pass[b{index + 1}]')
            index += 1
    base = f'color=c=0x505050:s={canvas_w}x{canvas_h}:r=30:d={format_seconds(total)}'
    header_filters = []
    for number, header in enumerate(headers):
        inputs += ['-i', header]
        source = f'[h{number}]' if number else f'{base}[h0];[h0]'
        target = '[b0]' if number == len(headers) - 1 else f'[h{number + 1}]'
        x, y, _, _ = tiles[number]
        header_filters.append(f'{source}[{index + number}:v]overlay=x={x}:y={y - header_h}{target}')
    if not headers:
        header_filters.append(f'{base}[b0]')
    graph = ';'.join(header_filters + filters + overlays)
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


def fps_passthrough_args(version_text):
    match = re.search(r'ffmpeg version n?(\d+)\.(\d+)', version_text or '')
    version = (int(match.group(1)), int(match.group(2))) if match else None
    if version and version < (4, 0):
        return ['-vsync', 'passthrough']
    time_base = ['-enc_time_base', '1:60000']
    if version and version < (5, 1):
        return ['-vsync', 'passthrough'] + time_base
    return ['-fps_mode', 'passthrough'] + time_base


def label_layout(width, height):
    width = max(16, (width + 1) // 2 * 2)
    height = max(16, (height + 1) // 2 * 2)
    return width, height, combine_header_height(height)


def label_command(source, header, width, height, header_h, encoder_args, fps_args, output):
    fit = f'min({width}/iw,{height}/ih)'
    graph = (f"[0:v]scale=w='max(2,trunc(iw*{fit}/2)*2)':h='max(2,trunc(ih*{fit}/2)*2)':eval=frame,"
             f'pad={width}:{height + header_h}:(ow-iw)/2:{header_h}+({height}-ih)/2:eval=frame,setsar=1[v];'
             f'[v][1:v]overlay=x=0:y=0[out]')
    return (['-hide_banner', '-nostdin', '-loglevel', 'error', '-y', '-reinit_filter', '0', '-i', source, '-i', header,
             '-filter_complex', graph, '-map', '[out]', '-map', '0:a?', '-c:a', 'copy'] + list(encoder_args)
            + ['-bf', '0', '-pix_fmt', 'yuv420p'] + list(fps_args) + ['-movflags', '+faststart', output])
