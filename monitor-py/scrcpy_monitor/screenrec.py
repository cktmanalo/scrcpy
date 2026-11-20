import ctypes
import ctypes.util
import os
import select
import subprocess
import threading
import time
from collections import deque
from ctypes import POINTER, Structure, byref, c_int, c_long, c_uint, c_uint32, c_ulong, c_void_p
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QEventLoop, QObject, QPoint, QRect, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QFont, QFontMetrics, QGuiApplication, QPainter, QPen, QRegion
from PySide6.QtWidgets import QMenu, QToolTip, QWidget

from . import logic
from .system import IS_LINUX, IS_MAC, IS_WINDOWS, get_setting, hidden_kwargs, kill_process, log, open_path, \
    run_hidden, set_setting

RED = QColor(230, 30, 30)
BRIGHT_RED = QColor(255, 70, 70)
BLUE = QColor(30, 144, 255)
ORANGE = QColor(255, 165, 0)
BAR_BACK = QColor(38, 38, 42)
BAR_HOVER = QColor(70, 70, 78)
GREY = QColor(110, 110, 110)
LIGHT = QColor(220, 220, 220)
WHITE = QColor(255, 255, 255)
FOLLOW_SIZES = [f'{w}x{h}' for w, h in logic.SCREEN_FOLLOW_SIZES]
EDGE_CURSORS = {1: Qt.CursorShape.SizeHorCursor, 4: Qt.CursorShape.SizeHorCursor, 2: Qt.CursorShape.SizeVerCursor,
                8: Qt.CursorShape.SizeVerCursor, 3: Qt.CursorShape.SizeFDiagCursor,
                12: Qt.CursorShape.SizeFDiagCursor, 6: Qt.CursorShape.SizeBDiagCursor,
                9: Qt.CursorShape.SizeBDiagCursor}


def _flags(focus=False):
    flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool
    if not focus:
        flags |= Qt.WindowType.WindowDoesNotAcceptFocus
    return flags


def _prepare(widget):
    widget.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
    widget.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow, True)
    widget.setMouseTracking(True)


def _exclude_from_capture(widget):
    if IS_WINDOWS:
        try:
            ctypes.windll.user32.SetWindowDisplayAffinity(c_void_p(int(widget.winId())), 0x11)
        except Exception:
            pass


def _qrect(rect):
    return QRect(rect[0], rect[1], rect[2], rect[3])


def _tuple(rect):
    return (rect.x(), rect.y(), rect.width(), rect.height())


def _screen_for(rect):
    center = QPoint(rect[0] + rect[2] // 2, rect[1] + rect[3] // 2)
    return QGuiApplication.screenAt(center) or QGuiApplication.primaryScreen()


def _monitor(rect):
    screen = _screen_for(rect)
    return _tuple(screen.geometry()) if screen else rect


class Display:
    __slots__ = ('number', 'logical', 'capture', 'dpr', 'primary', 'device')

    def __init__(self, number, logical, capture, dpr, primary, device=''):
        self.number = number
        self.logical = logical
        self.capture = capture
        self.dpr = dpr
        self.primary = primary
        self.device = device


class Space:
    def __init__(self, devices=None):
        screens = QGuiApplication.screens()
        primary = QGuiApplication.primaryScreen()
        self.scale = max([s.devicePixelRatio() for s in screens] or [1]) if IS_MAC else 1
        self.displays = []
        for index, screen in enumerate(screens):
            logical = _tuple(screen.geometry())
            dpr = screen.devicePixelRatio()
            if IS_MAC:
                capture = tuple(round(value * self.scale) for value in logical)
            else:
                capture = (logical[0], logical[1], round(logical[2] * dpr), round(logical[3] * dpr))
            device = ''
            if devices is not None:
                device = devices.get(index, '')
            self.displays.append(Display(index + 1, logical, capture, dpr, screen is primary, device))
        self.displays.sort(key=lambda d: (not d.primary, d.logical[0], d.logical[1]))
        for number, display in enumerate(self.displays, 1):
            display.number = number

    def display_at(self, x, y, logical=True):
        for display in self.displays:
            rect = display.logical if logical else display.capture
            if rect[0] <= x < rect[0] + rect[2] and rect[1] <= y < rect[1] + rect[3]:
                return display
        return self.displays[0]

    def to_capture_point(self, x, y):
        if IS_MAC:
            return round(x * self.scale), round(y * self.scale)
        display = self.display_at(x, y)
        return (display.capture[0] + round((x - display.logical[0]) * display.dpr),
                display.capture[1] + round((y - display.logical[1]) * display.dpr))

    def to_capture(self, rect):
        x, y = self.to_capture_point(rect[0], rect[1])
        ratio = self.scale if IS_MAC else self.display_at(rect[0], rect[1]).dpr
        return (x, y, logic.even_size(rect[2] * ratio), logic.even_size(rect[3] * ratio))

    def from_native_window(self, rect):
        if IS_MAC:
            return tuple(round(value * self.scale) for value in rect)
        return rect

    def logical_monitor(self, capture_rect):
        display = self.display_at(capture_rect[0] + capture_rect[2] // 2, capture_rect[1] + capture_rect[3] // 2,
                                  logical=False)
        return display.logical

    def cursor(self):
        pos = QCursor.pos()
        return self.to_capture_point(pos.x(), pos.y())

    def virtual_logical(self):
        return logic.rect_union(d.logical for d in self.displays)

    def virtual_capture(self):
        return logic.rect_union(d.capture for d in self.displays)


class _Strip(QWidget):
    def __init__(self, frame, edge):
        super().__init__(None, _flags())
        _prepare(self)
        self.frame = frame
        self.edge = edge

    def edges_at(self, pos):
        if self.frame.recording:
            return 0
        corner = 18
        edges = self.edge
        if edges in (2, 8):
            if pos.x() < corner:
                edges |= 1
            elif pos.x() >= self.width() - corner:
                edges |= 4
        else:
            if pos.y() < corner:
                edges |= 2
            elif pos.y() >= self.height() - corner:
                edges |= 8
        return edges

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), self.frame.color())

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        edges = self.edges_at(event.position().toPoint())
        if edges:
            self.frame.begin_resize(edges, event.globalPosition().toPoint())

    def mouseMoveEvent(self, event):
        if self.frame.resize_edges:
            self.frame.resize_to(event.globalPosition().toPoint())
            return
        self.setCursor(EDGE_CURSORS.get(self.edges_at(event.position().toPoint()), Qt.CursorShape.ArrowCursor))

    def mouseReleaseEvent(self, event):
        if self.frame.resize_edges:
            self.frame.end_resize()


