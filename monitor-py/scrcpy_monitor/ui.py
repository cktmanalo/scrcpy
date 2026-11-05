import collections
import re
import traceback
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, QUrl
from PySide6.QtGui import QAction, QBrush, QColor, QDesktopServices, QFont, QIcon, QPalette
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QComboBox, QDialog, QFileDialog, QHBoxLayout,
                               QHeaderView, QLabel, QLineEdit, QMenu, QMessageBox, QPushButton, QStatusBar,
                               QStyle, QSystemTrayIcon, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

from . import logic, updater
from .system import IS_MAC, log, open_path, write_json

TITLE = 'Scrcpy Monitor'
AUTHOR = 'Charles Manalo'
FIREBRICK = QColor(178, 34, 34)
MESSAGE_ICONS = {'info': QMessageBox.Icon.Information, 'warning': QMessageBox.Icon.Warning,
                 'error': QMessageBox.Icon.Critical, 'question': QMessageBox.Icon.Question}
TRAY_ICONS = {'info': QSystemTrayIcon.MessageIcon.Information, 'warning': QSystemTrayIcon.MessageIcon.Warning,
              'error': QSystemTrayIcon.MessageIcon.Critical}


def safely(function):
    def wrapper(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except Exception:
            log('ERROR: ' + traceback.format_exc())
    return wrapper


class ConnectDialog(QDialog):
    def __init__(self, parent, address, port, ports):
        super().__init__(parent)
        self.setWindowTitle('Connect Wi-Fi device')
        self.setWindowFlag(Qt.WindowType.WindowContextHelpButtonHint, False)
        if parent is None:
            self.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint, True)
        layout = QVBoxLayout(self)
        label = QLabel('ADB over Wi-Fi must be enabled on the device (for example adb tcpip 5555).\n\nIP address:')
        label.setWordWrap(True)
        layout.addWidget(label)
        self.address = QLineEdit(address)
        self.address.setMinimumWidth(340)
        layout.addWidget(self.address)
        layout.addWidget(QLabel('Port:'))
        self.port = QComboBox()
        self.port.setEditable(True)
        self.port.addItems([str(p) for p in ports])
        self.port.setCurrentText(port)
        self.port.setFixedWidth(120)
        layout.addWidget(self.port)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        connect = QPushButton('Connect')
        connect.setDefault(True)
        connect.clicked.connect(self.accept)
        cancel = QPushButton('Cancel')
        cancel.clicked.connect(self.reject)
        buttons.addWidget(connect)
        buttons.addWidget(cancel)
        layout.addLayout(buttons)
        self.setFixedSize(self.sizeHint())


class AboutDialog(QDialog):
    def __init__(self, version, engine_text, repo):
        super().__init__(None)
        self.setWindowTitle('About Scrcpy Monitor')
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.setWindowFlag(Qt.WindowType.WindowContextHelpButtonHint, False)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 16)
        title = QLabel('Scrcpy Monitor')
        font = title.font()
        font.setPointSize(14)
        font.setBold(True)
        title.setFont(font)
        layout.addWidget(title)
        shortcut = 'Cmd+E' if IS_MAC else 'Alt+E'
        details = QLabel(
            f'Version: {version}\nMirroring engine: {engine_text}\nAuthor: {AUTHOR}\n\n'
            'Mirrors one or more Android devices in separate windows and keeps each window open while its device '
            'restarts or reconnects.\n\n'
            '- Detects devices connected over USB or Wi-Fi and shows the connection type of each.\n'
            '- Scan now finds devices on the local Wi-Fi network (ports 5555, 5037 and any port you connected with) '
            'and connects them automatically.\n'
            '- Connect a Wi-Fi device by IP address and port, disconnect it or reconnect it later; Wi-Fi devices are '
            'remembered.\n'
            '- A device connected over both USB and Wi-Fi is mirrored over USB; the Wi-Fi connection is kept on '
            'standby.\n'
            '- Switch a device between USB and Wi-Fi; the old entry is removed, and if the switch fails the previous '
            'connection is restored.\n'
            f'- Record per device or all devices from the window button ({shortcut}), this panel or the tray icon; '
            'recordings continue across restarts and are saved as one MP4 per device.\n'
            '- Record combined also joins the recordings of the selected devices into one side-by-side video.\n'
            '- Checks for updates; the packaged version updates itself.\n\n'
            'Built on scrcpy by Genymobile (Apache License 2.0).')
        details.setWordWrap(True)
        details.setFixedWidth(480)
        layout.addWidget(details)
        link = QLabel(f'<a href="https://github.com/{repo}">https://github.com/{repo}</a>')
        link.setOpenExternalLinks(True)
        layout.addWidget(link)
        row = QHBoxLayout()
        row.addStretch(1)
        ok = QPushButton('OK')
        ok.setDefault(True)
        ok.clicked.connect(self.close)
        row.addWidget(ok)
        layout.addLayout(row)
        self.setFixedSize(self.sizeHint())


