import ipaddress
import math
import os
import re
import shutil
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


SCREEN_FOLLOW_SIZES = ((1920, 1080), (1280, 720), (854, 480), (640, 360), (800, 600), (640, 480))
SCREEN_FRAME_SIZES = ((1920, 1080), (1280, 720), (854, 480), (640, 360), (1024, 768), (800, 600), (640, 480),
                      (320, 240))


def even_size(value):
    value = int(value)
    return max(2, value - value % 2)


def rect_intersect(a, b):
    left, top = max(a[0], b[0]), max(a[1], b[1])
    right, bottom = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    if right <= left or bottom <= top:
        return (0, 0, 0, 0)
    return (left, top, right - left, bottom - top)


def rect_union(rects):
    rects = list(rects)
    left, top = min(r[0] for r in rects), min(r[1] for r in rects)
    right, bottom = max(r[0] + r[2] for r in rects), max(r[1] + r[3] for r in rects)
    return (left, top, right - left, bottom - top)


def rect_contains(outer, inner):
    return (inner[0] >= outer[0] and inner[1] >= outer[1] and inner[0] + inner[2] <= outer[0] + outer[2]
            and inner[1] + inner[3] <= outer[1] + outer[3])


def format_bytes(count):
    if count >= 1 << 30:
        return f'{count / (1 << 30):.2f} GB'
    if count >= 1 << 20:
        return f'{count / (1 << 20):.1f} MB'
    return f'{count / 1024:.0f} KB'


DISK_LOW = 2 << 30
DISK_CRITICAL = 500 << 20


def existing_folder(path):
    current = os.path.abspath(os.path.expanduser(str(path or '.')))
    while not os.path.isdir(current):
        parent = os.path.dirname(current)
        if not parent or parent == current:
            return None
        current = parent
    return current


def disk_free(path):
    folder = existing_folder(path)
    if not folder:
        return -1
    try:
        return shutil.disk_usage(folder).free
    except (OSError, ValueError):
        return -1


def disk_level(free):
    if free < 0:
        return 'unknown'
    if free < DISK_CRITICAL:
        return 'critical'
    if free < DISK_LOW:
        return 'low'
    return 'ok'


def normalize_screen_area(area):
    if not area or area[2] < 16 or area[3] < 16:
        return None
    return (int(area[0]), int(area[1]), even_size(area[2]), even_size(area[3]))