class _Toolbar(QWidget):
    HEIGHT = 34

    def __init__(self, frame):
        super().__init__(None, _flags())
        _prepare(self)
        self.frame = frame
        self.setWindowTitle('Scrcpy Monitor screen recorder')
        self.font_ = QFont(self.font())
        self.font_.setPixelSize(13)
        self.buttons = []
        self.hover = None
        self.pressed = None
        self.move_start = None

    def build(self):
        frame = self.frame
        buttons = []

        def add(ident, text, tip, enabled=True, color=WHITE, clickable=True):
            buttons.append({'id': ident, 'text': text, 'tip': tip, 'enabled': enabled, 'color': color,
                            'clickable': clickable, 'rect': QRect()})

        if frame.recording:
            add('rec', '\u25A0  Stop', 'Stop recording (F12)')
        else:
            add('rec', '\u25CF  REC', 'Start recording (F12)', color=BRIGHT_RED)
        add('pause', '\u25B6  Resume' if frame.paused else '\u275A\u275A  Pause',
            ('Resume' if frame.paused else 'Pause') + ' recording (Shift+F12)', frame.recording)
        add('shot', 'Screenshot', 'Take a screenshot (F11)')
        if frame.bar_only:
            add('mode', frame.mode_text, '', False, LIGHT, False)
        else:
            add('size', f'{frame.capture[2]} \u00D7 {frame.capture[3]}  \u25BE', 'Choose the recording size',
                not frame.recording)
            add('full', 'Full', 'Fit the frame to this screen', not frame.recording)
        add('time', frame.time_text, '', False,
            (ORANGE if frame.paused else BRIGHT_RED) if frame.recording else LIGHT, False)
        add('bytes', frame.size_text, '', False, LIGHT, False)
        add('folder', 'Folder', 'Open the recordings folder')
        add('close', '\u2715', 'Stop recording and close' if frame.recording else 'Close the screen recorder')
        metrics = QFontMetrics(self.font_)
        x = 6
        for button in buttons:
            width = metrics.horizontalAdvance(button['text']) + 14 if button['text'] else 0
            if button['id'] == 'time':
                width = max(width, metrics.horizontalAdvance('00:00:00') + 14)
            button['rect'] = QRect(x, 4, width, self.HEIGHT - 8)
            x += width + 3
        self.buttons = buttons
        return x + 3

    def button_at(self, pos):
        for button in self.buttons:
            if button['clickable'] and button['rect'].contains(pos):
                return button
        return None

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), BAR_BACK)
        painter.setFont(self.font_)
        for button in self.buttons:
            if button['clickable'] and button['enabled'] and self.hover == button['id']:
                painter.fillRect(button['rect'], BAR_HOVER)
            painter.setPen(button['color'] if button['enabled'] or not button['clickable'] else GREY)
            painter.drawText(button['rect'], Qt.AlignmentFlag.AlignCenter, button['text'])

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        button = self.button_at(event.position().toPoint())
        if button:
            self.pressed = button['id']
        elif self.frame.movable():
            self.move_start = event.globalPosition().toPoint()
            self.frame.begin_move()

    def mouseMoveEvent(self, event):
        if self.move_start is not None:
            delta = event.globalPosition().toPoint() - self.move_start
            self.frame.move_by(delta.x(), delta.y())
            return
        button = self.button_at(event.position().toPoint())
        ident = button['id'] if button else None
        if ident != self.hover:
            self.hover = ident
            self.update()
            if button and button['tip']:
                QToolTip.showText(self.mapToGlobal(QPoint(button['rect'].left(), self.height() + 4)), button['tip'],
                                  self)
            else:
                QToolTip.hideText()

    def mouseReleaseEvent(self, event):
        if self.move_start is not None:
            self.move_start = None
            self.frame.end_move()
            return
        pressed, self.pressed = self.pressed, None
        button = self.button_at(event.position().toPoint())
        if button and button['id'] == pressed and button['enabled']:
            self.frame.clicked(button['id'], self.mapToGlobal(button['rect'].bottomLeft()))

    def leaveEvent(self, event):
        if self.hover:
            self.hover = None
            QToolTip.hideText()
            self.update()

    def closeEvent(self, event):
        if not self.frame.closing:
            event.ignore()
            QTimer.singleShot(0, lambda: self.frame.command.emit('close'))