class Panel(QWidget):
    def __init__(self, controller, title):
        super().__init__()
        self.controller = controller
        self.items = {}
        self.setWindowTitle(title)
        self.resize(720, 380)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        self.list = QTreeWidget()
        self.list.setColumnCount(4)
        self.list.setHeaderLabels(['Device', 'Connection', 'Status', 'Recording'])
        for column, width in enumerate((250, 85, 170, 165)):
            self.list.setColumnWidth(column, width)
        self.list.header().setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        self.list.setRootIsDecorated(False)
        self.list.setUniformRowHeights(True)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.list.setSortingEnabled(True)
        self.list.sortByColumn(0, Qt.SortOrder.AscendingOrder)
        self.list.itemSelectionChanged.connect(safely(self.update_buttons))
        self.list.itemDoubleClicked.connect(safely(lambda *_: self.toggle.isEnabled() and self.toggle.click()))
        layout.addWidget(self.list, 1)

        devices = QHBoxLayout()
        devices.setContentsMargins(6, 6, 6, 2)
        self.toggle = self._button(devices, 'Start recording', controller.panel_toggle)
        self.combine = self._button(devices, 'Record combined', controller.panel_combine)
        self.open = self._button(devices, 'Open window', lambda: controller.open_window(self.selected_serials()))
        self.disconnect = self._button(devices, 'Disconnect', lambda: controller.disconnect(self.selected_serials()))
        self.switch = self._button(devices, 'Switch to USB', lambda: controller.switch(self.selected_serials()))
        self._button(devices, 'Connect Wi-Fi device...', controller.show_connect_dialog)
        self.scan = self._button(devices, 'Scan now', controller.scan_now)
        devices.addStretch(1)
        layout.addLayout(devices)

        buttons = QHBoxLayout()
        buttons.setContentsMargins(6, 2, 6, 6)
        self.start_all = self._button(buttons, 'Start all', controller.start_all)
        self.stop_all = self._button(buttons, 'Stop all', controller.stop_all)
        self._button(buttons, 'Open recordings folder', controller.open_record_folder)
        self._button(buttons, 'Change folder...', controller.select_record_folder)
        self._button(buttons, 'Open log', controller.open_log)
        if controller.version.enabled:
            self._button(buttons, 'Check for updates', lambda: controller.start_update_check(True))
        self._button(buttons, 'About', controller.show_about)
        self._button(buttons, 'Exit', controller.request_exit)
        buttons.addStretch(1)
        layout.addLayout(buttons)

        self.status_bar = QStatusBar()
        self.status_bar.setSizeGripEnabled(False)
        self.status = QLabel()
        self.scan_label = QLabel()
        self.status_bar.addWidget(self.status, 1)
        self.status_bar.addPermanentWidget(self.scan_label)
        layout.addWidget(self.status_bar)
        self.setMinimumSize(max(560, buttons.sizeHint().width()), 260)

    def _button(self, layout, text, action):
        button = QPushButton(text)

        def clicked():
            action()
            self.controller.refresh_soon()

        button.clicked.connect(safely(clicked))
        layout.addWidget(button)
        return button

    def selected_serials(self):
        return [item.data(0, Qt.ItemDataRole.UserRole) for item in self.list.selectedItems()]

    def selected_views(self):
        views = {view.serial: view for view in self.controller.snapshot().sessions}
        return [views[s] for s in self.selected_serials() if s in views]

    def closeEvent(self, event):
        self.controller.panel_closing(event)

    def update_view(self):
        if not self.isVisible():
            return
        snapshot = self.controller.snapshot()
        palette = self.palette()
        gray = QBrush(palette.color(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text))
        normal = QBrush(palette.color(QPalette.ColorRole.Text))
        seen = set()
        sorting = self.list.isSortingEnabled()
        self.list.setSortingEnabled(False)
        for view in snapshot.sessions:
            seen.add(view.serial)
            item = self.items.get(view.serial)
            if item is None:
                item = QTreeWidgetItem(['', '', '', ''])
                item.setData(0, Qt.ItemDataRole.UserRole, view.serial)
                self.list.addTopLevelItem(item)
                self.items[view.serial] = item
            for column, text in enumerate((view.title, view.connection, view.status, view.recording_text)):
                if item.text(column) != text:
                    item.setText(column, text)
            brush = FIREBRICK if view.recording else (gray if view.user_closed or view.standby else normal)
            brush = QBrush(brush) if isinstance(brush, QColor) else brush
            if item.foreground(0) != brush:
                for column in range(4):
                    item.setForeground(column, brush)
        for serial in [s for s in self.items if s not in seen]:
            item = self.items.pop(serial)
            self.list.takeTopLevelItem(self.list.indexOfTopLevelItem(item))
        self.list.setSortingEnabled(sorting)
        status = self.controller.status_text(snapshot)
        if self.status.text() != status:
            self.status.setText(status)
        scan = 'Wi-Fi scan: off' if snapshot.discovery_off else snapshot.discovery_status
        if self.scan_label.text() != scan:
            self.scan_label.setText(scan)
        self.update_buttons()

    def update_buttons(self):
        snapshot = self.controller.snapshot()
        selected = self.selected_views()
        standby = [v for v in selected if v.standby]
        active = [v for v in selected if not v.standby]
        opened = [v for v in active if not v.user_closed]
        to_start = [v for v in opened if not v.recording]
        self.toggle.setText('Start recording' if to_start or not opened else 'Stop recording')
        self.toggle.setEnabled(bool(opened))
        self.combine.setEnabled(len(opened) >= 2 and not any(v.recording or v.stopping for v in opened))
        closed = [v for v in selected if v.user_closed]
        open_text = 'Reconnect' if closed and not [v for v in closed if not v.disconnected] else 'Open window'
        if self.open.text() != open_text:
            self.open.setText(open_text)
        self.open.setEnabled(bool(closed))
        self.disconnect.setEnabled(any(v.connection == 'Wi-Fi' and not v.disconnected for v in selected))
        kinds = list(dict.fromkeys(v.connection for v in selected))
        switch_text = 'Switch to Wi-Fi' if kinds == ['USB'] else 'Switch to USB'
        if self.switch.text() != switch_text:
            self.switch.setText(switch_text)
        self.switch.setEnabled(not standby and len(kinds) == 1 and kinds[0] in ('Wi-Fi', 'USB')
                               and any(not v.disconnected and v.last_state == 'device' for v in selected))
        self.scan.setEnabled(snapshot.scan_enabled and not snapshot.exiting)
        targets = [v for v in snapshot.sessions if not v.user_closed and not v.standby]
        self.start_all.setEnabled(any(not v.recording for v in targets))
        self.stop_all.setEnabled(any(v.recording for v in targets))


