import os
import sys
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


if __name__ == '__main__':
    unittest.main()