class Frame(QObject):
    command = Signal(str)
    BORDER = 5

    def __init__(self, bar_only, capture=None, mode_text=''):
        super().__init__()
        self.bar_only = bar_only
        self.capture = capture or (0, 0, 0, 0)
        self.mode_text = mode_text
        self.recording = False
        self.paused = False
        self.time_text = '00:00:00'
        self.size_text = ''
        self.closing = False
        self.bar_hidden = False
        self.bar_pos = QPoint(0, 0)
        self.position = 0
        self.resize_edges = 0
        self.resize_start = None
        self.resize_rect = None
        self.move_origin = None
        self.toolbar = _Toolbar(self)
        self.strips = [] if bar_only else [_Strip(self, 2), _Strip(self, 8), _Strip(self, 1), _Strip(self, 4)]
        self.menu = None
        self.arrange()

    def widgets(self):
        return self.strips + [self.toolbar]

    def color(self):
        if self.recording:
            return ORANGE if self.paused else RED
        return BLUE

    def movable(self):
        return self.bar_only or not self.recording

    def toolbar_inside(self):
        return self.bar_only or self.position == 2

    def arrange(self):
        width = self.toolbar.build()
        height = _Toolbar.HEIGHT
        if self.bar_only:
            self.toolbar.setGeometry(self.bar_pos.x(), self.bar_pos.y(), width, height)
        else:
            x, y, w, h = self.capture
            b = self.BORDER
            monitor = _monitor(self.capture)
            if y - b - height >= monitor[1]:
                self.position = 0
                self.toolbar.setGeometry(x - b, y - b - height, width, height)
            elif y + h + b + height <= monitor[1] + monitor[3]:
                self.position = 1
                self.toolbar.setGeometry(x - b, y + h + b, width, height)
            else:
                self.position = 2
                self.toolbar.setGeometry(x, y, width, height)
            geometry = ((x - b, y - b, w + 2 * b, b), (x - b, y + h, w + 2 * b, b), (x - b, y, b, h), (x + w, y, b, h))
            for strip, rect in zip(self.strips, geometry):
                strip.setGeometry(_qrect(rect))
        for widget in self.widgets():
            widget.update()

    def place_bar(self, monitor):
        width = self.toolbar.build()
        self.bar_pos = QPoint(monitor[0] + (monitor[2] - width) // 2, monitor[1] + 8)
        self.arrange()

    def show(self):
        for widget in self.strips:
            widget.show()
            _exclude_from_capture(widget)
        if not self.bar_hidden:
            self.toolbar.show()
            _exclude_from_capture(self.toolbar)
        for widget in self.widgets():
            widget.raise_()

    def hide(self):
        for widget in self.widgets():
            widget.hide()

    def close(self):
        self.closing = True
        if self.menu:
            self.menu.close()
        QToolTip.hideText()
        for widget in self.widgets():
            widget.close()
            widget.deleteLater()

    def set_bar_hidden(self, hidden):
        self.bar_hidden = hidden
        self.toolbar.setVisible(not hidden)
        if not hidden:
            _exclude_from_capture(self.toolbar)
            self.toolbar.raise_()

    def set_capture(self, area):
        self.capture = area
        self.arrange()

    def set_state(self, recording, paused):
        self.recording = recording
        self.paused = paused
        if not recording:
            self.time_text = '00:00:00'
        self.arrange()

    def set_status(self, elapsed, size):
        if elapsed == self.time_text and size == self.size_text:
            return
        resize = len(size) != len(self.size_text)
        self.time_text, self.size_text = elapsed, size
        if resize:
            self.arrange()
        else:
            self.toolbar.update()

    def begin_resize(self, edges, point):
        self.resize_edges = edges
        self.resize_start = point
        self.resize_rect = self.capture

    def resize_to(self, point):
        dx, dy = point.x() - self.resize_start.x(), point.y() - self.resize_start.y()
        x, y, w, h = self.resize_rect
        left, top, right, bottom = x, y, x + w, y + h
        minimum = 64
        if self.resize_edges & 1:
            left = min(left + dx, right - minimum)
        if self.resize_edges & 4:
            right = max(right + dx, left + minimum)
        if self.resize_edges & 2:
            top = min(top + dy, bottom - minimum)
        if self.resize_edges & 8:
            bottom = max(bottom + dy, top + minimum)
        width, height = (right - left) & ~1, (bottom - top) & ~1
        if self.resize_edges & 1:
            left = right - width
        if self.resize_edges & 2:
            top = bottom - height
        self.capture = (left, top, width, height)
        self.arrange()

    def end_resize(self):
        self.resize_edges = 0
        self.arrange()
        self.command.emit('moved')

    def begin_move(self):
        self.move_origin = (self.capture, QPoint(self.bar_pos))

    def move_by(self, dx, dy):
        if self.move_origin is None:
            return
        capture, bar = self.move_origin
        if self.bar_only:
            self.bar_pos = bar + QPoint(dx, dy)
        else:
            self.capture = (capture[0] + dx, capture[1] + dy, capture[2], capture[3])
        self.arrange()

    def end_move(self):
        self.move_origin = None
        if not self.bar_only:
            self.command.emit('moved')

    def fit_screen(self):
        monitor = _monitor(self.capture)
        self.capture = (monitor[0], monitor[1], monitor[2] & ~1, monitor[3] & ~1)
        self.arrange()
        self.command.emit('moved')

    def apply_size(self, width, height):
        monitor = _monitor(self.capture)
        width = min(width, monitor[2]) & ~1
        height = min(height, monitor[3]) & ~1
        left = max(monitor[0], min(self.capture[0], monitor[0] + monitor[2] - width))
        top = max(monitor[1], min(self.capture[1], monitor[1] + monitor[3] - height))
        self.capture = (left, top, width, height)
        self.arrange()
        self.command.emit('moved')

    def clicked(self, ident, anchor):
        if ident == 'size':
            self.show_sizes(anchor)
        elif ident == 'full':
            self.fit_screen()
        else:
            self.command.emit(ident)

    def show_sizes(self, anchor):
        menu = QMenu()
        for width, height in logic.SCREEN_FRAME_SIZES:
            action = menu.addAction(f'{width} \u00D7 {height}')
            action.setCheckable(True)
            action.setChecked(self.capture[2] == width and self.capture[3] == height)
            action.triggered.connect(lambda _=False, w=width, h=height: self.apply_size(w, h))
        menu.addSeparator()
        menu.addAction('Full screen').triggered.connect(lambda: self.fit_screen())
        menu.addAction('Select area...').triggered.connect(lambda: self.command.emit('select'))
        self.menu = menu
        try:
            menu.exec(anchor)
        finally:
            self.menu = None
            menu.deleteLater()


class _PickerOverlay(QWidget):
    def __init__(self, picker, screen):
        super().__init__(None, _flags(True))
        self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow, True)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setWindowTitle('Select the recording area')
        self.picker = picker
        self.screen_ = screen
        self.shot = screen.grabWindow(0)
        self.setGeometry(screen.geometry())

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.drawPixmap(self.rect(), self.shot)
        selection = self.picker.selection()
        local = QRect()
        if selection and selection.width() > 0 and selection.height() > 0:
            local = selection.translated(-self.geometry().topLeft())
        region = QRegion(self.rect())
        if not local.isEmpty():
            region = region.subtracted(QRegion(local))
        painter.setClipRegion(region)
        painter.fillRect(self.rect(), QColor(0, 0, 0, 120))
        painter.setClipping(False)
        font = QFont(self.font())
        font.setPixelSize(15)
        painter.setFont(font)
        metrics = QFontMetrics(font)
        if not local.isEmpty():
            painter.setPen(QPen(RED, 2))
            painter.drawRect(local)
            label = f'{selection.width() & ~1} \u00D7 {selection.height() & ~1}'
            box = QRect(local.left(), max(0, local.top() - metrics.height() - 6), metrics.horizontalAdvance(label) + 12,
                        metrics.height() + 4)
            painter.fillRect(box, QColor(30, 30, 30, 200))
            painter.setPen(WHITE)
            painter.drawText(box, Qt.AlignmentFlag.AlignCenter, label)
        elif not selection:
            help_text = 'Drag to select the recording area. Click to select the whole screen. Esc cancels.'
            width = metrics.horizontalAdvance(help_text) + 24
            box = QRect((self.width() - width) // 2, 40, width, metrics.height() + 12)
            painter.fillRect(box, QColor(30, 30, 30, 210))
            painter.setPen(WHITE)
            painter.drawText(box, Qt.AlignmentFlag.AlignCenter, help_text)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.RightButton:
            self.picker.finish(None)
        elif event.button() == Qt.MouseButton.LeftButton:
            self.picker.begin(event.globalPosition().toPoint())

    def mouseMoveEvent(self, event):
        self.picker.drag(event.globalPosition().toPoint())

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.picker.release(event.globalPosition().toPoint())

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.picker.finish(None)

    def closeEvent(self, event):
        if not self.picker.done:
            self.picker.finish(None)


class AreaPicker:
    def __init__(self):
        self.start = None
        self.current = None
        self.result = None
        self.done = False
        self.loop = QEventLoop()
        self.overlays = []

    def selection(self):
        if self.start is None or self.current is None:
            return None
        return QRect(self.start, self.current).normalized()

    def begin(self, point):
        self.start = self.current = point
        self.refresh()

    def drag(self, point):
        if self.start is not None:
            self.current = point
            self.refresh()

    def release(self, point):
        if self.start is None:
            return
        self.current = point
        rect = self.selection()
        if rect.width() < 16 or rect.height() < 16:
            screen = QGuiApplication.screenAt(point) or QGuiApplication.primaryScreen()
            rect = screen.geometry()
        self.finish((rect.x(), rect.y(), rect.width() & ~1, rect.height() & ~1))

    def refresh(self):
        for overlay in self.overlays:
            overlay.update()

    def finish(self, result):
        if self.done:
            return
        self.done = True
        self.result = result
        self.loop.quit()

    def pick(self):
        self.overlays = [_PickerOverlay(self, screen) for screen in QGuiApplication.screens()]
        try:
            for overlay in self.overlays:
                overlay.show()
                overlay.raise_()
            cursor_screen = QGuiApplication.screenAt(QCursor.pos())
            active = next((o for o in self.overlays if o.screen_ is cursor_screen), self.overlays[0])
            active.activateWindow()
            active.setFocus()
            active.grabKeyboard()
            self.loop.exec()
        finally:
            self.done = True
            for overlay in self.overlays:
                overlay.releaseKeyboard()
                overlay.close()
                overlay.deleteLater()
            self.overlays = []
        return self.result


class XKeyEvent(Structure):
    _fields_ = [('type', c_int), ('serial', c_ulong), ('send_event', c_int), ('display', c_void_p),
                ('window', c_ulong), ('root', c_ulong), ('subwindow', c_ulong), ('time', c_ulong), ('x', c_int),
                ('y', c_int), ('x_root', c_int), ('y_root', c_int), ('state', c_uint), ('keycode', c_uint),
                ('same_screen', c_int)]


class XKeyUnion(ctypes.Union):
    _fields_ = [('xkey', XKeyEvent), ('pad', c_long * 24)]


class X11HotKeys:
    LOCKS = (0, 2, 16, 18)
    MODIFIERS = 0x0D
    KEYS = ((0xFFC9, 0, 'rec'), (0xFFC9, 1, 'pause'), (0xFFC8, 0, 'shot'))

    def __init__(self, emit, keys=None, label='screen recorder hotkeys', ungrab=False):
        self.emit = emit
        self.keys = keys or self.KEYS
        self.label = label
        self.ungrab = ungrab
        self.thread = None
        self.stopping = threading.Event()
        self.ready = threading.Event()
        self.failed = False
        self.error_handler = None

    def enable(self):
        if self.thread and self.thread.is_alive():
            return True
        try:
            lib = ctypes.CDLL(ctypes.util.find_library('X11') or 'libX11.so.6')
        except OSError as error:
            log(f'Could not load X11 for the {self.label}: {error}')
            return False
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XOpenDisplay.restype = c_void_p
        lib.XCloseDisplay.argtypes = [c_void_p]
        lib.XDefaultRootWindow.argtypes = [c_void_p]
        lib.XDefaultRootWindow.restype = c_ulong
        lib.XKeysymToKeycode.argtypes = [c_void_p, c_ulong]
        lib.XKeysymToKeycode.restype = ctypes.c_ubyte
        lib.XGrabKey.argtypes = [c_void_p, c_int, c_uint, c_ulong, c_int, c_int, c_int]
        lib.XUngrabKey.argtypes = [c_void_p, c_int, c_uint, c_ulong]
        lib.XSync.argtypes = [c_void_p, c_int]
        lib.XPending.argtypes = [c_void_p]
        lib.XNextEvent.argtypes = [c_void_p, POINTER(XKeyUnion)]
        lib.XConnectionNumber.argtypes = [c_void_p]
        lib.XUngrabKeyboard.argtypes = [c_void_p, c_ulong]
        lib.XFlush.argtypes = [c_void_p]
        self.stopping.clear()
        self.ready.clear()
        self.failed = False
        self.thread = threading.Thread(target=self._run, args=(lib,), name=self.label.replace(' ', '-'), daemon=True)
        self.thread.start()
        self.ready.wait(2)
        return not self.failed

    def _run(self, lib):
        from .windowing import X_ERROR_HANDLER, ignore_x_errors
        display = lib.XOpenDisplay(None)
        if not display:
            log(f'Could not open the X11 display for the {self.label}.')
            self.failed = True
            self.ready.set()
            return
        try:
            def on_error(error_display, event):
                if error_display == display:
                    self.failed = True
                return 0
            self.error_handler = X_ERROR_HANDLER(on_error)
            ignore_x_errors(lib, self.error_handler)
            root = lib.XDefaultRootWindow(display)
            keys = [(lib.XKeysymToKeycode(display, keysym), modifiers, name) for keysym, modifiers, name in self.keys]
            grabs = [(code, modifiers | lock) for lock in self.LOCKS for code, modifiers, _ in keys]
            for code, modifiers in grabs:
                if code:
                    lib.XGrabKey(display, code, modifiers, root, 0, 1, 1)
            lib.XSync(display, 0)
            ignore_x_errors(lib)
            if not any(code for code, _ in grabs):
                self.failed = True
            self.ready.set()
            descriptor = lib.XConnectionNumber(display)
            event = XKeyUnion()
            while not self.stopping.is_set():
                while lib.XPending(display):
                    lib.XNextEvent(display, byref(event))
                    if event.xkey.type != 2:
                        continue
                    for code, modifiers, name in keys:
                        if code and event.xkey.keycode == code and event.xkey.state & self.MODIFIERS == modifiers:
                            if self.ungrab:
                                lib.XUngrabKeyboard(display, event.xkey.time)
                                lib.XFlush(display)
                            self.emit(name)
                            break
                select.select([descriptor], [], [], 0.25)
            for code, modifiers in grabs:
                if code:
                    lib.XUngrabKey(display, code, modifiers, root)
            lib.XSync(display, 0)
        except Exception as error:
            if not self.ready.is_set():
                self.failed = True
            log(f'The {self.label} stopped: {error}')
        finally:
            self.ready.set()
            lib.XCloseDisplay(display)

    def disable(self):
        self.stopping.set()
        if self.thread:
            self.thread.join(1)
        self.thread = None


def _fourcc(text):
    return int.from_bytes(text.encode('ascii'), 'big')


class EventTypeSpec(Structure):
    _fields_ = [('eventClass', c_uint32), ('eventKind', c_uint32)]


class EventHotKeyID(Structure):
    _fields_ = [('signature', c_uint32), ('id', c_uint32)]


class MacHotKeys:
    KEYS = ((1, 111, 0, 'rec'), (2, 111, 0x200, 'pause'), (3, 103, 0, 'shot'))

    def __init__(self, emit, keys=None, label='screen recorder hotkeys'):
        self.emit = emit
        self.keys = keys or self.KEYS
        self.label = label
        self.carbon = None
        self.callback = None
        self.handler = None
        self.refs = []

    def _load(self):
        carbon = ctypes.CDLL('/System/Library/Frameworks/Carbon.framework/Carbon')
        carbon.GetApplicationEventTarget.restype = c_void_p
        handler_type = ctypes.CFUNCTYPE(ctypes.c_int32, c_void_p, c_void_p, c_void_p)
        carbon.InstallEventHandler.argtypes = [c_void_p, handler_type, c_uint32, POINTER(EventTypeSpec), c_void_p,
                                               POINTER(c_void_p)]
        carbon.RegisterEventHotKey.argtypes = [c_uint32, c_uint32, EventHotKeyID, c_void_p, c_uint32,
                                               POINTER(c_void_p)]
        carbon.UnregisterEventHotKey.argtypes = [c_void_p]
        carbon.GetEventParameter.argtypes = [c_void_p, c_uint32, c_uint32, c_void_p, c_ulong, c_void_p, c_void_p]
        self.carbon = carbon
        self.callback = handler_type(self._handle)

    def _handle(self, call, event, data):
        try:
            hotkey = EventHotKeyID()
            if self.carbon.GetEventParameter(event, _fourcc('----'), _fourcc('hkid'), None, ctypes.sizeof(hotkey),
                                             None, byref(hotkey)) == 0 and hotkey.signature == _fourcc('scrm'):
                for ident, _, _, name in self.keys:
                    if hotkey.id == ident:
                        self.emit(name)
                        return 0
        except Exception:
            pass
        return -9874

    def enable(self):
        if self.refs:
            return True
        try:
            if not self.carbon:
                self._load()
            target = self.carbon.GetApplicationEventTarget()
            if not self.handler:
                spec = EventTypeSpec(_fourcc('keyb'), 5)
                handler = c_void_p()
                if self.carbon.InstallEventHandler(target, self.callback, 1, byref(spec), None, byref(handler)):
                    return False
                self.handler = handler
            for ident, code, modifiers, _ in self.keys:
                ref = c_void_p()
                if self.carbon.RegisterEventHotKey(code, modifiers, EventHotKeyID(_fourcc('scrm'), ident), target, 0,
                                                   byref(ref)) == 0:
                    self.refs.append(ref)
        except Exception as error:
            log(f'Could not register the {self.label}: {error}')
        return bool(self.refs)

    def disable(self):
        for ref in self.refs:
            try:
                self.carbon.UnregisterEventHotKey(ref)
            except Exception:
                pass
        self.refs = []


class WinWindowList:
    def __init__(self):
        from ctypes import wintypes
        self.wintypes = wintypes
        self.user32 = ctypes.windll.user32
        self.dwm = ctypes.windll.dwmapi
        self.enum_type = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)

    def window_rect(self, handle):
        wintypes = self.wintypes
        hwnd = wintypes.HWND(handle)
        if not self.user32.IsWindow(hwnd) or self.user32.IsIconic(hwnd):
            return None
        rect = wintypes.RECT()
        point = wintypes.POINT(0, 0)
        if not self.user32.GetClientRect(hwnd, byref(rect)) or not self.user32.ClientToScreen(hwnd, byref(point)):
            return None
        return (point.x, point.y, rect.right - rect.left, rect.bottom - rect.top)

    def list_windows(self):
        wintypes = self.wintypes
        found = []

        def visit(hwnd, _):
            if not self.user32.IsWindowVisible(hwnd) or self.user32.GetWindow(hwnd, 4):
                return True
            length = self.user32.GetWindowTextLengthW(hwnd)
            if not length:
                return True
            cloaked = c_int(0)
            self.dwm.DwmGetWindowAttribute(hwnd, 14, byref(cloaked), ctypes.sizeof(cloaked))
            if cloaked.value:
                return True
            buffer = ctypes.create_unicode_buffer(length + 1)
            self.user32.GetWindowTextW(hwnd, buffer, length + 1)
            pid = wintypes.DWORD()
            self.user32.GetWindowThreadProcessId(hwnd, byref(pid))
            found.append((int(hwnd or 0), buffer.value, pid.value))
            return True

        self.user32.EnumWindows(self.enum_type(visit), 0)
        return found