def screen_area_from_setting(text, virtual, primary):
    match = re.match(r'^(-?\d+),(-?\d+),(\d+),(\d+)$', str(text or ''))
    if match:
        area = tuple(int(value) for value in match.groups())
        if area[2] >= 16 and area[3] >= 16 and rect_contains(virtual, area):
            return area
    width = even_size(min(1280, primary[2] - 80))
    height = even_size(min(720, primary[3] - 160))
    return (primary[0] + (primary[2] - width) // 2, primary[1] + (primary[3] - height) // 2, width, height)


def parse_follow_size(text):
    match = re.match(r'^(\d+)x(\d+)$', str(text or ''))
    if match and int(match.group(1)) >= 64 and int(match.group(2)) >= 64:
        return int(match.group(1)), int(match.group(2))
    return 1280, 720


def follow_area(cursor, bounds, size):
    width = even_size(min(size[0], bounds[2]))
    height = even_size(min(size[1], bounds[3]))
    x = max(bounds[0], min(cursor[0] - width // 2, bounds[0] + bounds[2] - width))
    y = max(bounds[1], min(cursor[1] - height // 2, bounds[1] + bounds[3] - height))
    return (x, y, width, height)


def follow_offset(area, box, width, height):
    x = max(0, min(area[0] - box[0], box[2] - width))
    y = max(0, min(area[1] - box[1], box[3] - height))
    return x, y


def screen_capture_command(kind, sources, area, follow, encoder_args, output, display=':0', shot=False):
    box = rect_union(rect for _, rect in sources)
    if not follow:
        area = rect_intersect(area, box)
    width = even_size(min(area[2], box[2]))
    height = even_size(min(area[3], box[3]))
    if kind != 'avfoundation' and not follow:
        box = (area[0], area[1], width, height)
    x, y = follow_offset(area, box, width, height)
    crop = follow or width != box[2] or height != box[3]
    inputs = []
    if kind == 'avfoundation':
        chains = []
        for index, (device, rect) in enumerate(sources):
            inputs += ['-f', 'avfoundation', '-capture_cursor', '1', '-framerate', '30', '-i', f'{device}:none']
            chains.append(f'[{index}:v]scale={rect[2]}:{rect[3]},setsar=1')
        if len(sources) == 1:
            graph = chains[0]
        else:
            labels = ''.join(f'[s{index}]' for index in range(len(sources)))
            layout = '|'.join(f'{rect[0] - box[0]}_{rect[1] - box[1]}' for _, rect in sources)
            graph = (';'.join(f'{chain}[s{index}]' for index, chain in enumerate(chains))
                     + f';{labels}xstack=inputs={len(sources)}:layout={layout}:fill=black')
    else:
        inputs = ['-f', kind, '-framerate', '30', '-draw_mouse', '1']
        if kind == 'x11grab':
            inputs += ['-video_size', f'{box[2]}x{box[3]}', '-i', f'{display}+{box[0]},{box[1]}']
        else:
            inputs += ['-offset_x', str(box[0]), '-offset_y', str(box[1]), '-video_size', f'{box[2]}x{box[3]}',
                       '-i', 'desktop']
        graph = '[0:v]null'
    if crop:
        graph += f',crop=w={width}:h={height}:x={x}:y={y}:exact=1'
    head = ['-hide_banner', '-loglevel', 'warning', '-nostats', '-stats_period', '0.05']
    if shot:
        return head + inputs + ['-filter_complex', graph + ',format=rgb24[v]', '-map', '[v]', '-frames:v', '1',
                                '-update', '1', '-y', output], None
    args = (head + inputs + ['-filter_complex', graph + ',format=yuv420p[v]', '-map', '[v]'] + list(encoder_args)
            + ['-pix_fmt', 'yuv420p', '-g', '60', '-y', output])
    return args, {'box': box, 'width': width, 'height': height, 'x': x, 'y': y} if follow else None


def screen_merge_steps(parts, sizes, list_file, output, encoder_args):
    if len(set(sizes)) <= 1:
        lines = ["file '" + str(part).replace("'", "'\\''") + "'" for part in parts]
        return [['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(list_file),
                 '-c', 'copy', '-movflags', '+faststart', output]], lines
    width = max(size[0] for size in sizes)
    height = max(size[1] for size in sizes)
    inputs, filters = [], []
    for index, part in enumerate(parts):
        inputs += ['-i', str(part)]
        filters.append(f'[{index}:v]scale={width}:{height}:force_original_aspect_ratio=decrease,'
                       f'pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1[v{index}]')
    labels = ''.join(f'[v{index}]' for index in range(len(parts)))
    graph = ';'.join(filters) + f';{labels}concat=n={len(parts)}:v=1:a=0[v]'
    return [['-hide_banner', '-nostdin', '-loglevel', 'error', '-y'] + inputs + ['-filter_complex', graph, '-map', '[v]']
            + list(encoder_args) + ['-pix_fmt', 'yuv420p', '-movflags', '+faststart', output]], None


def parse_avfoundation_screens(text):
    return {int(match.group(2)): int(match.group(1))
            for match in re.finditer(r'\[(\d+)\] Capture screen (\d+)', text or '')}


LOGCAT_HEADER = re.compile(r'^\[ (\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\s+(?:\S+:\s*)?(\d+):\s*(\d+)\s+'
                           r'([VDIWEFAS])/(.*?)\s*\]$')
_BOOT_ID = re.compile(r'^[0-9a-fA-F-]{16,}$')
_DEVICE_CLOCK = re.compile(r'^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)()')
LOG_RULE = '-' * 28


def parse_logcat_header(line, now):
    match = LOGCAT_HEADER.match(line)
    if not match:
        return None
    return _log_time(match, now), int(match.group(7)), int(match.group(8)), match.group(9), match.group(10).strip()


def _log_time(match, now):
    month = int(match.group(1))
    year = now.year - 1 if month > now.month + 1 else now.year
    try:
        return datetime(year, month, int(match.group(2)), int(match.group(3)), int(match.group(4)),
                        int(match.group(5)), int((match.group(6) + '000')[:3]) * 1000)
    except ValueError:
        return now


def parse_device_time(text, now):
    match = _DEVICE_CLOCK.match((text or '').strip())
    return _log_time(match, now) if match else None


def logcat_prefix(moment, pid, tid, tag, app, level):
    return (f'{moment:%Y-%m-%d %H:%M:%S}.{moment.microsecond // 1000:03d}  {pid:>5}-{tid:<5}  {tag:<23}  '
            f'{app:<35}  {level}  ')


def log_marker(text, now):
    return f'{LOG_RULE} {text} ({now:%Y-%m-%d %H:%M:%S}) {LOG_RULE}'


def boot_id(text):
    text = (text or '').strip()
    return text if _BOOT_ID.match(text) else ''


def parse_process_names(text):
    names = {}
    pid_column = -1
    for raw in (text or '').split('\n'):
        parts = raw.split()
        if len(parts) < 2:
            continue
        if pid_column < 0:
            pid_column = parts.index('PID') if 'PID' in parts else -1
            continue
        if len(parts) <= pid_column or not parts[pid_column].isdigit():
            continue
        name = parts[-1]
        if name == 'system_server':
            name = 'system_process'
        if name.startswith(('zygote', 'usap')) or name == '<pre-initialized>':
            continue
        names[int(parts[pid_column])] = name
    return names


def device_log_path(folder, device_name, serial, moment, exists):
    stem = f'logs_{device_name}_{serial}_{moment:%Y%m%d_%H%M%S}'
    path = os.path.join(folder, f'{stem}.txt')
    suffix = 2
    while exists(path):
        path = os.path.join(folder, f'{stem}_{suffix}.txt')
        suffix += 1
    return path


def parse_packages(text):
    return {line.strip()[8:] for line in (text or '').split('\n') if line.strip().startswith('package:')} - {''}


def app_package(name, packages):
    package = (name or '').split(':', 1)[0].strip()
    if not package:
        return None
    if package == 'system_process':
        return package
    if packages:
        return package if package in packages else None
    return package if '.' in package and not any(c in package for c in '/@ ') else None


def log_app(name, apps):
    package = (name or '').split(':', 1)[0].strip()
    return package if package and package in apps else None


def parse_log_apps(value):
    if isinstance(value, str):
        value = value.split(',')
    if not isinstance(value, (list, tuple, set, frozenset)):
        return []
    return sorted({str(item).strip() for item in value if str(item).strip()})


PA_PACKAGE = 'com.global.wwca'
PIA_PACKAGE = 'com.global.integrated'
VERSION_COMMAND = (f'if [ "$(getprop sys.boot_completed)" = 1 ]; then for p in {PA_PACKAGE} {PIA_PACKAGE}; do '
                   'echo "@$p"; dumpsys package $p | grep -E \'versionName|Unable to find\'; done; fi')
_VERSION_NAME = re.compile(r'versionName=(\S+)')
_START_PROC = re.compile(r'^Start proc (\d+):([^/\s]+)/')
_KILLING = re.compile(r'^Killing (\d+):([^/\s]+)/\S+(?: \(adj -?\d+\))?: (.*)$')
_DIED = re.compile(r'^Process (\S+) \(pid (\d+)\) has died')
_ANR = re.compile(r'^ANR in (\S+)')


def log_app_choices(running, opened, installed, chosen):
    groups = [{item for item in group if item} for group in (opened, running, installed, chosen)]
    every = set().union(*groups)
    result = [package for package in (PA_PACKAGE, PIA_PACKAGE) if package in every]
    for group in groups:
        result += [item for item in sorted(group) if item not in result]
    return result


def parse_app_versions(text):
    versions = {}
    resolved = set()
    current = None
    for raw in (text or '').split('\n'):
        line = raw.strip()
        if line.startswith('@'):
            current = line[1:]
            versions.setdefault(current, '')
            continue
        if current is None or versions[current]:
            continue
        if line.startswith('Unable to find'):
            resolved.add(current)
            continue
        match = _VERSION_NAME.search(line)
        if match:
            versions[current] = match.group(1)
            resolved.add(current)
    if PA_PACKAGE not in resolved or PIA_PACKAGE not in resolved:
        return None
    return versions


def app_version_text(versions):
    if versions is None:
        return None
    return (f'PA ({PA_PACKAGE}) {versions.get(PA_PACKAGE) or "Not installed"}, '
            f'PIA ({PIA_PACKAGE}) {versions.get(PIA_PACKAGE) or "Not installed"}')


def version_mismatch(version_dicts, package):
    return len({versions.get(package) for versions in version_dicts if versions.get(package)}) > 1


def app_tag(package):
    return {PA_PACKAGE: ' (PA)', PIA_PACKAGE: ' (PIA)'}.get(package, '')


def app_label(package):
    return {PA_PACKAGE: f'PA ({PA_PACKAGE})', PIA_PACKAGE: f'PIA ({PIA_PACKAGE})'}.get(package, package)


def app_status_text(processes, chosen):
    tracked = [PA_PACKAGE, PIA_PACKAGE]
    tracked += sorted({app for app in chosen or () if app not in tracked})
    parts = []
    for app in tracked:
        found = sorted(pid for pid, name in processes.items() if name == app)
        parts.append(app_label(app) + (f' running (pid {", ".join(map(str, found))})' if found else ' not running'))
    return ', '.join(parts)


def parse_app_event(tag, message):
    if tag == 'ActivityManager':
        match = _START_PROC.match(message)
        if match:
            return 'APP STARTED', match.group(2), match.group(1), ''
        match = _KILLING.match(message)
        if match:
            return 'APP STOPPED', match.group(2), match.group(1), match.group(3).strip()
        match = _DIED.match(message)
        if match:
            return 'APP STOPPED', match.group(1), match.group(2), 'process died'
        match = _ANR.match(message)
        if match:
            return 'APP NOT RESPONDING', match.group(1), '', ''
        return None
    if ((tag == 'AndroidRuntime' and message.startswith('FATAL EXCEPTION'))
            or (tag == 'libc' and message.startswith('Fatal signal'))):
        return 'APP CRASHED', '', '', message.strip()
    return None


def running_apps(ps_text, packages):
    return {package for package in (app_package(name, packages) for name in parse_process_names(ps_text).values())
            if package}


def foreground_app(text):
    for pattern in (r'mCurrentFocus=Window\{[^}]*?\s([\w.]+)/', r'mFocusedApp=\S*\{[^}]*?\s([\w.]+)/',
                    r'mResumedActivity:? ActivityRecord\{[^}]*?\s([\w.]+)/'):
        match = re.search(pattern, text or '')
        if match:
            return match.group(1)
    return None


def app_log_path(path, package):
    folder = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', package).strip('. ') or '_'
    return os.path.join(os.path.dirname(path), folder, os.path.basename(path))


def screen_capture_base(folder, moment, exists):
    stem = moment.strftime('Screen_Capture_%Y%m%d_%H%M%S')
    base = os.path.join(folder, stem)
    suffix = 2
    while exists(f'{base}.mp4') or exists(f'{base}_part01.mkv'):
        base = os.path.join(folder, f'{stem}_{suffix}')
        suffix += 1
    return base

def snip_format(value):
    return 'jpg' if value == 'jpg' else 'png'


def snip_file_name(moment, file_format):
    return f'Snip_{moment:%Y%m%d_%H%M%S}_{moment.microsecond // 1000:03d}.{snip_format(file_format)}'


def snip_status(path, saved, copied):
    if saved and copied:
        return f'Copied to the clipboard and saved: {path}'
    if saved:
        return f'Saved: {path} (could not copy to the clipboard)'
    if copied:
        return 'Copied to the clipboard (could not save the file)'
    return 'Could not copy or save the snip'


def snip_save_path(path, jpeg_filter):
    if os.path.splitext(path)[1].lower() in ('.png', '.jpg', '.jpeg'):
        return path
    return path + ('.jpg' if jpeg_filter else '.png')


def is_jpeg(path):
    return os.path.splitext(str(path))[1].lower() in ('.jpg', '.jpeg')


def rect_from_points(a, b):
    left, top = min(a[0], b[0]), min(a[1], b[1])
    return (left, top, max(a[0], b[0]) - left, max(a[1], b[1]) - top)


def rect_intersection(a, b):
    left, top = max(a[0], b[0]), max(a[1], b[1])
    right, bottom = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    if right <= left or bottom <= top:
        return None
    return (left, top, right - left, bottom - top)


def point_in_rect(rect, x, y):
    return rect[0] <= x < rect[0] + rect[2] and rect[1] <= y < rect[1] + rect[3]


def snip_target(windows, screens, x, y):
    for rect in windows:
        if point_in_rect(rect, x, y):
            return rect
    for rect in screens:
        if point_in_rect(rect, x, y):
            return rect
    return None


def snip_native_to_logical(rect, displays):
    x, y = rect[0] + rect[2] // 2, rect[1] + rect[3] // 2
    origin, ratio = (0, 0), 1
    for capture, dpr in displays:
        if point_in_rect(capture, x, y):
            origin, ratio = (capture[0], capture[1]), dpr or 1
            break
    left = origin[0] + (rect[0] - origin[0]) / ratio
    top = origin[1] + (rect[1] - origin[1]) / ratio
    return (round(left), round(top), round(rect[2] / ratio), round(rect[3] / ratio))


def snip_window_rects(rects, bounds):
    found = []
    for rect in rects:
        clipped = rect_intersection(rect, bounds) if rect and rect[2] > 0 and rect[3] > 0 else None
        if clipped:
            found.append(clipped)
    return found


def fit_zoom(view_width, view_height, image_width, image_height):
    if view_width <= 0 or view_height <= 0 or image_width <= 0 or image_height <= 0:
        return 1.0
    return max(0.05, min(1.0, min((view_width - 16) / image_width, (view_height - 16) / image_height)))


def segment_distance(point, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = dx * dx + dy * dy
    t = 0.0 if length <= 0 else max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length))
    return math.hypot(a[0] + t * dx - point[0], a[1] + t * dy - point[1])


def shape_hit(kind, points, width, point, tolerance):
    limit = width / 2 + tolerance
    if kind == 'rect':
        left, top, w, h = rect_from_points(points[0], points[1])
        corners = ((left, top), (left + w, top), (left + w, top + h), (left, top + h))
        return any(segment_distance(point, corners[i], corners[(i + 1) % 4]) <= limit for i in range(4))
    if len(points) == 1:
        return segment_distance(point, points[0], points[0]) <= limit
    return any(segment_distance(point, points[i - 1], points[i]) <= limit for i in range(1, len(points)))


def arrow_geometry(a, b, width):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy)
    if length < 1:
        return None
    head = min(length, max(12.0, width * 4))
    ux, uy = dx / length, dy / length
    bottom = (b[0] - ux * head, b[1] - uy * head)
    half = head * 0.55
    left = (bottom[0] - uy * half, bottom[1] + ux * half)
    right = (bottom[0] + uy * half, bottom[1] - ux * half)
    shaft = (b[0] - ux * head * 0.7, b[1] - uy * head * 0.7) if length > head else None
    return shaft, (b, left, right)


def crop_area(start, end, image_width, image_height):
    rect = rect_from_points(start, end)
    left, top = max(0.0, rect[0]), max(0.0, rect[1])
    right, bottom = min(float(image_width), rect[0] + rect[2]), min(float(image_height), rect[1] + rect[3])
    if right <= left or bottom <= top:
        return None
    x, y = round(left), round(top)
    w, h = round(right) - x, round(bottom) - y
    if w < 4 or h < 4 or (w, h) == (image_width, image_height):
        return None
    return (x, y, w, h)