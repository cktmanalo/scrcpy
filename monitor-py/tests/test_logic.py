import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from scrcpy_monitor import logic

NOW = datetime(2026, 10, 9, 12, 0, 0)


def session(**values):
    defaults = dict(user_closed=False, moved_to=None, recording=False, missing_since=None, disconnected=False)
    defaults.update(values)
    return SimpleNamespace(**defaults)


class ParseAdbDevicesTest(unittest.TestCase):
    def test_states(self):
        output = ('* daemon not running; starting now at tcp:5037\n'
                  '* daemon started successfully\n'
                  'List of devices attached\r\n'
                  '810-880-708\tdevice\r\n'
                  '192.168.68.103:5555\tdevice\n'
                  '192.168.68.104:5037\toffline\n'
                  'R58M12345\tunauthorized\n'
                  'emulator-5554\tauthorizing\n'
                  'ABC123\tno permissions (missing udev rules); see [http://developer.android.com/tools/device.html]\n'
                  '\n')
        devices = logic.parse_adb_devices(output)
        self.assertEqual(devices['810-880-708'], 'device')
        self.assertEqual(devices['192.168.68.103:5555'], 'device')
        self.assertEqual(devices['192.168.68.104:5037'], 'offline')
        self.assertEqual(devices['R58M12345'], 'unauthorized')
        self.assertEqual(devices['emulator-5554'], 'authorizing')
        self.assertTrue(devices['ABC123'].startswith('no permissions'))
        self.assertEqual(len(devices), 6)

    def test_empty(self):
        self.assertEqual(logic.parse_adb_devices('List of devices attached\n\n'), {})
        self.assertEqual(logic.parse_adb_devices(''), {})
        self.assertEqual(logic.parse_adb_devices(None), {})

    def test_connection_type(self):
        self.assertEqual(logic.connection_type('810-880-708'), 'USB')
        self.assertEqual(logic.connection_type('192.168.68.103:5555'), 'Wi-Fi')
        self.assertEqual(logic.connection_type('adb-R58M-abc._adb-tls-connect._tcp'), 'Wi-Fi')
        self.assertEqual(logic.connection_type('emulator-5554'), 'Emulator')

    def test_mdns(self):
        output = ('List of discovered mdns services\n'
                  'adb-R58M-abc\t_adb-tls-connect._tcp\t192.168.68.50:37000\n'
                  'adb-R58M-abc\t_adb._tcp.\t192.168.68.50:5555\n')
        self.assertEqual(logic.parse_mdns_services(output), [('adb-R58M-abc', '192.168.68.50:5555')])


class ConnectFailureReasonTest(unittest.TestCase):
    def test_refused(self):
        reason = logic.connect_failure_reason(
            '192.168.68.20:5038', 'cannot connect to 192.168.68.20:5038: No connection could be made because the '
                                  'target machine actively refused it. (10061)')
        self.assertIn('port 5038 is not open', reason)
        self.assertIn('adb tcpip 5038', reason)

    def test_unknown_host(self):
        reason = logic.connect_failure_reason('phone.lan:5555', 'failed to resolve host: phone.lan: No such host')
        self.assertEqual(reason, 'The address phone.lan could not be found. Check the IP address.')

    def test_unauthorized(self):
        reason = logic.connect_failure_reason('192.168.68.20:5555', 'failed to authenticate to 192.168.68.20:5555')
        self.assertIn('Allow debugging', reason)

    def test_timeout_and_empty(self):
        for output in ('', 'cannot connect to 192.168.68.20:5555: A connection attempt failed (10060)',
                       'failed to connect to 192.168.68.20:5555', 'Operation timed out'):
            reason = logic.connect_failure_reason('192.168.68.20:5555', output)
            self.assertTrue(reason.startswith('No device answered at 192.168.68.20:5555.'), output)

    def test_other_output_is_returned(self):
        self.assertEqual(logic.connect_failure_reason('1.2.3.4:5555', 'something odd'), 'something odd')


class DisplayVersionTest(unittest.TestCase):
    def test_tags(self):
        self.assertEqual(logic.display_version('qa-v5.0.1-11-gabc1234'), '5.0.1.11')
        self.assertEqual(logic.display_version('qa-v5.0.1-11-gabc1234-dirty'), '5.0.1.11')
        self.assertEqual(logic.display_version('v5.0.1'), '5.0.1.0')
        self.assertEqual(logic.display_version('qa-v5.0.1'), '5.0.1.0')
        self.assertEqual(logic.display_version('5.0'), '5.0.0')
        self.assertEqual(logic.display_version('qa-abc1234'), 'abc1234')
        self.assertEqual(logic.display_version(''), '')

    def test_parse_version(self):
        self.assertEqual(logic.parse_version('5.0.1.11'), (5, 0, 1, 11))
        self.assertEqual(logic.parse_version('5.0'), (5, 0))
        self.assertIsNone(logic.parse_version('5'))
        self.assertIsNone(logic.parse_version('1.2.3.4.5'))
        self.assertIsNone(logic.parse_version('abc1234'))
        self.assertIsNone(logic.parse_version('5.0.99999999999'))
        self.assertIsNone(logic.parse_version(None))

    def test_newer_version(self):
        self.assertTrue(logic.is_newer_version('qa-v5.0.1-12-gdef5678', 'qa-v5.0.1-11-gabc1234'))
        self.assertTrue(logic.is_newer_version('qa-v5.0.2', 'qa-v5.0.1-11-gabc1234'))
        self.assertTrue(logic.is_newer_version('qa-v5.0.1-11-gabc1234', 'qa-v5.0.1-2-gabc1234'))
        self.assertFalse(logic.is_newer_version('qa-v5.0.1-10-gdef5678', 'qa-v5.0.1-11-gabc1234'))
        self.assertFalse(logic.is_newer_version('qa-v5.0.1-11-gdef5678', 'qa-v5.0.1-11-gabc1234-dirty'))
        self.assertFalse(logic.is_newer_version('qa-v5.0.1', 'qa-v5.0.1-0-gabc1234'))
        self.assertTrue(logic.is_newer_version('qa-v5.0.1-12-gdef5678', 'qa-abc1234'))
        self.assertTrue(logic.is_newer_version('qa-def5678', 'qa-v5.0.1-11-gabc1234'))


class FreePortBlockTest(unittest.TestCase):
    def test_first_free(self):
        self.assertEqual(logic.free_port_block([]), 27200)
        self.assertEqual(logic.free_port_block([27200, 27204]), 27208)
        self.assertEqual(logic.free_port_block([27200, 27208]), 27204)

    def test_custom_base(self):
        self.assertEqual(logic.free_port_block([], base=28200), 28200)
        self.assertEqual(logic.free_port_block([28200], base=28200), 28204)

    def test_exhausted_wraps_to_base(self):
        used = list(range(28200, 28200 + 16, 4))
        self.assertEqual(logic.free_port_block(used, base=28200, span=16), 28200)

    def test_port_arg(self):
        self.assertTrue(logic.has_port_arg(['--port=27183']))
        self.assertTrue(logic.has_port_arg(['-p', '27183']))
        self.assertFalse(logic.has_port_arg(['--max-size=1024']))