def create_window_list():
    if IS_WINDOWS:
        return WinWindowList()
    if IS_MAC:
        from .windowing import MacWindowList
        return MacWindowList()
    from .windowing import X11Mover
    mover = X11Mover()
    if not mover.available():
        raise OSError(mover.reason)
    return mover


class ScreenRecorder(QObject):
    hotkey = Signal(str)

    def __init__(self, controller):
        super().__init__()
        self.controller = controller
        self.engine = controller.engine
        self.paths = controller.paths
        self.frame = None
        self.mode = ''
        self.label = ''
        self.device = 0
        self.window = 0
        self.window_serial = ''
        self.recording = False
        self.paused = False
        self.process = None
        self.part = None
        self.part_log = None
        self.part_started = None
        self.parts = []
        self.base = None
        self.elapsed = 0.0
        self.done_bytes = 0
        self.failures = deque()
        self.follow = None
        self.follow_size = (1280, 720)
        self.pending_size = ''
        self.resized_at = 0.0
        self.next_status = 0.0
        self.next_follow = 0.0
        self.next_window_lookup = 0.0
        self.space = None
        self.av_devices = None
        self.windows = None
        self.shots = []
        self.last_hotkey = {}
        self.hotkeys = None
        if IS_LINUX:
            self.hotkeys = X11HotKeys(self.hotkey.emit)
        elif IS_MAC:
            self.hotkeys = MacHotKeys(self.hotkey.emit)
        self.hotkey.connect(self._hotkey)
        self.timer = QTimer(self)
        self.timer.setInterval(100)
        self.timer.timeout.connect(self._safe(self.update))

    def _safe(self, function):
        def wrapper(*args):
            try:
                return function(*args)
            except Exception as error:
                log(f'ERROR: screen recorder: {error!r}')
        return wrapper

    def notify(self, message, icon='info'):
        log(message)
        self.controller.notify(message, icon)

    def active(self):
        return self.frame is not None or self.recording or bool(self.shots)

    def kind(self):
        return 'gdigrab' if IS_WINDOWS else 'avfoundation' if IS_MAC else 'x11grab'

    def unavailable(self):
        if not self.engine.tools.ffmpeg:
            return 'Screen recording needs ffmpeg, which was not found.'
        if IS_LINUX and (QGuiApplication.platformName() != 'xcb' or not os.environ.get('DISPLAY')):
            return 'Screen recording needs an X11 session (Wayland is not supported).'
        return ''

    def folder(self):
        folder = Path(self.controller.engine.record_dir) / 'Screen Recordings'
        folder.mkdir(parents=True, exist_ok=True)
        return folder

    def open_folder(self):
        open_path(self.folder())

    def encoder_args(self):
        return self.engine.combine_encoder or self.engine.get_combine_encoder_args()

    def mac_devices(self):
        if not self.av_devices:
            text = run_hidden([self.engine.tools.ffmpeg, '-hide_banner', '-f', 'avfoundation', '-list_devices', 'true',
                               '-i', ''], 15, include_stderr=True)
            self.av_devices = {index: str(device) for index, device in logic.parse_avfoundation_screens(text).items()}
        return self.av_devices

    def load_space(self, devices=True):
        self.space = Space(self.mac_devices() if IS_MAC and devices else None)
        return self.space

    def window_list(self):
        if self.windows is None:
            self.windows = create_window_list()
        return self.windows

    def session_window(self, serial):
        view = next((v for v in self.controller.snapshot().sessions if v.serial == serial), None)
        if not view or not view.pid or not view.window_shown:
            return 0
        best, best_area = 0, 0
        lister = self.window_list()
        for handle, _, pid in lister.list_windows():
            if pid != view.pid:
                continue
            rect = lister.window_rect(handle)
            if rect and rect[2] * rect[3] > best_area:
                best, best_area = handle, rect[2] * rect[3]
        return best

    def window_rect(self):
        lister = self.window_list()
        rect = lister.window_rect(self.window) if self.window else None
        if not rect and self.window_serial and time.monotonic() >= self.next_window_lookup:
            self.next_window_lookup = time.monotonic() + 1
            self.window = self.session_window(self.window_serial)
            rect = lister.window_rect(self.window) if self.window else None
        return self.space.from_native_window(rect) if rect else None

    def area(self):
        space = self.space
        if self.mode == 'rect':
            return space.to_capture(self.frame.capture) if self.frame else None
        if self.mode == 'all':
            return space.virtual_capture()
        if self.mode == 'monitor':
            display = next((d for d in space.displays if d.number == self.device), space.displays[0])
            return display.capture
        if self.mode == 'window':
            return self.window_rect()
        cursor = space.cursor()
        return logic.follow_area(cursor, space.display_at(*cursor, logical=False).capture, self.follow_size)

    def sources(self, area, follow):
        displays = self.space.displays
        found = displays if follow else [d for d in displays if logic.rect_intersect(d.capture, area)[2] > 0]
        if IS_MAC:
            for display in found:
                if display.device == '':
                    raise RuntimeError(f'Screen {display.number} is not available to ffmpeg. Allow screen recording '
                                       'for this app in System Settings > Privacy & Security.')
        return [(d.device, d.capture) for d in found]

    def bar_captured(self):
        return not IS_WINDOWS and self.frame is not None and self.frame.toolbar_inside()

    def start_part(self):
        space = self.load_space()
        if not space.displays:
            raise RuntimeError('No screen was found.')
        area = self.area()
        if not area or area[2] < 2 or area[3] < 2:
            raise RuntimeError('The window to record is closed or minimized.')
        follow = self.mode in ('window', 'mouse')
        sources = self.sources(area, follow)
        if not sources:
            raise RuntimeError('The recording area is outside the screens.')
        index = len(self.parts) + 1
        part = f'{self.base}_part{index:02d}.mkv'
        args, self.follow = logic.screen_capture_command(self.kind(), sources, area, follow, self.encoder_args(), part,
                                                         os.environ.get('DISPLAY', ':0'))
        self.pending_size = ''
        self.resized_at = 0.0
        self.paths.logs.mkdir(parents=True, exist_ok=True)
        part_log = self.paths.logs / f'screen-record-part{index:02d}.log'
        log(f'Starting screen recorder: {" ".join(args)}')
        with open(part_log, 'wb') as handle:
            self.process = subprocess.Popen([self.engine.tools.ffmpeg] + args, stdin=subprocess.PIPE,
                                            stdout=subprocess.DEVNULL, stderr=handle, **hidden_kwargs())
        self.part = part
        self.part_log = part_log
        self.part_started = time.monotonic()
        self.parts.append(part)

    def stop_part(self):
        process, self.process = self.process, None
        if not process:
            return
        if self.part_started:
            self.elapsed += time.monotonic() - self.part_started
            self.part_started = None
        try:
            if process.poll() is None:
                process.stdin.write(b'q')
                process.stdin.flush()
        except (OSError, ValueError):
            pass
        try:
            process.wait(8)
        except subprocess.TimeoutExpired:
            log('The screen recorder did not stop gracefully; killing it.')
            kill_process(process)
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                pass
        try:
            process.stdin.close()
        except (OSError, ValueError):
            pass
        self.done_bytes += _size(self.part)

    def log_tail(self):
        try:
            lines = Path(self.part_log).read_text(encoding='utf-8', errors='replace').splitlines()
        except OSError:
            return ''
        return ' | '.join(lines[-3:])

    def restore_part(self):
        code = self.process.returncode
        tail = self.log_tail()
        log(f'The screen recorder stopped unexpectedly (exit code {code}): {tail}')
        self.stop_part()
        now = time.monotonic()
        self.failures.append(now)
        while self.failures and now - self.failures[0] > 30:
            self.failures.popleft()
        if len(self.failures) >= 3:
            self.notify(f'Screen recording stopped because ffmpeg failed repeatedly. {tail}', 'warning')
            self.stop_recording()
            return
        try:
            self.start_part()
        except (OSError, RuntimeError) as error:
            self.notify(f'Screen recording stopped: {error}', 'warning')
            self.stop_recording()

    def update_follow(self, now):
        follow = self.follow
        area = self.area()
        if not area or area[2] < 2 or area[3] < 2:
            return
        box = follow['box']
        if self.mode == 'window':
            width = logic.even_size(min(area[2], box[2]))
            height = logic.even_size(min(area[3], box[3]))
            if width != follow['width'] or height != follow['height']:
                size = f'{width}x{height}'
                if self.pending_size != size:
                    self.pending_size = size
                    self.resized_at = now
                elif now - self.resized_at >= 0.8:
                    log(f'The recorded window was resized to {size}; starting a new part.')
                    self.stop_part()
                    try:
                        self.start_part()
                    except (OSError, RuntimeError) as error:
                        self.notify(f'Screen recording stopped: {error}', 'warning')
                        self.stop_recording()
                    return
            else:
                self.pending_size = ''
        x, y = logic.follow_offset(area, box, follow['width'], follow['height'])
        if x == follow['x'] and y == follow['y']:
            return
        try:
            text = ''
            if x != follow['x']:
                text += f'ccrop -1 x {x}\n'
            if y != follow['y']:
                text += f'ccrop -1 y {y}\n'
            self.process.stdin.write(text.encode('ascii'))
            self.process.stdin.flush()
            follow['x'], follow['y'] = x, y
        except (OSError, ValueError):
            pass

    def update(self):
        if not self.active():
            self.timer.stop()
            return
        self.update_shots()
        now = time.monotonic()
        if self.recording and not self.paused and self.process:
            if self.process.poll() is not None:
                self.restore_part()
            elif self.follow and now >= self.next_follow:
                self.next_follow = now + 0.2
                self.update_follow(now)
        if self.recording and self.frame and now >= self.next_status:
            self.next_status = now + 0.5
            elapsed = self.elapsed + (now - self.part_started if self.part_started else 0)
            total = self.done_bytes + (_size(self.part) if self.process else 0)
            seconds = int(elapsed)
            self.frame.set_status(f'{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}',
                                  logic.format_bytes(total))

    def start_recording(self):
        if not self.frame or self.recording:
            return
        if not self.controller.confirm_record_space() or not self.frame or self.recording:
            return
        self.base = logic.screen_capture_base(str(self.folder()), datetime.now(), os.path.exists)
        self.parts = []
        self.failures.clear()
        self.elapsed = 0.0
        self.done_bytes = 0
        for old in self.paths.logs.glob('screen-record-part*.log') if self.paths.logs.is_dir() else []:
            try:
                old.unlink()
            except OSError:
                pass
        try:
            self.start_part()
        except (OSError, RuntimeError) as error:
            self.notify(f'Could not start the screen recording: {error}', 'warning')
            return
        self.recording = True
        self.paused = False
        self.next_status = 0.0
        self.frame.set_state(True, False)
        if self.bar_captured():
            self.frame.set_bar_hidden(True)
            self.notify('Recording the screen. The toolbar is hidden so it is not recorded; press F12 or use the '
                        'Screen recording menu to stop.')
        log(f'Screen recording started: {self.label}')
        self.controller.refresh_soon()

    def stop_recording(self):
        if not self.recording:
            return
        self.stop_part()
        self.recording = False
        self.paused = False
        if self.frame:
            self.frame.set_state(False, False)
            self.frame.set_status('00:00:00', '')
            if self.frame.bar_hidden:
                self.frame.set_bar_hidden(False)
        base, parts = self.base, list(self.parts)
        self.parts = []
        self.engine.post_screen_recording(base, parts)
        self.controller.refresh_soon()

    def toggle_pause(self):
        if not self.recording:
            return
        if self.paused:
            try:
                self.start_part()
            except (OSError, RuntimeError) as error:
                self.notify(f'Screen recording stopped: {error}', 'warning')
                self.stop_recording()
                return
            self.paused = False
            log('Screen recording resumed.')
        else:
            self.stop_part()
            self.paused = True
            log('Screen recording paused.')
        if self.frame:
            self.frame.set_state(True, self.paused)

    def screenshot(self):
        if not self.frame:
            return
        self.load_space()
        area = self.area()
        if not area or area[2] < 2 or area[3] < 2:
            self.notify('Nothing to capture: the window is closed or minimized.', 'warning')
            return
        try:
            sources = self.sources(area, False)
        except RuntimeError as error:
            self.notify(str(error), 'warning')
            return
        if not sources:
            self.notify('Nothing to capture: the area is outside the screens.', 'warning')
            return
        now = datetime.now()
        path = self.folder() / f'Screenshot_{now:%Y%m%d_%H%M%S}_{now.microsecond // 1000:03d}.png'
        args, _ = logic.screen_capture_command(self.kind(), sources, area, False, [], str(path),
                                               os.environ.get('DISPLAY', ':0'), shot=True)
        hide = self.bar_captured() and not self.frame.bar_hidden
        if hide:
            self.frame.set_bar_hidden(True)
        QTimer.singleShot(250 if hide else 0, self._safe(lambda: self._start_shot(args, path, hide)))

    def _start_shot(self, args, path, hide):
        try:
            process = subprocess.Popen([self.engine.tools.ffmpeg] + args, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, **hidden_kwargs())
        except OSError as error:
            self.notify(f'Could not take the screenshot: {error}', 'warning')
            self._restore_bar(hide)
            return
        self.shots.append({'process': process, 'path': path, 'hide': hide, 'started': time.monotonic()})
        self.timer.start()

    def _restore_bar(self, hide):
        if hide and self.frame and self.frame.bar_hidden and not self.recording:
            self.frame.set_bar_hidden(False)

    def update_shots(self):
        for shot in list(self.shots):
            process = shot['process']
            if process.poll() is None:
                if time.monotonic() - shot['started'] < 20:
                    continue
                kill_process(process)
                process.wait(3)
            self.shots.remove(shot)
            error = ''
            try:
                error = process.stderr.read().decode('utf-8', 'replace').strip()
                process.stderr.close()
            except (OSError, ValueError):
                pass
            self._restore_bar(shot['hide'])
            if process.returncode == 0 and Path(shot['path']).is_file():
                self.notify(f'Screenshot saved: {shot["path"]}')
            else:
                log(f'Screenshot failed: {error}')
                self.notify('Could not take the screenshot.', 'warning')

    def select_area(self):
        frame = self.frame
        frame.hide()
        try:
            area = logic.normalize_screen_area(AreaPicker().pick())
        finally:
            if self.frame is frame:
                frame.show()
        if not area or self.frame is not frame:
            return
        frame.set_capture(area)
        self.save_area(area)

    def save_area(self, area):
        set_setting(self.paths.settings, 'ScreenArea', '{},{},{},{}'.format(*area))

    def saved_area(self):
        primary = QGuiApplication.primaryScreen()
        return logic.screen_area_from_setting(get_setting(self.paths.settings, 'ScreenArea'),
                                              self.space.virtual_logical(), _tuple(primary.geometry()))

    def _hotkey(self, name):
        now = time.monotonic()
        if now - self.last_hotkey.get(name, 0) < 0.4:
            return
        self.last_hotkey[name] = now
        self.command(name)

    def command(self, name):
        if not self.frame and name != 'folder':
            return
        try:
            if name == 'rec':
                if self.recording:
                    self.stop_recording()
                else:
                    self.start_recording()
            elif name == 'pause':
                self.toggle_pause()
            elif name == 'shot':
                self.screenshot()
            elif name == 'folder':
                self.open_folder()
            elif name == 'close':
                self.close()
            elif name == 'moved':
                self.save_area(self.frame.capture)
            elif name == 'select':
                self.select_area()
        except Exception as error:
            log(f'ERROR: screen recorder command {name}: {error!r}')
        self.controller.refresh_soon()

    def close(self):
        self.stop_recording()
        if self.hotkeys:
            self.hotkeys.disable()
        frame, self.frame = self.frame, None
        if frame:
            frame.close()
            frame.deleteLater()
        self.controller.refresh_soon()

    def shutdown(self):
        self.close()
        for shot in self.shots:
            kill_process(shot['process'])
        self.shots = []
        self.timer.stop()
        if self.windows is not None and hasattr(self.windows, 'close'):
            self.windows.close()

    def open(self, mode, target='', label=''):
        reason = self.unavailable()
        if reason:
            self.notify(reason, 'warning')
            return
        if self.recording:
            self.notify('A screen recording is in progress. Stop it (F12) before choosing another area.')
            return
        space = self.load_space(False)
        if not space.displays:
            return
        self.close()
        self.engine.post(self.engine.get_combine_encoder_args)
        area = None
        if mode == 'select':
            area = logic.normalize_screen_area(AreaPicker().pick())
            if not area:
                return
            self.save_area(area)
            mode = 'rect'
        elif mode == 'rect':
            area = self.saved_area()
        self.mode = mode
        self.device = 0
        self.window = 0
        self.window_serial = ''
        self.follow = None
        self.follow_size = logic.parse_follow_size(get_setting(self.paths.settings, 'ScreenFollowSize'))
        self.label = 'Rectangle on screen'
        bar_area = space.displays[0].logical
        if mode == 'all':
            virtual = space.virtual_capture()
            self.label = f'Full screen ({virtual[2]} x {virtual[3]})'
        elif mode == 'monitor':
            display = next((d for d in space.displays if str(d.number) == target), space.displays[0])
            self.device = display.number
            self.label = (f'Screen {display.number} ({display.capture[2]} x {display.capture[3]})'
                          if len(space.displays) > 1 else f'Full screen ({display.capture[2]} x {display.capture[3]})')
            bar_area = display.logical
        elif mode == 'window':
            try:
                if target.startswith('serial:'):
                    self.window_serial = target[7:]
                elif target.startswith('window:'):
                    self.window = int(target[7:])
                rect = self.window_rect()
            except (OSError, ValueError) as error:
                log(f'Window lookup failed: {error}')
                rect = None
            if not rect:
                self.notify('The window to record is no longer open.', 'warning')
                return
            self.label = f'Window: {label}'
            bar_area = space.logical_monitor(rect)
        elif mode == 'mouse':
            match = logic.parse_follow_size(target) if target else None
            if match and target == f'{match[0]}x{match[1]}':
                self.follow_size = match
                set_setting(self.paths.settings, 'ScreenFollowSize', target)
            self.label = f'Around mouse ({self.follow_size[0]} x {self.follow_size[1]})'
            pos = QCursor.pos()
            bar_area = space.display_at(pos.x(), pos.y()).logical
        if mode == 'rect':
            frame = Frame(False, area)
        else:
            frame = Frame(True, None, self.label)
            frame.place_bar(bar_area)
        frame.command.connect(self._safe(self.command))
        self.frame = frame
        frame.show()
        if self.hotkeys and not self.hotkeys.enable():
            log('Could not enable the screen recorder hotkeys.')
        self.timer.start()
        log(f'Screen recorder opened: {self.label}')
        self.controller.refresh_soon()

    def request(self, mode, target='', label=''):
        QTimer.singleShot(200, self._safe(lambda: self.open(mode, target, label)))

    def window_choices(self):
        choices = []
        owned = set()
        for view in sorted(self.controller.snapshot().sessions, key=lambda v: v.title.lower()):
            if view.window_shown and view.pid:
                owned.add(view.pid)
                choices.append((view.title, f'serial:{view.serial}', True))
        others = []
        try:
            for handle, title, pid in self.window_list().list_windows():
                if pid == os.getpid() or pid in owned or not title:
                    continue
                others.append((title if len(title) <= 60 else title[:57] + '...', f'window:{handle}', False))
        except Exception as error:
            log(f'Could not list windows: {error!r}')
        return choices + sorted(others, key=lambda c: c[0].lower())

    def build_menu(self, menu):
        menu.clear()

        def add(parent, text, function, checked=None, enabled=True):
            action = parent.addAction(text)
            action.setEnabled(enabled)
            if checked is not None:
                action.setCheckable(True)
                action.setChecked(checked)
            action.triggered.connect(self._safe(lambda *_: function()))
            return action

        reason = self.unavailable()
        if reason:
            add(menu, 'Needs ffmpeg (not found)' if not self.engine.tools.ffmpeg else reason, lambda: None,
                enabled=False)
            return
        if self.frame:
            add(menu, 'Stop screen recording (F12)' if self.recording else 'Start screen recording (F12)',
                lambda: self.command('rec'))
            if self.recording:
                add(menu, 'Resume (Shift+F12)' if self.paused else 'Pause (Shift+F12)', lambda: self.command('pause'))
            add(menu, 'Take screenshot (F11)', lambda: self.command('shot'))
            if not self.recording:
                add(menu, 'Close screen recorder', lambda: self.command('close'))
            menu.addSeparator()
        if not self.recording:
            mode = self.mode if self.frame else ''
            space = Space()
            add(menu, 'Rectangle on screen', lambda: self.request('rect'), mode == 'rect')
            add(menu, 'Select area...', lambda: self.request('select'))
            if len(space.displays) > 1:
                virtual = space.virtual_capture()
                add(menu, f'Full screen - all screens ({virtual[2]} x {virtual[3]})', lambda: self.request('all'),
                    mode == 'all')
            for display in space.displays:
                if len(space.displays) > 1:
                    text = (f'Screen {display.number} ({display.capture[2]} x {display.capture[3]})'
                            + (', main' if display.primary else ''))
                else:
                    text = f'Full screen ({display.capture[2]} x {display.capture[3]})'
                add(menu, text, lambda n=display.number: self.request('monitor', str(n)),
                    mode == 'monitor' and self.device == display.number)
            window_menu = menu.addMenu('Lock to window')
            choices = self.window_choices()
            previous_device = True
            for text, target, device in choices:
                if previous_device and not device and not window_menu.isEmpty():
                    window_menu.addSeparator()
                previous_device = device
                add(window_menu, text, lambda t=target, l=text: self.request('window', t, l))
            if not choices:
                add(window_menu, 'No window', lambda: None, enabled=False)
            if mode == 'window':
                window_menu.setTitle('Lock to window  \u2713')
            mouse_menu = menu.addMenu('Around mouse' + ('  \u2713' if mode == 'mouse' else ''))
            saved = logic.parse_follow_size(get_setting(self.paths.settings, 'ScreenFollowSize'))
            for size in FOLLOW_SIZES:
                add(mouse_menu, size.replace('x', ' x '), lambda s=size: self.request('mouse', s),
                    size == f'{saved[0]}x{saved[1]}')
            menu.addSeparator()
        add(menu, 'Open screen recordings folder', self.open_folder)


def _size(path):
    try:
        return os.path.getsize(path) if path else 0
    except OSError:
        return 0