class Controller(QObject):
    def __init__(self, app, engine, paths, version, options):
        super().__init__()
        self.app = app
        self.engine = engine
        self.paths = paths
        self.version = version
        self.options = options
        self.prompting = False
        self.pending_events = collections.deque()
        self.exit_requested = False
        self.exit_posted = False
        self.panel_hidden_once = False
        self.update_status = ''
        self.update_worker = None
        self.update_manual = False
        self.available_update = None
        self.update_job = None
        self.updating = False
        self.about = None
        self.fast_ticks = 0
        self.tray_available = QSystemTrayIcon.isSystemTrayAvailable()
        self.icon = self._load_icon(options.icon_path)
        app.setWindowIcon(self.icon)
        self.panel = None
        if not options.no_panel:
            title = f'{TITLE} {version.display}' if version.enabled else TITLE
            self.panel = Panel(self, title)
            self.panel.setWindowIcon(self.icon)
        self.tray = None
        self.tray_menu = None
        if not options.no_tray and self.tray_available:
            self.tray = QSystemTrayIcon(self.icon)
            self.tray_menu = QMenu()
            self.tray_menu.aboutToShow.connect(safely(self.update_tray_menu))
            self.tray.setContextMenu(self.tray_menu)
            self.tray.activated.connect(safely(self.tray_activated))
            self.tray.setToolTip(TITLE)
            self.update_tray_menu()
            self.tray.show()
        elif not options.no_tray:
            log('The system tray is not available; the control panel stays open instead.')
        self.no_tray_fallback = not options.no_tray and self.tray is None
        engine.has_panel = self.panel is not None
        engine.panel_pending = self.panel is not None and not self.no_tray_fallback
        self.timer = QTimer(self)
        self.timer.setInterval(int(options.poll_seconds * 1000))
        self.timer.timeout.connect(safely(engine.post_tick))
        self.fast_timer = QTimer(self)
        self.fast_timer.setInterval(300)
        self.fast_timer.timeout.connect(safely(self.fast_tick))

    def _load_icon(self, path):
        if path and Path(path).is_file():
            icon = QIcon(str(path))
            if not icon.isNull():
                return icon
        return self.app.style().standardIcon(QStyle.StandardPixmap.SP_ComputerIcon)

    def start(self):
        self.timer.start()
        self.fast_timer.start()
        QTimer.singleShot(100, safely(self.engine.post_tick))
        if self.no_tray_fallback and self.panel:
            self.show_panel()
        if not self.options.no_update_check:
            self.start_update_check(False)

    def snapshot(self):
        return self.engine.snapshot

    def owner(self):
        return self.panel if self.panel and self.panel.isVisible() and not self.panel.isMinimized() else None

    def show_message(self, text, buttons=QMessageBox.StandardButton.Ok, icon='info'):
        owner = self.owner()
        box = QMessageBox(MESSAGE_ICONS.get(icon, QMessageBox.Icon.Information), TITLE, text, buttons, owner)
        if owner is None:
            box.setWindowFlag(Qt.WindowType.WindowStaysOnTopHint, True)
        self.prompting = True
        try:
            box.activateWindow()
            return box.exec()
        finally:
            self.prompting = False

    def notify(self, message, icon='info'):
        if self.tray and self.tray.supportsMessages():
            self.tray.showMessage(TITLE, message, TRAY_ICONS.get(icon, QSystemTrayIcon.MessageIcon.Information), 4000)

    def refresh_soon(self):
        QTimer.singleShot(150, safely(self.refresh))

    def refresh(self):
        if self.panel:
            self.panel.update_view()
        self.update_tray_text()

    def post(self, function, *args):
        self.engine.post(lambda: function(*args))
        self.refresh_soon()

    def fast_tick(self):
        if self.engine.finished.is_set():
            self.finish()
            return
        self.engine.panel_visible = bool(self.panel and self.panel.isVisible())
        if self.exit_requested and not self.exit_posted:
            self.exit_posted = True
            self.engine.post('exit')
        if not self.exit_posted:
            self.engine.post_fast()
            self.complete_update_check()
            self.complete_update_job()
        self.process_events()
        self.fast_ticks += 1
        if self.fast_ticks % 3 == 0:
            self.refresh()

    def process_events(self):
        while True:
            try:
                self.pending_events.append(self.engine.ui_events.get_nowait())
            except Exception:
                break
        while self.pending_events and not self.prompting:
            event = self.pending_events[0]
            kind = event[0]
            if kind in ('message', 'confirm', 'connect_failure') and (self.exit_posted or self.app.activeModalWidget()):
                if self.exit_posted:
                    self.pending_events.popleft()
                    continue
                break
            self.pending_events.popleft()
            if kind == 'notify':
                self.notify(event[1], event[2])
            elif kind == 'show_panel':
                self.show_panel()
            elif kind == 'message':
                self.show_message(event[1], icon=event[2])
            elif kind == 'confirm':
                answer = self.show_message(event[1], QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                           'question')
                if answer == QMessageBox.StandardButton.Yes:
                    self.post(event[2])
            elif kind == 'connect_failure':
                self.show_connect_failure(event[1], event[2])

    def show_connect_failure(self, address, output):
        reason = logic.connect_failure_reason(address, output)
        answer = self.show_message(f'Could not connect to {address}.\n\n{reason}\n\nTry again?',
                                   QMessageBox.StandardButton.Retry | QMessageBox.StandardButton.Cancel, 'warning')
        if answer == QMessageBox.StandardButton.Retry:
            host, _, port = address.rpartition(':')
            self.show_connect_dialog(host, port)

    def finish(self):
        self.timer.stop()
        self.fast_timer.stop()
        if self.tray:
            self.tray.hide()
        for widget in QApplication.topLevelWidgets():
            if isinstance(widget, QDialog) and widget.isVisible():
                widget.reject()
        if self.panel:
            self.panel.hide()
        self.app.quit()

    def request_exit(self):
        if self.exit_requested:
            return
        self.exit_requested = True
        if self.panel and self.panel.isVisible():
            self.panel.status.setText('Stopping: finishing recordings and closing windows...')
            self.panel.setCursor(Qt.CursorShape.WaitCursor)
        QTimer.singleShot(0, safely(self.fast_tick))

    def panel_closing(self, event):
        if self.engine.exiting or self.exit_requested:
            event.accept()
            return
        event.ignore()
        if self.tray:
            self.panel.hide()
            if not self.panel_hidden_once:
                self.panel_hidden_once = True
                where = 'menu bar' if IS_MAC else 'tray'
                action = 'Click' if IS_MAC else 'Double-click'
                self.engine.notify(f'scrcpy monitor keeps running in the {where}. {action} the {where} icon to show '
                                   f'the control panel.')
        elif self.no_tray_fallback:
            self.panel.showMinimized()
        else:
            self.request_exit()

    def show_panel(self):
        self.engine.panel_pending = False
        if not self.panel:
            return
        if self.panel.isMinimized():
            self.panel.showNormal()
        self.panel.show()
        self.panel.raise_()
        self.panel.activateWindow()
        self.engine.panel_visible = True
        self.panel.update_view()

    def tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            if self.panel:
                self.show_panel()
            else:
                self.open_record_folder()

    def update_tray_text(self):
        if not self.tray:
            return
        recording = sum(1 for v in self.snapshot().sessions if v.recording)
        text = f'{TITLE} - recording {recording} device(s)' if recording else TITLE
        self.tray.setToolTip(text[:63])

    def _action(self, menu, text, function, enabled=True, bold=False):
        action = QAction(text, menu)
        action.setEnabled(enabled)
        if bold:
            font = QFont(action.font())
            font.setBold(True)
            action.setFont(font)
        action.triggered.connect(safely(lambda *_: function()))
        menu.addAction(action)
        return action

    def update_tray_menu(self):
        menu = self.tray_menu
        menu.clear()
        snapshot = self.snapshot()
        if self.panel:
            self._action(menu, 'Show control panel', self.show_panel, bold=True)
            menu.addSeparator()
        views = sorted(snapshot.sessions, key=lambda v: v.title.lower())
        sessions = [v for v in views if not v.user_closed]
        closed = [v for v in views if v.user_closed]
        if not sessions and not closed:
            self._action(menu, 'No device', lambda: None, enabled=False)
        for view in sessions:
            label = f'{view.title} - {view.connection}'
            serial = view.serial
            if view.standby:
                sub = menu.addMenu(label + '  [standby]')
                if view.connection == 'Wi-Fi':
                    self._action(sub, 'Disconnect', lambda s=serial: self.disconnect([s]))
                else:
                    sub.setEnabled(False)
                continue
            if view.recording:
                label += '  [REC]'
            sub = menu.addMenu(label)
            self._action(sub, 'Stop recording' if view.recording else 'Start recording',
                         lambda s=serial: self.post(self.engine.toggle_recording, [s]))
            if view.connection in ('Wi-Fi', 'USB'):
                self._action(sub, 'Switch to USB' if view.connection == 'Wi-Fi' else 'Switch to Wi-Fi',
                             lambda s=serial: self.switch([s]), enabled=view.last_state == 'device')
            if view.connection == 'Wi-Fi':
                self._action(sub, 'Disconnect', lambda s=serial: self.disconnect([s]))
        for view in closed:
            state = (f'switching to {view.moved_to}' if view.moved_to else
                     'disconnected' if view.disconnected else 'closed')
            sub = menu.addMenu(f'{view.title} - {view.connection}  [{state}]')
            self._action(sub, 'Reconnect' if view.disconnected else 'Open window',
                         lambda s=view.serial: self.open_window([s]))
        menu.addSeparator()
        targets = [v for v in sessions if not v.standby]
        self._action(menu, 'Start recording on all devices', self.start_all,
                     enabled=any(not v.recording for v in targets))
        self._action(menu, 'Stop recording on all devices', self.stop_all, enabled=any(v.recording for v in sessions))
        self._action(menu, 'Connect Wi-Fi device...', self.show_connect_dialog)
        menu.addSeparator()
        self._action(menu, 'Open recordings folder', self.open_record_folder)
        self._action(menu, 'Change recordings folder...', self.select_record_folder)
        self._action(menu, 'Open log', self.open_log)
        if self.version.enabled:
            self._action(menu, 'Check for updates', lambda: self.start_update_check(True))
        self._action(menu, 'About', self.show_about)
        menu.addSeparator()
        self._action(menu, 'Exit', self.request_exit)

    def status_text(self, snapshot):
        if snapshot.exiting or self.exit_requested:
            return 'Stopping: finishing recordings and closing windows...'
        status = f'Recordings: {snapshot.record_dir}'
        if snapshot.connecting:
            status = f'Connecting to {", ".join(snapshot.connecting)}...  {status}'
        if snapshot.merges:
            status = f'Joining {snapshot.merges} recording(s)...  {status}'
        if snapshot.combines:
            status = f'Combining {snapshot.combines} recording(s)...  {status}'
        if self.update_status:
            status = f'{self.update_status}  |  {status}'
        return status

    def panel_toggle(self):
        selected = [v for v in self.panel.selected_views() if not v.user_closed]
        if selected:
            self.post(self.engine.toggle_recording, [v.serial for v in selected])

    def panel_combine(self):
        selected = [v for v in self.panel.selected_views() if not v.user_closed and not v.standby]
        if len(selected) >= 2:
            self.post(self.engine.start_combined_recording, [v.serial for v in selected])

    def open_window(self, serials):
        if serials:
            self.post(self.engine.open_window, list(serials))

    def disconnect(self, serials):
        if serials:
            self.post(self.engine.disconnect_device, list(serials))

    def switch(self, serials):
        if serials:
            self.post(self.engine.switch_connection, list(serials))

    def scan_now(self):
        self.post(self.engine.start_scan)

    def start_all(self):
        self.post(self.engine.start_all)

    def stop_all(self):
        self.post(self.engine.stop_all)

    def open_record_folder(self):
        folder = Path(self.snapshot().record_dir)
        folder.mkdir(parents=True, exist_ok=True)
        open_path(folder)

    def open_log(self):
        open_path(self.paths.log_file)

    def select_record_folder(self):
        current = self.snapshot().record_dir
        self.prompting = True
        try:
            folder = QFileDialog.getExistingDirectory(self.owner(), 'Choose the folder where recordings are saved',
                                                      current if Path(current).is_dir() else str(Path.home()))
        finally:
            self.prompting = False
        if not folder:
            return
        folder = str(Path(folder))
        write_json(self.paths.settings, {'RecordDir': folder})
        self.post(self.engine.set_record_dir, folder)

    def show_connect_dialog(self, address='', port='5555'):
        if self.prompting:
            return
        dialog = ConnectDialog(self.owner(), address, port, self.snapshot().scan_ports)
        dialog.setWindowIcon(self.icon)
        self.prompting = True
        try:
            dialog.activateWindow()
            result = dialog.exec()
            address = dialog.address.text().strip()
            port_text = dialog.port.currentText().strip()
        finally:
            self.prompting = False
            dialog.deleteLater()
        if result != QDialog.DialogCode.Accepted or not address:
            return
        match = re.match(r'^(.+):(\d{1,5})$', address)
        if match:
            address, port_text = match.group(1), match.group(2)
        if not re.match(r'^[A-Za-z0-9][A-Za-z0-9.-]*$', address):
            self.show_message(f"'{address}' is not a valid address. Enter an IP address such as 192.168.1.20.",
                              icon='warning')
            return
        if not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
            self.show_message(f"'{port_text}' is not a valid port. Enter a number from 1 to 65535, such as 5555.",
                              icon='warning')
            return
        self.post(self.engine.connect_wifi_device, f'{address}:{int(port_text)}')

    def show_about(self):
        if self.about is not None:
            self.about.showNormal()
            self.about.raise_()
            self.about.activateWindow()
            return
        version = self.version.display if self.version.enabled else 'development build'
        scrcpy = self.engine.scrcpy_version
        self.about = AboutDialog(version, f'scrcpy {scrcpy}' if scrcpy else 'scrcpy', self.version.repo)
        self.about.setWindowIcon(self.icon)
        self.about.destroyed.connect(lambda *_: setattr(self, 'about', None))
        self.about.show()
        self.about.raise_()
        self.about.activateWindow()

    def handle_request(self, command, serials):
        if command == 'start-recording':
            self.post(self.engine.start_all, serials)
        elif command == 'stop-recording':
            self.post(self.engine.stop_all, serials)
        elif command == 'show-panel':
            if self.panel:
                self.show_panel()
            else:
                self.engine.notify('scrcpy monitor is already running (see the tray icon).')
        elif command == 'open-windows':
            self.engine.post(lambda: setattr(self.engine, 'open_windows_requested', True))
            self.engine.post_tick()
        elif command == 'exit':
            self.request_exit()

    def start_update_check(self, manual):
        if not self.version.enabled or self.update_worker or self.updating:
            return
        self.update_worker = updater.Worker(updater.fetch_latest_release, self.version.repo)
        self.update_manual = manual
        if manual:
            self.update_status = 'Checking for updates...'

    def complete_update_check(self):
        worker = self.update_worker
        if not worker or not worker.done.is_set() or self.prompting or self.app.activeModalWidget():
            return
        self.update_worker = None
        self.update_status = ''
        manual = self.update_manual
        current = self.version.display
        if worker.error:
            message = str(worker.error)
            log(f'Update check failed: {message}')
            if manual:
                self.show_message(f'Could not check for updates:\n{message}', icon='warning')
            return
        update = updater.check_release(worker.result, self.version)
        if not update:
            log(f'Update check: {self.version.version} is up to date.')
            if manual:
                self.show_message(f'You have the latest version ({current}).')
            return
        tag = update['tag']
        log(f'Update available: {tag} (current: {self.version.version})')
        display = logic.display_version(tag)
        notes = update['notes']
        if len(notes) > 600:
            notes = notes[:600] + '...'
        text = f'scrcpy monitor {display} is available (you have {current}).'
        if notes:
            text += f'\n\n{notes}'
        yes_no = QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        if self.version.can_self_update and update['url']:
            recording = sum(1 for v in self.snapshot().sessions if v.recording)
            text += '\n\nUpdate now? The monitor restarts'
            text += f' and the {recording} recording(s) in progress are stopped and saved.' if recording else '.'
            if self.snapshot().combine_active:
                text += ' A combined recording that is not finished within 2 minutes is cancelled.'
            self.available_update = update
            if self.show_message(text, yes_no, 'question') == QMessageBox.StandardButton.Yes:
                self.start_update()
            else:
                self.update_status = f'Update {display} available'
            return
        self.update_status = f'Update {display} available'
        text += ('\n\nThis copy does not update itself. Download the new version from the release page.'
                 '\n\nOpen the release page?')
        if self.show_message(text, yes_no, 'question') == QMessageBox.StandardButton.Yes:
            page = update['page']
            if not page.startswith('https://github.com/'):
                page = f'https://github.com/{self.version.repo}/releases/latest'
            QDesktopServices.openUrl(QUrl(page))

    def start_update(self):
        update = self.available_update
        if self.updating or not update:
            return
        self.updating = True
        display = logic.display_version(update['tag'])
        self.update_status = f'Downloading update {display}... the monitor restarts when it is ready.'
        log(f'Updating to {update["tag"]}')
        self.update_job = updater.Worker(updater.prepare_update, update['url'], self.paths.update_dir)

    def complete_update_job(self):
        job = self.update_job
        if not job or not job.done.is_set():
            return
        self.update_job = None
        if job.error:
            log(f'Update failed: {job.error}')
            self.updating = False
            self.update_status = ''
            log('Update was not installed.')
            self.engine.message(f'Update failed: {job.error}')
            return
        try:
            updater.launch_update(job.result, self.paths.log_file)
        except OSError as error:
            self.updating = False
            self.update_status = ''
            self.engine.message(f'Update failed: {error}')
            return
        self.request_exit()