class UsbPriorityTest(unittest.TestCase):
    WIFI = '192.168.68.103:5555'
    USB = '810-880-708'

    def run_priority(self, devices, sessions, moved_usb=None, serial_filter=()):
        return logic.usb_priority(devices, sessions, {self.WIFI: self.USB}, moved_usb or {}, NOW, serial_filter)

    def test_both_online_wifi_standby(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        standby, handovers = self.run_priority(devices, {self.USB: session(), self.WIFI: session()})
        self.assertEqual(standby, {self.WIFI: self.USB})
        self.assertEqual(handovers, [])

    def test_serial_filter_disables(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        self.assertEqual(self.run_priority(devices, {}, serial_filter=[self.WIFI]), ({}, []))

    def test_no_usb_device(self):
        self.assertEqual(logic.usb_priority({self.WIFI: 'device'}, {}, {}, {}, NOW), ({}, []))

    def test_wifi_recording_keeps_wifi(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        sessions = {self.USB: session(), self.WIFI: session(recording=True)}
        standby, _ = self.run_priority(devices, sessions)
        self.assertEqual(standby, {self.USB: self.WIFI})

    def test_wifi_recording_usb_closed_no_standby(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        sessions = {self.USB: session(user_closed=True), self.WIFI: session(recording=True)}
        self.assertEqual(self.run_priority(devices, sessions), ({}, []))

    def test_usb_missing_less_than_30s_keeps_usb(self):
        devices = {self.WIFI: 'device'}
        sessions = {self.USB: session(missing_since=NOW - timedelta(seconds=10)), self.WIFI: session()}
        standby, _ = self.run_priority(devices, sessions)
        self.assertEqual(standby, {self.WIFI: self.USB})

    def test_usb_missing_30s_falls_back_to_wifi(self):
        devices = {self.WIFI: 'device'}
        sessions = {self.USB: session(missing_since=NOW - timedelta(seconds=31)), self.WIFI: session()}
        standby, _ = self.run_priority(devices, sessions)
        self.assertEqual(standby, {self.USB: self.WIFI})

    def test_usb_recording_missing_keeps_usb(self):
        devices = {self.WIFI: 'device'}
        sessions = {self.USB: session(recording=True, missing_since=NOW - timedelta(seconds=60)),
                    self.WIFI: session()}
        standby, _ = self.run_priority(devices, sessions)
        self.assertEqual(standby, {self.WIFI: self.USB})

    def test_wifi_recording_missing_30s_hands_over_to_usb(self):
        devices = {self.USB: 'device'}
        sessions = {self.USB: session(),
                    self.WIFI: session(recording=True, missing_since=NOW - timedelta(seconds=30))}
        standby, handovers = self.run_priority(devices, sessions)
        self.assertEqual(handovers, [(self.WIFI, self.USB)])
        self.assertEqual(standby, {self.WIFI: self.USB})

    def test_wifi_recording_missing_short_no_handover(self):
        devices = {self.USB: 'device'}
        sessions = {self.USB: session(),
                    self.WIFI: session(recording=True, missing_since=NOW - timedelta(seconds=5))}
        standby, handovers = self.run_priority(devices, sessions)
        self.assertEqual(handovers, [])
        self.assertEqual(standby, {self.USB: self.WIFI})

    def test_moving_or_moved_skipped(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        self.assertEqual(self.run_priority(devices, {self.WIFI: session(moved_to='USB')}), ({}, []))
        self.assertEqual(self.run_priority(devices, {self.WIFI: session(user_closed=True)}), ({}, []))
        self.assertEqual(self.run_priority(devices, {}, moved_usb={self.USB: self.WIFI}), ({}, []))

    def test_usb_offline_without_session_skipped(self):
        devices = {self.USB: 'offline', self.WIFI: 'device'}
        self.assertEqual(self.run_priority(devices, {self.WIFI: session()}), ({}, []))

    def test_skipped_address(self):
        devices = {self.USB: 'device', self.WIFI: 'device'}
        sessions = {self.USB: session(), self.WIFI: session()}
        self.assertEqual(logic.usb_priority(devices, sessions, {self.WIFI: self.USB}, {}, NOW, skip={self.WIFI}),
                         ({}, []))


class MovedAwayTest(unittest.TestCase):
    WIFI = '192.168.68.103:5555'
    USB = '810-880-708'

    def test_not_moved(self):
        self.assertEqual(logic.moved_away(self.USB, {}, {}, {}, NOW), (False, False))

    def test_wifi_session_active(self):
        sessions = {self.WIFI: session()}
        devices = {self.USB: 'device', self.WIFI: 'device'}
        self.assertEqual(logic.moved_away(self.USB, devices, {self.USB: self.WIFI}, sessions, NOW), (True, False))

    def test_wifi_lost_for_30s_returns_to_usb(self):
        sessions = {self.WIFI: session(missing_since=NOW - timedelta(seconds=30))}
        devices = {self.USB: 'device'}
        self.assertEqual(logic.moved_away(self.USB, devices, {self.USB: self.WIFI}, sessions, NOW), (False, True))

    def test_wifi_lost_shortly_stays_away(self):
        sessions = {self.WIFI: session(missing_since=NOW - timedelta(seconds=5))}
        devices = {self.USB: 'device'}
        self.assertEqual(logic.moved_away(self.USB, devices, {self.USB: self.WIFI}, sessions, NOW), (True, False))

    def test_wifi_disconnected_forgets(self):
        sessions = {self.WIFI: session(disconnected=True)}
        self.assertEqual(logic.moved_away(self.USB, {self.USB: 'device'}, {self.USB: self.WIFI}, sessions, NOW),
                         (False, True))

    def test_no_session_but_wifi_online(self):
        self.assertEqual(logic.moved_away(self.USB, {self.WIFI: 'device'}, {self.USB: self.WIFI}, {}, NOW),
                         (True, False))
        self.assertEqual(logic.moved_away(self.USB, {}, {self.USB: self.WIFI}, {}, NOW), (False, True))


class UpdateTest(unittest.TestCase):
    BUILT = datetime(2026, 10, 1, tzinfo=timezone.utc)

    def release(self, tag='qa-v5.0.1-12-gdef5678', published='2026-10-05T10:00:00Z', assets=None):
        if assets is None:
            assets = [f'scrcpy-monitor-portable-{tag}.zip', f'scrcpy-monitor-macos-arm64-{tag}.zip',
                      f'scrcpy-monitor-macos-x86_64-{tag}.zip', f'scrcpy-monitor-linux-x86_64-{tag}.tar.gz']
        return {'tag_name': tag, 'published_at': published, 'html_url': f'https://github.com/x/y/releases/{tag}',
                'body': 'notes', 'assets': [{'name': n, 'browser_download_url': f'https://dl/{n}'} for n in assets]}

    def test_asset_names(self):
        self.assertEqual(logic.update_asset_name('darwin', 'arm64', 't'), 'scrcpy-monitor-macos-arm64-t.zip')
        self.assertEqual(logic.update_asset_name('darwin', 'x86_64', 't'), 'scrcpy-monitor-macos-x86_64-t.zip')
        self.assertEqual(logic.update_asset_name('linux', 'x86_64', 't'), 'scrcpy-monitor-linux-x86_64-t.tar.gz')
        self.assertEqual(logic.update_asset_name('linux', 'AMD64', 't'), 'scrcpy-monitor-linux-x86_64-t.tar.gz')
        self.assertIsNone(logic.update_asset_name('windows', 'AMD64', 't'))

    def test_mac_update_found(self):
        update = logic.find_update(self.release(), 'qa-v5.0.1-11-gabc1234', self.BUILT, 'darwin', 'arm64')
        self.assertEqual(update['url'], 'https://dl/scrcpy-monitor-macos-arm64-qa-v5.0.1-12-gdef5678.zip')
        self.assertEqual(update['tag'], 'qa-v5.0.1-12-gdef5678')

    def test_linux_update_found(self):
        update = logic.find_update(self.release(), 'qa-v5.0.1-11-gabc1234', self.BUILT, 'linux', 'x86_64')
        self.assertTrue(update['url'].endswith('scrcpy-monitor-linux-x86_64-qa-v5.0.1-12-gdef5678.tar.gz'))

    def test_same_tag(self):
        release = self.release(tag='qa-v5.0.1-11-gabc1234')
        self.assertIsNone(logic.find_update(release, 'qa-v5.0.1-11-gabc1234', self.BUILT, 'darwin', 'arm64'))

    def test_older_version(self):
        release = self.release(tag='qa-v5.0.1-10-gdef5678')
        self.assertIsNone(logic.find_update(release, 'qa-v5.0.1-11-gabc1234', self.BUILT, 'darwin', 'arm64'))
        release = self.release(tag='qa-v5.0.1-11-gdef5678')
        self.assertIsNone(logic.find_update(release, 'qa-v5.0.1-11-gabc1234', self.BUILT, 'linux', 'x86_64'))

    def test_missing_asset(self):
        release = self.release(assets=['scrcpy-monitor-portable-x.zip'])
        self.assertIsNone(logic.find_update(release, 'qa-v5.0.1-11-gabc1234', self.BUILT, 'darwin', 'arm64'))

    def test_older_release(self):
        release = self.release(published='2026-09-01T00:00:00Z')
        self.assertIsNone(logic.find_update(release, 'qa-v5.0.1-11-gabc1234', self.BUILT, 'linux', 'x86_64'))

    def test_windows_reports_only(self):
        update = logic.find_update(self.release(), 'qa-v5.0.1-11-gabc1234', self.BUILT, 'windows', 'AMD64')
        self.assertIsNone(update['url'])
        self.assertTrue(update['page'].startswith('https://github.com/'))

    def test_no_release(self):
        self.assertIsNone(logic.find_update(None, 'v', None, 'darwin', 'arm64'))
        self.assertIsNone(logic.find_update({}, 'v', None, 'darwin', 'arm64'))

    def test_parse_iso(self):
        self.assertEqual(logic.parse_iso_datetime('2026-10-01T00:00:00Z'), self.BUILT)
        self.assertEqual(logic.parse_iso_datetime('2026-10-01T02:00:00.1234567+02:00'),
                         self.BUILT + timedelta(microseconds=123456))
        self.assertIsNone(logic.parse_iso_datetime('garbage'))
        self.assertIsNone(logic.parse_iso_datetime(None))


class MiscLogicTest(unittest.TestCase):
    def test_scan_ports(self):
        self.assertEqual(logic.scan_ports([5038], ['192.168.68.104:5037', '192.168.68.113:5555', '10.0.0.2:4444']),
                         [5555, 5037, 5038, 4444])

    def test_wifi_address(self):
        output = ('1: lo: <LOOPBACK,UP>\n    inet 127.0.0.1/8 scope host lo\n'
                  '20: rmnet_data0: <UP>\n    inet 10.1.2.3/30 scope global rmnet_data0\n'
                  '30: wlan0: <BROADCAST,UP>\n    inet 192.168.68.103/22 brd 192.168.71.255 scope global wlan0\n')
        self.assertEqual(logic.parse_wifi_address(output), '192.168.68.103')
        self.assertIsNone(logic.parse_wifi_address('1: lo: <LOOPBACK>\n    inet 127.0.0.1/8 scope host lo\n'))

    def test_probe_hosts(self):
        self.assertEqual(len(logic.probe_hosts('192.168.68.10', 22)), 1022)
        self.assertEqual(len(logic.probe_hosts('10.0.0.5', 8)), 254)

    def test_connected_output(self):
        self.assertTrue(logic.is_connected_output('connected to 192.168.68.103:5555'))
        self.assertTrue(logic.is_connected_output('already connected to 192.168.68.103:5555'))
        self.assertFalse(logic.is_connected_output('failed to connect to 192.168.68.103:5555'))

    def test_format_elapsed(self):
        self.assertEqual(logic.format_elapsed(0), '00:00:00')
        self.assertEqual(logic.format_elapsed(3725), '01:02:05')

    def test_safe_name(self):
        self.assertEqual(logic.safe_name('192.168.68.103:5555'), '192.168.68.103_5555')

    def test_power_watch(self):
        self.assertEqual(logic.parse_power_watch('1/'), 'restarting')
        self.assertEqual(logic.parse_power_watch('1,reboot/\n'), 'restarting')
        self.assertEqual(logic.parse_power_watch('/reboot,userrequested'), 'restarting')
        self.assertEqual(logic.parse_power_watch('/Reboot'), 'restarting')
        self.assertEqual(logic.parse_power_watch('0userrequested/'), 'off')
        self.assertEqual(logic.parse_power_watch('/shutdown,userrequested'), 'off')
        self.assertIsNone(logic.parse_power_watch('/'))
        self.assertIsNone(logic.parse_power_watch(''))
        self.assertIsNone(logic.parse_power_watch(None))
        self.assertIsNone(logic.parse_power_watch('error: closed'))

    def test_sort_key(self):
        self.assertEqual(logic.sort_key(['Pixel', 'USB', 'Mirroring', ''], 0), ('pixel', ''))
        self.assertEqual(logic.sort_key(['Pixel', 'USB', 'Mirroring', ''], 1), ('usb', 'pixel'))
        rows = [['b', 'Wi-Fi'], ['A', 'USB'], ['c', 'usb']]
        self.assertEqual([r[0] for r in sorted(rows, key=lambda r: logic.sort_key(r, 0))], ['A', 'b', 'c'])
        self.assertEqual([r[0] for r in sorted(rows, key=lambda r: logic.sort_key(r, 1))], ['A', 'c', 'b'])


class CombineTest(unittest.TestCase):
    def test_format_seconds(self):
        self.assertEqual(logic.format_seconds(0), '0')
        self.assertEqual(logic.format_seconds(1.5), '1.5')
        self.assertEqual(logic.format_seconds(2.0001), '2')
        self.assertEqual(logic.format_seconds(30.048), '30.048')

    def test_layout_matches_arranged_windows(self):
        sizes = [(320, 480), (720, 1280), (720, 1440), (720, 1440)]
        canvas_w, canvas_h, header_h, tiles = logic.combine_layout(sizes, [480, 811, 812, 812], (0, 0, 1920, 1032))
        self.assertEqual((canvas_w, canvas_h, header_h), (2558, 1344, 44))
        self.assertEqual([y for _, y, _, _ in tiles[1:]], [56, 56, 56])
        self.assertEqual([x for x, _, _, _ in tiles], sorted(x for x, _, _, _ in tiles))
        small, large = tiles[0], tiles[1]
        self.assertAlmostEqual(small[1] - header_h + (small[3] + header_h) / 2,
                               large[1] - header_h + (large[3] + header_h) / 2, delta=2)
        self.assertAlmostEqual(small[3] / large[3], 480 / 811, delta=0.01)
        for x, y, w, h in tiles:
            self.assertEqual((x % 2, y % 2, w % 2, h % 2), (0, 0, 0, 0))
            self.assertLessEqual(x + w, canvas_w)
            self.assertLessEqual(y + h, canvas_h)

    def test_layout_without_window_sizes(self):
        canvas_w, canvas_h, _, tiles = logic.combine_layout([(720, 1280)] * 2, [0, 0], None)
        self.assertEqual((canvas_w, canvas_h), (1472, 1340))
        self.assertEqual([t[2:] for t in tiles], [(720, 1280), (720, 1280)])

    def test_layout_limits_size_and_uses_rows(self):
        canvas_w, canvas_h, _, tiles = logic.combine_layout([(1080, 2400)] * 9, None, None)
        self.assertLessEqual(canvas_w, 2560)
        self.assertLessEqual(canvas_h, 1440)
        self.assertEqual(len({y for _, y, _, _ in tiles}), 2)

    def test_layout_rounding_stays_within_limit(self):
        canvas_w, canvas_h, _, tiles = logic.combine_layout(
            [(758, 990), (2208, 2200), (1200, 1920)], [0, 836, 365], (0, 0, 2560, 1400))
        self.assertEqual((canvas_w, canvas_h), (2552, 1438))
        for x, y, w, h in tiles:
            self.assertLessEqual(x + w, canvas_w)
            self.assertLessEqual(y + h, canvas_h)

    def test_chain_centers_device_in_tile(self):
        self.assertEqual(logic.combine_chain(640, 1280),
                         "scale=w='max(2,trunc(iw*min(640/iw,1280/ih)/2)*2)':"
                         "h='max(2,trunc(ih*min(640/iw,1280/ih)/2)*2)':eval=frame,"
                         'pad=640:1280:(ow-iw)/2:(oh-ih)/2:eval=frame,setsar=1')

    def test_header_height(self):
        self.assertEqual(logic.combine_header_height(1080), 54)
        self.assertEqual(logic.combine_header_height(1028), 50)
        self.assertEqual(logic.combine_header_height(684), 34)
        self.assertEqual(logic.combine_header_height(300), 16)

    def members(self):
        t0 = NOW
        return [
            [{'path': 'a.mp4', 'position': 0.0, 'duration': 6.0, 'start': t0 + timedelta(seconds=0.5)}],
            [{'path': 'c.mp4', 'position': 0.0, 'duration': 2.0, 'start': t0},
             {'path': 'c.mp4', 'position': 2.0, 'duration': 1.5, 'start': t0 + timedelta(seconds=4)}],
        ]

    LAYOUT = (1500, 900, 40, [(10, 50, 480, 840), (500, 300, 990, 556)])

    def test_command(self):
        args, total, count = logic.combine_command(self.members(), self.LAYOUT, NOW, ['-c:v', 'mpeg4'], 'out.mp4')
        self.assertEqual((total, count), (6.5, 3))
        self.assertEqual(args[-1], 'out.mp4')
        self.assertEqual(args[-3:-1], ['-t', '6.5'])
        self.assertEqual(args.count('-reinit_filter'), 3)
        graph = args[args.index('-filter_complex') + 1]
        self.assertTrue(graph.startswith('color=c=0x505050:s=1500x900:r=30:d=6.5[b0];'))
        self.assertIn("[0:v]setpts=PTS-STARTPTS+0.5/TB,scale=w='max(2,trunc(iw*min(480/iw,840/ih)/2)*2)'", graph)
        self.assertIn("[2:v]setpts=PTS-STARTPTS+4/TB,scale=w='max(2,trunc(iw*min(990/iw,556/ih)/2)*2)'", graph)
        self.assertIn('[b0][v0]overlay=x=10:y=50:eof_action=pass[b1]', graph)
        self.assertIn('[b2][v2]overlay=x=500:y=300:eof_action=pass[b3]', graph)
        self.assertEqual(args[args.index('-map') + 1], '[b3]')
        second = args.index('-i', args.index('-i') + 1)
        self.assertEqual(args[second - 4:second + 2], ['-ss', '0', '-t', '2', '-i', 'c.mp4'])

    def test_command_with_headers(self):
        args, _, count = logic.combine_command(self.members(), self.LAYOUT, NOW, ['-c:v', 'mpeg4'], 'out.mp4',
                                               ['h1.png', 'h2.png'])
        self.assertEqual(count, 3)
        graph = args[args.index('-filter_complex') + 1]
        self.assertTrue(graph.startswith('color=c=0x505050:s=1500x900:r=30:d=6.5[h0];[h0][3:v]overlay=x=10:y=10[h1];'
                                         '[h1][4:v]overlay=x=500:y=260[b0];[0:v]'))
        self.assertEqual(args[args.index('-map') + 1], '[b3]')
        inputs = args[:args.index('-filter_complex')]
        self.assertEqual(inputs[-4:], ['-i', 'h1.png', '-i', 'h2.png'])
        self.assertEqual(inputs.count('-i'), 5)

    def test_encoder_choice(self):
        self.assertEqual(logic.combine_encoder_args(' V....D libx264   H.264 ')[1], 'libx264')
        self.assertEqual(logic.combine_encoder_args(' V....D libopenh264 OpenH264 ')[1], 'libopenh264')
        self.assertEqual(logic.combine_encoder_args('')[1], 'mpeg4')


class LabelTest(unittest.TestCase):
    def test_fps_args_follow_ffmpeg_version(self):
        time_base = ['-enc_time_base', '1:60000']
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version 3.4.11 Copyright'), ['-vsync', 'passthrough'])
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version 4.4.2-0ubuntu0.22.04.1 Copyright'),
                         ['-vsync', 'passthrough'] + time_base)
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version n5.0.1 Copyright'),
                         ['-vsync', 'passthrough'] + time_base)
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version 5.1.2 Copyright'),
                         ['-fps_mode', 'passthrough'] + time_base)
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version 9.0.2 Copyright'),
                         ['-fps_mode', 'passthrough'] + time_base)
        self.assertEqual(logic.fps_passthrough_args('ffmpeg version N-112233-gabc Copyright'),
                         ['-fps_mode', 'passthrough'] + time_base)
        self.assertEqual(logic.fps_passthrough_args(''), ['-fps_mode', 'passthrough'] + time_base)

    def test_layout_is_even_and_scales_header(self):
        self.assertEqual(logic.label_layout(720, 1280), (720, 1280, 64))
        self.assertEqual(logic.label_layout(1081, 2401), (1082, 2402, 120))
        self.assertEqual(logic.label_layout(8, 8), (16, 16, 16))

    def test_command_stacks_header_and_keeps_audio(self):
        args = logic.label_command('in.mp4', 'h.png', 720, 1280, 64, ['-c:v', 'libx264'], ['-fps_mode', 'passthrough'],
                                   'out.mp4')
        graph = args[args.index('-filter_complex') + 1]
        self.assertIn('pad=720:1344:(ow-iw)/2:64+(1280-ih)/2:eval=frame', graph)
        self.assertIn('[v][1:v]overlay=x=0:y=0[out]', graph)
        self.assertEqual(args[args.index('-reinit_filter') + 1], '0')
        self.assertIn('0:a?', args)
        self.assertEqual(args[args.index('-c:a') + 1], 'copy')
        self.assertEqual(args[args.index('-bf') + 1], '0')
        self.assertEqual(args[-1], 'out.mp4')
        self.assertLess(args.index('in.mp4'), args.index('h.png'))


class WindowLayoutTest(unittest.TestCase):
    AREA = (1920, 0, 1920, 1032)

    @staticmethod
    def item(width, height, frame_height=32):
        return {'aspect': width / height, 'frame_width': 0, 'frame_height': frame_height, 'max_height': height}

    def check(self, area, items, rects):
        left, top, width, height = area
        self.assertEqual(len(rects), len(items))
        for index, (x, y, w, h) in enumerate(rects):
            self.assertGreaterEqual(x, left)
            self.assertGreaterEqual(y, top)
            self.assertLessEqual(x + w, left + width)
            self.assertLessEqual(y + h, top + height)
            for other in rects[index + 1:]:
                ox, oy, ow, oh = other
                self.assertTrue(x + w <= ox or ox + ow <= x or y + h <= oy or oy + oh <= y)

    def test_single_device_is_centered_at_natural_size(self):
        rects = logic.window_layout(self.AREA, [self.item(320, 480)])
        self.assertEqual(rects, [(1920 + 800, 260, 320, 512)])

    def test_large_devices_scale_down_to_fit(self):
        items = [self.item(320, 480), self.item(720, 1280), self.item(720, 1440)]
        rects = logic.window_layout(self.AREA, items)
        self.check(self.AREA, items, rects)
        self.assertEqual(rects[0][2:], (320, 512))
        self.assertLess(rects[1][3], 1280)
        left_margin = rects[0][0] - 1920
        right_margin = 1920 + 1920 - (rects[2][0] + rects[2][2])
        self.assertLessEqual(abs(left_margin - right_margin), 1)
        self.assertEqual(rects[1][0] - (rects[0][0] + rects[0][2]), 8)

    def test_many_devices_use_rows(self):
        for count in (2, 3, 5, 8, 12):
            items = [self.item(720, 1280)] * count
            rects = logic.window_layout(self.AREA, items)
            self.check(self.AREA, items, rects)
        rects = logic.window_layout(self.AREA, [self.item(720, 1280)] * 12)
        self.assertGreater(len({y for _, y, _, _ in rects}), 1)

    def test_landscape_and_small_screen(self):
        items = [self.item(1280, 720), self.item(1280, 720)]
        self.check(self.AREA, items, logic.window_layout(self.AREA, items))
        small = (0, 0, 800, 600)
        items = [self.item(720, 1280)] * 3
        self.check(small, items, logic.window_layout(small, items))
        self.assertIsNone(logic.window_layout((0, 0, 100, 100), items))
        self.assertIsNone(logic.window_layout(self.AREA, []))

    def test_arguments(self):
        self.assertTrue(logic.has_placement_arg(['--window-x=10']))
        self.assertTrue(logic.has_placement_arg(['-f']))
        self.assertTrue(logic.has_placement_arg(['--fullscreen']))
        self.assertFalse(logic.has_placement_arg(['--window-title=x', '-m1024', '--force-adb-forward']))


class ScreenRecordTest(unittest.TestCase):
    def test_area_from_setting(self):
        virtual, primary = (0, 0, 3840, 1080), (0, 0, 1920, 1080)
        self.assertEqual(logic.screen_area_from_setting('100,50,640,480', virtual, primary), (100, 50, 640, 480))
        self.assertEqual(logic.screen_area_from_setting('3800,0,640,480', virtual, primary), (320, 180, 1280, 720))
        self.assertEqual(logic.screen_area_from_setting('bad', virtual, (0, 0, 1024, 768)), (40, 80, 944, 608))
        self.assertIsNone(logic.normalize_screen_area((0, 0, 10, 100)))
        self.assertEqual(logic.normalize_screen_area((5, 6, 101.0, 77)), (5, 6, 100, 76))

    def test_follow(self):
        self.assertEqual(logic.parse_follow_size('854x480'), (854, 480))
        self.assertEqual(logic.parse_follow_size('10x10'), (1280, 720))
        bounds = (0, 0, 1920, 1080)
        self.assertEqual(logic.follow_area((10, 10), bounds, (1280, 720)), (0, 0, 1280, 720))
        self.assertEqual(logic.follow_area((1900, 1070), bounds, (1280, 720)), (640, 360, 1280, 720))
        self.assertEqual(logic.follow_area((960, 540), (0, 0, 800, 600), (1280, 720)), (0, 0, 800, 600))

    def test_capture_command_rect(self):
        args, follow = logic.screen_capture_command('x11grab', [('', (0, 0, 1920, 1080))], (100, 200, 641, 480),
                                                    None, ['-c:v', 'libx264'], 'out.mkv', ':1')
        self.assertIsNone(follow)
        self.assertIn(':1+100,200', args)
        self.assertEqual(args[args.index('-video_size') + 1], '640x480')
        self.assertEqual(args[args.index('-filter_complex') + 1], '[0:v]null,format=yuv420p[v]')
        self.assertEqual(args[-1], 'out.mkv')

    def test_capture_command_follow_and_shot(self):
        sources = [('', (-1920, 0, 1920, 1080)), ('', (0, 0, 1920, 1080))]
        args, follow = logic.screen_capture_command('gdigrab', sources, (-100, 10, 1280, 720), True, [], 'o.mkv')
        self.assertEqual(follow, {'box': (-1920, 0, 3840, 1080), 'width': 1280, 'height': 720, 'x': 1820, 'y': 10})
        self.assertIn('crop=w=1280:h=720:x=1820:y=10:exact=1', args[args.index('-filter_complex') + 1])
        args, follow = logic.screen_capture_command('gdigrab', sources, (0, 0, 100, 100), None, [], 's.png', shot=True)
        self.assertIsNone(follow)
        self.assertIn('-frames:v', args)

    def test_capture_command_avfoundation(self):
        sources = [('1', (0, 0, 2880, 1800)), ('2', (2880, 0, 1920, 1080))]
        args, _ = logic.screen_capture_command('avfoundation', sources, (0, 0, 4800, 1800), None, [], 'o.mkv')
        graph = args[args.index('-filter_complex') + 1]
        self.assertIn('xstack=inputs=2:layout=0_0|2880_0', graph)
        self.assertIn('1:none', args)
        self.assertNotIn('crop', graph)

    def test_merge_steps(self):
        steps, lines = logic.screen_merge_steps(["a'b.mkv", 'c.mkv'], [(640, 480)] * 2, 'l.txt', 'o.mp4', [])
        self.assertEqual(lines, ["file 'a'\\''b.mkv'", "file 'c.mkv'"])
        self.assertIn('copy', steps[0])
        steps, lines = logic.screen_merge_steps(['a', 'b'], [(640, 480), (1280, 720)], 'l.txt', 'o.mp4', ['-c:v', 'x'])
        self.assertIsNone(lines)
        self.assertIn('concat=n=2:v=1:a=0[v]', steps[0][steps[0].index('-filter_complex') + 1])

    def test_avfoundation_and_base(self):
        text = '[AVFoundation indev @ 0x1] [3] Capture screen 0\n[AVFoundation indev @ 0x1] [4] Capture screen 1'
        self.assertEqual(logic.parse_avfoundation_screens(text), {0: 3, 1: 4})
        moment = datetime(2026, 1, 2, 3, 4, 5)
        taken = {os.path.join('d', 'Screen_Capture_20260102_030405.mp4')}
        self.assertEqual(logic.screen_capture_base('d', moment, taken.__contains__),
                         os.path.join('d', 'Screen_Capture_20260102_030405_2'))
        self.assertEqual(logic.format_bytes(3 << 20), '3.0 MB')


class DiskSpaceTest(unittest.TestCase):
    def test_disk_level(self):
        self.assertEqual(logic.disk_level(-1), 'unknown')
        self.assertEqual(logic.disk_level(logic.DISK_CRITICAL - 1), 'critical')
        self.assertEqual(logic.disk_level(logic.DISK_CRITICAL), 'low')
        self.assertEqual(logic.disk_level(logic.DISK_LOW - 1), 'low')
        self.assertEqual(logic.disk_level(logic.DISK_LOW), 'ok')

    def test_missing_folder_uses_existing_parent(self):
        with tempfile.TemporaryDirectory() as root:
            missing = os.path.join(root, 'a', 'b')
            self.assertEqual(logic.existing_folder(missing), os.path.abspath(root))
            self.assertGreaterEqual(logic.disk_free(missing), 0)


class DeviceLogTest(unittest.TestCase):
    def test_parse_header(self):
        header = logic.parse_logcat_header('[ 10-09 11:22:33.4567  1234: 5678 I/ActivityManager ]', NOW)
        self.assertEqual(header, (datetime(2026, 10, 9, 11, 22, 33, 456000), 1234, 5678, 'I', 'ActivityManager'))
        header = logic.parse_logcat_header('[ 12-31 23:59:59.1 u0_a12:  42:   43 E/my tag  ]', NOW)
        self.assertEqual(header, (datetime(2025, 12, 31, 23, 59, 59, 100000), 42, 43, 'E', 'my tag'))
        self.assertEqual(logic.parse_logcat_header('[ 02-30 01:00:00.000  1:  1 D/x ]', NOW)[0], NOW)
        self.assertIsNone(logic.parse_logcat_header('--------- beginning of main', NOW))

    def test_prefix_and_marker(self):
        prefix = logic.logcat_prefix(datetime(2026, 1, 2, 3, 4, 5, 6000), 12, 34, 'Tag', 'com.app', 'W')
        self.assertEqual(prefix, '2026-01-02 03:04:05.006     12-34     Tag' + ' ' * 22 + 'com.app'
                         + ' ' * 30 + 'W  ')
        self.assertEqual(logic.log_marker('LOGGING STARTED: x', NOW),
                         '-' * 28 + ' LOGGING STARTED: x (2026-10-09 12:00:00) ' + '-' * 28)

    def test_process_names_and_boot_id(self):
        text = ('PID NAME\n1 init\n500 system_server\n600 zygote64\n700 com.example.app\n'
                '800 <pre-initialized>\n')
        self.assertEqual(logic.parse_process_names(text), {1: 'init', 500: 'system_process', 700: 'com.example.app'})
        legacy = 'USER PID PPID VSIZE RSS WCHAN PC NAME\nroot 1 0 100 10 0 0 S /init\n'
        self.assertEqual(logic.parse_process_names(legacy), {1: '/init'})
        self.assertEqual(logic.boot_id(' 0123abcd-4567-89ef-0123-456789abcdef\n'),
                         '0123abcd-4567-89ef-0123-456789abcdef')
        self.assertEqual(logic.boot_id('cat: permission denied'), '')

    def test_device_log_path(self):
        taken = {os.path.join('L', 'logs_T650_450_20261009_120000.txt')}
        self.assertEqual(logic.device_log_path('L', 'T650', '450', NOW, taken.__contains__),
                         os.path.join('L', 'logs_T650_450_20261009_120000_2.txt'))

    def test_capture_formats_entries(self):
        from scrcpy_monitor.logcat import LogcatCapture
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'd', 'log.txt')
            capture = LogcatCapture('adb', 'serial', path, 'label', apps={'com.app'})
            capture._pids_at = float('inf')
            capture._pids = {10: 'com.app'}
            capture._marker('LOGGING STARTED: label')
            year = datetime.now().year
            for line in ['--------- beginning of main', '[ 01-02 03:04:05.006    10:   11 I/Tag ]', 'first',
                         'second', '', '--------- beginning of system', '[ 01-02 03:04:05.007    99:   99 D/T ]',
                         '', '']:
                capture._handle_line(line)
            capture._end_entry()
            capture.stop()
            with open(path, encoding='utf-8') as handle:
                lines = handle.read().splitlines()
            with open(os.path.join(root, 'd', 'com.app', 'log.txt'), encoding='utf-8') as handle:
                app_lines = handle.read().splitlines()
            self.assertEqual(sorted(os.listdir(os.path.join(root, 'd'))), ['com.app', 'log.txt'])
        prefix = logic.logcat_prefix(datetime(year, 1, 2, 3, 4, 5, 6000), 10, 11, 'Tag', 'com.app', 'I')
        self.assertEqual(lines[1:4], [prefix + 'first', ' ' * len(prefix) + 'second',
                                      logic.logcat_prefix(datetime(year, 1, 2, 3, 4, 5, 7000), 99, 99, 'T', '',
                                                          'D').rstrip()])
        self.assertIn('LOGGING STARTED: label', lines[0])
        self.assertIn('LOGGING STOPPED', lines[-1])
        self.assertEqual(capture.entries, 2)
        self.assertIn('LOGGING STARTED: label', app_lines[0])
        self.assertEqual(app_lines[1:3], [prefix + 'first', ' ' * len(prefix) + 'second'])
        self.assertIn('LOGGING STOPPED', app_lines[3])
        self.assertEqual(len(app_lines), 4)

    def test_capture_writes_only_chosen_apps(self):
        from scrcpy_monitor.logcat import LogcatCapture
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'd', 'log.txt')
            capture = LogcatCapture('adb', 'serial', path, 'label')
            capture._pids_at = float('inf')
            capture._pids = {10: 'com.app', 11: 'com.other:remote'}
            for line in ['[ 01-02 03:04:05.006    10:   10 I/Tag ]', 'one', '']:
                capture._handle_line(line)
            capture._end_entry()
            capture.set_apps({'com.other'})
            for line in ['[ 01-02 03:04:06.006    10:   10 I/Tag ]', 'two', '',
                         '[ 01-02 03:04:07.006    11:   11 I/Tag ]', 'three', '']:
                capture._handle_line(line)
            capture._end_entry()
            capture.stop()
            names = sorted(os.listdir(os.path.join(root, 'd')))
            with open(os.path.join(root, 'd', 'com.other', 'log.txt'), encoding='utf-8') as handle:
                other = handle.read()
        self.assertEqual(names, ['com.other', 'log.txt'])
        self.assertIn('three', other)
        self.assertNotIn('two', other)

    def test_capture_reopens_evicted_app_files(self):
        from unittest import mock
        from scrcpy_monitor import logcat
        with tempfile.TemporaryDirectory() as root, mock.patch.object(logcat, 'APP_FILES_OPEN', 1):
            path = os.path.join(root, 'd', 'log.txt')
            capture = logcat.LogcatCapture('adb', 'serial', path, 'label')
            capture._marker('LOGGING STARTED: label')
            capture._write('a1', 'com.a')
            capture._write('b1', 'com.b')
            capture._marker('DEVICE RESTARTED')
            capture._write('a2', 'com.a')
            self.assertEqual(len(capture._app_files), 1)
            capture.stop()
            files = {}
            for app in ('com.a', 'com.b'):
                with open(os.path.join(root, 'd', app, 'log.txt'), encoding='utf-8') as handle:
                    files[app] = handle.read().splitlines()
        self.assertEqual(files['com.a'][1:2] + files['com.a'][3:4], ['a1', 'a2'])
        self.assertEqual(files['com.b'][1], 'b1')
        for lines in files.values():
            self.assertIn('LOGGING STARTED: label', lines[0])
            self.assertIn('DEVICE RESTARTED', lines[2])
            self.assertIn('LOGGING STOPPED', lines[-1])
            self.assertEqual(sum('LOGGING STARTED' in line for line in lines), 1)

    def test_capture_notes_versions(self):
        from scrcpy_monitor.logcat import LogcatCapture
        pa, pia = logic.PA_PACKAGE, logic.PIA_PACKAGE
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'd', 'log.txt')
            capture = LogcatCapture('adb', 'serial', path, 'label')
            capture.note_versions(None, True)
            capture.note_versions({pa: '1', pia: ''}, False)
            capture.note_versions({pa: '1', pia: ''}, False)
            capture.note_versions({pa: '1', pia: ''}, True)
            capture.note_versions({pa: '2', pia: '3'}, False)
            capture.stop()
            self.assertEqual(capture.size, os.path.getsize(path))
            with open(path, encoding='utf-8') as handle:
                lines = [line for line in handle.read().splitlines() if 'APP VERSIONS' in line]
        self.assertEqual(len(lines), 3)
        self.assertIn(f'APP VERSIONS: PA ({pa}) 1, PIA ({pia}) Not installed', lines[0])
        self.assertIn(f'APP VERSIONS: PA ({pa}) 2, PIA ({pia}) 3', lines[2])
        self.assertEqual(capture.size, 0)

    def test_capture_notes_app_events(self):
        from scrcpy_monitor.logcat import LogcatCapture
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'd', 'log.txt')
            capture = LogcatCapture('adb', 'serial', path, 'label')
            capture._pids_at = float('inf')
            capture._pids = {500: 'system_server'}
            capture.note_versions({logic.PA_PACKAGE: '1', logic.PIA_PACKAGE: '2'}, False)
            capture.note_versions(None, True)
            capture.note_versions({logic.PA_PACKAGE: '1', logic.PIA_PACKAGE: '2'}, False)
            events = [(500, 'ActivityManager', 'Start proc 300:com.global.wwca/u0a87 for top-activity {x}'),
                      (500, 'ActivityManager', 'Start proc 301:com.x/u0a88 for service {y}'),
                      (300, 'AndroidRuntime', 'FATAL EXCEPTION: main'),
                      (500, 'ActivityManager', 'Killing 300:com.global.wwca/u0a87 (adj 100): crash'),
                      (500, 'ActivityManager', 'Process com.global.wwca (pid 300) has died: fg TOP'),
                      (500, 'ActivityManager', 'Start proc 302:com.global.wwca:svc/u0a87 for service {z}')]
            for second, (pid, tag, message) in enumerate(events):
                for line in [f'[ 01-02 03:04:0{second}.006   {pid}:  {pid} I/{tag} ]', message, '']:
                    capture._handle_line(line)
            capture._end_entry()
            self.assertEqual(capture._pids[301], 'com.x')
            capture._status_time = datetime.max
            for line in ['[ 01-02 03:04:09.006   500:  500 E/ActivityManager ]', 'ANR in com.global.wwca', '']:
                capture._handle_line(line)
            capture._end_entry()
            capture.stop()
            with open(path, encoding='utf-8') as handle:
                lines = [line for line in handle.read().splitlines() if 'APP ' in line]
        pa = f'PA ({logic.PA_PACKAGE})'
        self.assertEqual(sum('APP VERSIONS' in line for line in lines), 2)
        found = [line.split('APP ', 1)[1].rsplit(' (', 1)[0] for line in lines if 'APP VERSIONS' not in line]
        self.assertEqual(found, [f'STARTED: {pa}, pid 300', f'CRASHED: {pa}, pid 300 - FATAL EXCEPTION: main',
                                 f'STOPPED: {pa}, pid 300 - crash'])

    def test_app_package(self):
        packages = logic.parse_packages('package:com.verifone.app\r\npackage:android\nerror\n')
        self.assertEqual(packages, {'com.verifone.app', 'android'})
        self.assertEqual(logic.app_package('com.verifone.app:remote', packages), 'com.verifone.app')
        self.assertEqual(logic.app_package('system_process', packages), 'system_process')
        self.assertIsNone(logic.app_package('android.hardware.audio.service', packages))
        self.assertIsNone(logic.app_package('', packages))
        self.assertEqual(logic.app_package('com.x.y', set()), 'com.x.y')
        self.assertIsNone(logic.app_package('/system/bin/vold', set()))
        self.assertIsNone(logic.app_package('logd', set()))
        self.assertEqual(logic.app_log_path(os.path.join('L', 'T650', 'logs.txt'), 'a/b:c'),
                         os.path.join('L', 'T650', 'a_b_c', 'logs.txt'))

    def test_log_apps(self):
        self.assertEqual(logic.log_app('com.a:remote', {'com.a'}), 'com.a')
        self.assertIsNone(logic.log_app('com.b', {'com.a'}))
        self.assertIsNone(logic.log_app('', set()))
        self.assertEqual(logic.parse_log_apps([' com.b', 'com.a', 'com.b', '']), ['com.a', 'com.b'])
        self.assertEqual(logic.parse_log_apps('com.a, com.b'), ['com.a', 'com.b'])
        self.assertEqual(logic.parse_log_apps(None), [])
        self.assertEqual(logic.parse_log_apps([]), [])
        self.assertEqual(logic.log_app_choices({'com.r', 'com.o', 'system_process'}, {'com.o'}, {'com.i', 'com.r'},
                                               {'com.c', 'com.r'}),
                         ['com.o', 'com.r', 'system_process', 'com.i', 'com.c'])
        self.assertEqual(logic.log_app_choices({'com.a', logic.PIA_PACKAGE}, {'com.z'}, {logic.PA_PACKAGE, 'com.b'},
                                               []),
                         [logic.PA_PACKAGE, logic.PIA_PACKAGE, 'com.z', 'com.a', 'com.b'])
        self.assertEqual(logic.app_tag(logic.PA_PACKAGE), ' (PA)')
        self.assertEqual(logic.app_tag(logic.PIA_PACKAGE), ' (PIA)')
        self.assertEqual(logic.app_tag('com.a'), '')
        ps = 'USER PID PPID NAME\nu0_a1 10 1 com.r:svc\nroot 11 1 /system/bin/vold\nsystem 12 1 system_server\n'
        self.assertEqual(logic.running_apps(ps, {'com.r'}), {'com.r', 'system_process'})
        self.assertEqual(logic.foreground_app(
            'mCurrentFocus=Window{ce68f25 u0 StatusBar}\n  mFocusedApp=AppWindowToken{c0308b1 token=Token{57efc3b '
            'ActivityRecord{9be52ca u0 com.global.integrated/com.x.Main t6171}}}'), 'com.global.integrated')
        self.assertEqual(logic.foreground_app('mCurrentFocus=Window{3a u0 com.a/com.a.Main}'), 'com.a')
        self.assertEqual(logic.foreground_app(
            'mFocusedApp=ActivityRecord{2227486 u0 com.g/com.g.Main} t158}'), 'com.g')
        self.assertIsNone(logic.foreground_app(''))

    def test_app_versions(self):
        pa, pia = logic.PA_PACKAGE, logic.PIA_PACKAGE
        text = (f'@{pa}\r\n    versionName=1.2.3\r\n    versionName=0.9\r\n@{pia}\r\n'
                f'    versionName=4.5-qa\r\n')
        versions = logic.parse_app_versions(text)
        self.assertEqual(versions, {pa: '1.2.3', pia: '4.5-qa'})
        self.assertEqual(logic.app_version_text(versions), f'PA ({pa}) 1.2.3, PIA ({pia}) 4.5-qa')
        missing = logic.parse_app_versions(f'@{pa}\n  versionName=1.2.3\n@{pia}\nUnable to find package: {pia}\n')
        self.assertEqual(missing, {pa: '1.2.3', pia: ''})
        self.assertEqual(logic.app_version_text(missing), f'PA ({pa}) 1.2.3, PIA ({pia}) Not installed')
        self.assertIsNone(logic.parse_app_versions(f'@{pa}\n@{pia}\n'))
        self.assertIsNone(logic.parse_app_versions(f'@{pa}\n  versionName=1.2.3\n@{pia}\n'))
        self.assertIn("grep -E 'versionName|Unable to find'", logic.VERSION_COMMAND)
        self.assertTrue(logic.VERSION_COMMAND.startswith('if [ "$(getprop sys.boot_completed)" = 1 ]; then for p in '
                                                         f'{pa} {pia}; do echo "@$p"; dumpsys package $p | '))
        self.assertIsNone(logic.parse_app_versions(''))
        self.assertIsNone(logic.parse_app_versions(f'@{pa}\nversionName=1\n'))
        self.assertIsNone(logic.app_version_text(None))
        self.assertTrue(logic.version_mismatch([versions, {pa: '1.2.4', pia: '4.5-qa'}], pa))
        self.assertFalse(logic.version_mismatch([versions, {pa: '1.2.4', pia: '4.5-qa'}], pia))
        self.assertFalse(logic.version_mismatch([versions, missing], pia))
        self.assertFalse(logic.version_mismatch([], pa))

    def test_app_status_and_events(self):
        self.assertEqual(logic.app_label(logic.PIA_PACKAGE), 'PIA (com.global.integrated)')
        self.assertEqual(logic.app_label('com.x'), 'com.x')
        self.assertEqual(logic.app_status_text({100: 'com.global.wwca', 200: 'com.x', 201: 'com.global.wwca:svc'},
                                               ['com.x', 'com.global.wwca', 'com.y']),
                         'PA (com.global.wwca) running (pid 100), PIA (com.global.integrated) not running, '
                         'com.x running (pid 200), com.y not running')
        self.assertEqual(logic.app_status_text({7: 'com.global.integrated', 3: 'com.global.integrated'}, []),
                         'PA (com.global.wwca) not running, PIA (com.global.integrated) running (pid 3, 7)')
        am = 'ActivityManager'
        self.assertEqual(logic.parse_app_event(am, 'Start proc 1234:com.global.wwca/u0a87 for top-activity {x}'),
                         ('APP STARTED', 'com.global.wwca', '1234', ''))
        self.assertEqual(logic.parse_app_event(am, 'Killing 3298:com.global.wwca/u0a87 (adj 100): stop '
                                                   'com.global.wwca due to from pid 2723'),
                         ('APP STOPPED', 'com.global.wwca', '3298', 'stop com.global.wwca due to from pid 2723'))
        self.assertEqual(logic.parse_app_event(am, 'Killing 8872:com.global.wwca/u0a691 (adj 200): stop '
                                                   'com.global.wwca'),
                         ('APP STOPPED', 'com.global.wwca', '8872', 'stop com.global.wwca'))
        self.assertEqual(logic.parse_app_event(am, 'Killing 55:com.a:remote/u0a9: empty #17'),
                         ('APP STOPPED', 'com.a:remote', '55', 'empty #17'))
        self.assertEqual(logic.parse_app_event(am, 'Process com.a (pid 9) has died: fg TOP'),
                         ('APP STOPPED', 'com.a', '9', 'process died'))
        self.assertEqual(logic.parse_app_event(am, 'ANR in com.a (com.a/.Main)'),
                         ('APP NOT RESPONDING', 'com.a', '', ''))
        self.assertEqual(logic.parse_app_event('AndroidRuntime', 'FATAL EXCEPTION: main '),
                         ('APP CRASHED', '', '', 'FATAL EXCEPTION: main'))
        self.assertEqual(logic.parse_app_event('libc', 'Fatal signal 11 (SIGSEGV)'),
                         ('APP CRASHED', '', '', 'Fatal signal 11 (SIGSEGV)'))
        self.assertIsNone(logic.parse_app_event(am, 'Force stopping com.global.wwca appid=10087 user=0: from pid 1'))
        self.assertIsNone(logic.parse_app_event('Tag', 'Start proc 1:com.a/u0a1 for x'))
        self.assertIsNone(logic.parse_app_event('AndroidRuntime', 'Shutting down VM'))
        now = datetime(2026, 1, 5, 10, 0, 0)
        self.assertEqual(logic.parse_device_time('12-31 23:59:58\r\n', now), datetime(2025, 12, 31, 23, 59, 58))
        self.assertEqual(logic.parse_device_time('01-05 09:59:58', now), datetime(2026, 1, 5, 9, 59, 58))
        self.assertIsNone(logic.parse_device_time('error: closed', now))


class MacHotKeysTest(unittest.TestCase):
    def test_handler_passes_on_hotkeys_it_does_not_own(self):
        from scrcpy_monitor import screenrec

        def carbon(ident):
            def get_parameter(event, name, kind, actual, size, used, out):
                out._obj.signature = screenrec._fourcc('scrm')
                out._obj.id = ident
                return 0
            return SimpleNamespace(GetEventParameter=get_parameter)

        emitted = []
        menu = screenrec.MacHotKeys(emitted.append, ((4, 46, 0x1800, 'menu'),))
        recorder = screenrec.MacHotKeys(emitted.append)
        menu.carbon = recorder.carbon = carbon(4)
        self.assertEqual(recorder._handle(None, None, None), -9874)
        self.assertEqual(menu._handle(None, None, None), 0)
        recorder.carbon = carbon(3)
        self.assertEqual(recorder._handle(None, None, None), 0)
        self.assertEqual(emitted, ['menu', 'shot'])


class SessionEndTest(unittest.TestCase):
    def stop(self, session_ending):
        import threading
        from scrcpy_monitor.engine import Engine
        calls = []
        engine = Engine.__new__(Engine)
        engine.exiting = False
        engine.session_ending = session_ending
        engine.sessions = {}
        engine.finished = threading.Event()
        engine.tools = SimpleNamespace(ffprobe='ffprobe')
        engine.publish = lambda: None
        for name in ('stop_adb_jobs', 'stop_all_device_logs', 'stop_combines', 'stop_labels'):
            setattr(engine, name, lambda name=name: calls.append(name))
        for name in ('update_stops', 'update_merges', 'update_combines', 'update_combine_handovers'):
            setattr(engine, name, lambda value, name=name: calls.append((name, value)))
        engine.update_labels = lambda value, force: calls.append(('update_labels', value))
        engine.stop_monitor()
        self.assertTrue(engine.finished.is_set())
        return engine, calls

    def test_session_end_saves_without_long_waits(self):
        engine, calls = self.stop(True)
        self.assertEqual(calls, ['stop_adb_jobs', 'stop_all_device_logs', ('update_stops', 20),
                                 ('update_combine_handovers', True), ('update_merges', 30), 'stop_combines',
                                 'stop_labels'])
        with tempfile.NamedTemporaryFile(delete=False) as video:
            video.write(b'x' * 2048)
        try:
            self.assertTrue(engine.test_video_file(video.name))
        finally:
            os.unlink(video.name)

    def test_normal_exit_keeps_full_waits(self):
        _, calls = self.stop(False)
        self.assertIn(('update_merges', 600), calls)
        self.assertIn(('update_combines', 120), calls)
        self.assertIn(('update_labels', 120), calls)

    def test_system_quit_routes_by_quit_reason(self):
        from unittest import mock
        from scrcpy_monitor import ui
        calls = []

        def quit(mac, logout, **flags):
            state = dict(finishing=False, session_ended=False, request_exit=lambda: calls.append('exit'),
                         end_session=lambda: calls.append('end'))
            state.update(flags)
            with mock.patch.object(ui, 'IS_MAC', mac), mock.patch.object(ui, 'mac_session_ending', return_value=logout):
                result = ui.Controller.system_quit(SimpleNamespace(**state), lambda: calls.append('cancel'))
            handled = list(calls)
            calls.clear()
            return result, handled

        self.assertEqual(quit(True, False), (True, ['cancel', 'exit']))
        self.assertEqual(quit(True, True), (True, ['end']))
        self.assertEqual(quit(False, False), (True, ['end']))
        self.assertEqual(quit(True, False, finishing=True), (False, []))
        self.assertEqual(quit(False, True, session_ended=True), (False, []))


if __name__ == '__main__':
    unittest.main()
