import ctypes
import os
import time
import traceback
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QEventLoop, QObject, QPoint, QPointF, QRect, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import (QColor, QCursor, QFont, QFontMetrics, QGuiApplication, QIcon, QImage, QKeySequence,
                           QPainter, QPalette, QPen, QPixmap, QPolygonF, QRegion, QShortcut)
from PySide6.QtWidgets import (QFileDialog, QLabel, QMainWindow, QMenu, QMessageBox, QScrollArea, QToolButton,
                               QWidget)

from . import logic
from .screenrec import MacHotKeys, X11HotKeys, _flags
from .system import IS_LINUX, IS_MAC, IS_WINDOWS, get_setting, log, open_path, set_setting

RED = QColor(230, 30, 30)
WHITE = QColor(255, 255, 255)
SELECTED = QColor(30, 144, 255)
HOVER = QColor(70, 70, 78)
BAR_BACK = QColor(38, 38, 42, 235)
DIM = QColor(0, 0, 0, 110)
LABEL_BACK = QColor(30, 30, 30, 200)
COLORS = ((QColor(230, 30, 30), 'Red'), (QColor(255, 214, 0), 'Yellow'), (QColor(40, 180, 70), 'Green'),
          (QColor(30, 120, 255), 'Blue'), (QColor(0, 0, 0), 'Black'), (QColor(255, 255, 255), 'White'))
TOOLS = (('pen', 'Pen', 'P'), ('highlighter', 'Highlighter', 'H'), ('rect', 'Rectangle', 'R'), ('arrow', 'Arrow', 'A'),
         ('eraser', 'Eraser', 'E'), ('crop', 'Crop', 'X'))
COLORED_TOOLS = ('pen', 'highlighter', 'rect', 'arrow')
WIDTHS = ((2.0, 'Thin'), (4.0, 'Medium'), (8.0, 'Thick'))
BUTTONS = ('rect', 'window', 'screen', 'all', 'cancel')
KEY_NAMES = ('Control+Option+S',) if IS_MAC else ('Super+Shift+S', 'Print Screen')
KEY_TEXT = ' and '.join(KEY_NAMES)
UNDO_LIMIT = 100


def save_image(image, path):
    jpeg = logic.is_jpeg(path)
    if not image.save(str(path), 'JPG' if jpeg else 'PNG', 92 if jpeg else -1):
        raise OSError(f'could not write {path}')


def copy_image(image):
    try:
        QGuiApplication.clipboard().setImage(image)
        return True
    except Exception as error:
        log(f'Could not copy the snip to the clipboard: {error!r}')
        return False


def _tuple(rect):
    return (rect.x(), rect.y(), rect.width(), rect.height())


class Shot:
    def __init__(self, screen):
        self.geometry = screen.geometry()
        pixmap = screen.grabWindow(0)
        self.image = pixmap.toImage()
        self.image.setDevicePixelRatio(1.0)
        self.ratio = self.image.width() / self.geometry.width() if self.geometry.width() > 0 else 1.0
        self.capture = (self.geometry.x(), self.geometry.y(), self.image.width(), self.image.height())


def _scale(shots, area):
    ratios = [shot.ratio for shot in shots if shot.geometry.intersects(area)]
    return max(ratios) if ratios else 1.0


def compose(shots, area):
    if area.width() < 1 or area.height() < 1:
        return None
    scale = _scale(shots, area)
    image = QImage(max(1, round(area.width() * scale)), max(1, round(area.height() * scale)),
                   QImage.Format.Format_RGB32)
    image.fill(Qt.GlobalColor.black)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    try:
        for shot in shots:
            part = shot.geometry.intersected(area)
            if part.isEmpty():
                continue
            target = QRectF((part.x() - area.x()) * scale, (part.y() - area.y()) * scale, part.width() * scale,
                            part.height() * scale)
            source = QRectF((part.x() - shot.geometry.x()) * shot.ratio, (part.y() - shot.geometry.y()) * shot.ratio,
                            part.width() * shot.ratio, part.height() * shot.ratio)
            painter.drawImage(target, shot.image, source)
    finally:
        painter.end()
    return image


class _SnipOverlay(QWidget):
    def __init__(self, picker, shot):
        super().__init__(None, _flags(True))
        self.setAttribute(Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow, True)
        self.setAttribute(Qt.WidgetAttribute.WA_OpaquePaintEvent, True)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setWindowTitle('Snip')
        self.picker = picker
        self.shot = shot
        self.setGeometry(shot.geometry)

    def paintEvent(self, event):
        painter = QPainter(self)
        try:
            dirty = event.rect()
            ratio = self.shot.ratio
            painter.drawImage(QRectF(dirty), self.shot.image,
                              QRectF(dirty.x() * ratio, dirty.y() * ratio, dirty.width() * ratio,
                                     dirty.height() * ratio))
            origin = self.shot.geometry.topLeft()
            painter.translate(-origin.x(), -origin.y())
            self.picker.paint(painter, dirty.translated(origin))
        finally:
            painter.end()

    def mousePressEvent(self, event):
        self.picker.press(event.button(), event.globalPosition().toPoint())

    def mouseMoveEvent(self, event):
        self.picker.move(event.globalPosition().toPoint())

    def mouseReleaseEvent(self, event):
        self.picker.release(event.button(), event.globalPosition().toPoint())

    def keyPressEvent(self, event):
        self.picker.key(event.key())

    def closeEvent(self, event):
        if not self.picker.done:
            self.picker.finish(None)


class SnipPicker:
    def __init__(self, shots, windows, mode):
        self.shots = shots
        self.screens = [shot.geometry for shot in shots]
        self.bounds = QRect()
        for screen in self.screens:
            self.bounds = self.bounds.united(screen)
        self.windows = windows
        self.mode = mode if mode in ('window', 'screen') else 'rect'
        self.start = QPoint()
        self.selection = QRect()
        self.dragging = False
        self.hover = QRect()
        self.hot = -1
        self.result = None
        self.done = False
        self.loop = QEventLoop()
        self.overlays = []
        self.font = QFont()
        self.font.setPixelSize(14)
        self.metrics = QFontMetrics(self.font)
        multiple = len(self.screens) > 1
        self.labels = ('Rectangle', 'Window', 'Screen' if multiple else 'Full screen',
                       'All screens' if multiple else '', 'Cancel')
        self.buttons = []
        self.bar = QRect()
        self.hint = QRect()
        self.arrange(QCursor.pos())

    def arrange(self, cursor):
        monitor = next((screen for screen in self.screens if screen.contains(cursor)), self.screens[0])
        pad, height = 12, self.metrics.height() + 16
        widths = [self.metrics.horizontalAdvance(label) + 2 * pad if label else 0 for label in self.labels]
        left, top = monitor.left() + (monitor.width() - sum(widths)) // 2, monitor.top() + 16
        self.buttons = []
        for width in widths:
            self.buttons.append(QRect(left, top, width, height) if width else QRect())
            left += width
        self.bar = self.buttons[0].united(self.buttons[4])
        self.place_hint()
        if self.mode != 'rect':
            self.hover = self.target(cursor)

    def hint_text(self):
        if self.mode == 'window':
            return 'Click a window to snip it. Esc cancels.'
        if self.mode == 'screen':
            return 'Click a screen to snip it. Esc cancels.'
        return 'Drag to snip an area. Esc cancels.'

    def place_hint(self):
        pad = 12
        width = self.metrics.horizontalAdvance(self.hint_text()) + 2 * pad
        self.hint = QRect(self.bar.x() + (self.bar.width() - width) // 2, self.bar.y() + self.bar.height() + 8, width,
                          self.metrics.height() + pad)

    def button_at(self, point):
        for index, rect in enumerate(self.buttons):
            if not rect.isEmpty() and rect.contains(point):
                return index
        return -1

    def target(self, point):
        windows = self.windows if self.mode == 'window' else []
        rect = logic.snip_target(windows, [_tuple(screen) for screen in self.screens], point.x(), point.y())
        return QRect(*rect) if rect else QRect()

    def highlight(self):
        if self.mode == 'rect':
            return self.selection if self.dragging else QRect()
        return self.hover

    def pixel_size(self, rect):
        scale = _scale(self.shots, rect)
        return round(rect.width() * scale), round(rect.height() * scale)

    def paint(self, painter, area):
        focus = self.highlight()
        region = QRegion(area)
        if not focus.isEmpty():
            region = region.subtracted(QRegion(focus))
        painter.save()
        painter.setClipRegion(region)
        painter.fillRect(area, DIM)
        painter.restore()
        painter.setFont(self.font)
        if not focus.isEmpty():
            painter.setPen(QPen(RED, 2))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRect(QRectF(focus).adjusted(1, 1, -1, -1))
            if self.mode == 'rect':
                label = '{} \u00D7 {}'.format(*self.pixel_size(focus))
                screen = next((s for s in self.screens if s.contains(focus.topLeft())), self.bounds)
                height = self.metrics.height() + 2
                box = QRect(focus.left(), max(screen.top(), focus.top() - height - 4),
                            self.metrics.horizontalAdvance(label) + 8, height)
                painter.fillRect(box, LABEL_BACK)
                painter.setPen(WHITE)
                painter.drawText(box, Qt.AlignmentFlag.AlignCenter, label)
        if self.dragging:
            return
        painter.fillRect(self.bar, BAR_BACK)
        painter.fillRect(self.hint, BAR_BACK)
        painter.setPen(WHITE)
        painter.drawText(self.hint, Qt.AlignmentFlag.AlignCenter, self.hint_text())
        for index, rect in enumerate(self.buttons):
            if rect.isEmpty():
                continue
            selected = BUTTONS[index] == self.mode
            if selected or index == self.hot:
                painter.fillRect(rect, SELECTED if selected else HOVER)
            painter.setPen(WHITE)
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, self.labels[index])

    def repaint(self, rect=None):
        for overlay in self.overlays:
            geometry = overlay.shot.geometry
            if rect is None:
                overlay.update()
                continue
            part = rect.adjusted(-4, -4, 4, 4).intersected(geometry)
            if not part.isEmpty():
                overlay.update(part.translated(-geometry.topLeft()))

    def choose(self, index):
        ident = BUTTONS[index]
        if ident == 'cancel':
            self.finish(None)
        elif ident == 'all':
            self.finish(QRect(self.bounds))
        elif ident == 'screen' and len(self.screens) == 1:
            self.finish(QRect(self.screens[0]))
        else:
            self.mode = ident
            self.dragging = False
            self.selection = QRect()
            self.hover = QRect() if ident == 'rect' else self.target(QCursor.pos())
            self.place_hint()
            self.repaint()

    def press(self, button, point):
        if button == Qt.MouseButton.RightButton:
            self.finish(None)
            return
        if button != Qt.MouseButton.LeftButton:
            return
        index = self.button_at(point)
        if index >= 0:
            self.choose(index)
            return
        if self.mode != 'rect':
            return
        self.start = point
        self.selection = QRect(point, QSize(0, 0))
        self.dragging = True
        self.repaint()

    def move(self, point):
        index = -1 if self.dragging else self.button_at(point)
        if index != self.hot:
            self.hot = index
            self.repaint(self.bar)
        if self.dragging:
            previous = self.selection
            self.selection = QRect(*logic.rect_from_points((self.start.x(), self.start.y()), (point.x(), point.y())))
            self.repaint(previous.united(self.selection).adjusted(-200, -60, 200, 60))
        elif self.mode != 'rect':
            target = self.hover if index >= 0 else self.target(point)
            if target != self.hover:
                self.repaint(self.hover)
                self.hover = target
                self.repaint(self.hover)

    def release(self, button, point):
        if button != Qt.MouseButton.LeftButton:
            return
        if self.dragging:
            self.dragging = False
            if self.selection.width() >= 4 and self.selection.height() >= 4:
                self.finish(QRect(self.selection))
                return
            self.selection = QRect()
            self.repaint()
            return
        if self.mode != 'rect' and not self.hover.isEmpty() and self.button_at(point) < 0:
            self.finish(QRect(self.hover))

    def key(self, key):
        if key == Qt.Key.Key_Escape:
            if self.dragging:
                self.dragging = False
                self.selection = QRect()
                self.repaint()
            else:
                self.finish(None)
        elif key in (Qt.Key.Key_Return, Qt.Key.Key_Enter) and self.mode != 'rect' and not self.hover.isEmpty():
            self.finish(QRect(self.hover))

    def finish(self, result):
        if self.done:
            return
        self.done = True
        self.result = result
        self.loop.quit()

    def pick(self):
        self.overlays = [_SnipOverlay(self, shot) for shot in self.shots]
        try:
            for overlay in self.overlays:
                overlay.show()
                overlay.raise_()
            cursor = QCursor.pos()
            active = next((o for o in self.overlays if o.shot.geometry.contains(cursor)), self.overlays[0])
            active.activateWindow()
            active.setFocus()
            active.grabKeyboard()
            if not self.done:
                self.loop.exec()
        finally:
            self.done = True
            for overlay in self.overlays:
                overlay.releaseKeyboard()
                overlay.close()
                overlay.deleteLater()
            self.overlays = []
        if self.result is None or self.result.width() < 1 or self.result.height() < 1:
            return None
        return compose(self.shots, self.result)


class Shape:
    __slots__ = ('kind', 'color', 'width', 'points')

    def __init__(self, kind, color, width, points):
        self.kind = kind
        self.color = color
        self.width = width
        self.points = points

    def moved(self, dx, dy):
        return Shape(self.kind, self.color, self.width, [(x - dx, y - dy) for x, y in self.points])


class State:
    __slots__ = ('image', 'shapes')

    def __init__(self, image, shapes):
        self.image = image
        self.shapes = shapes


def draw_shape(painter, shape):
    points = shape.points
    pen = QPen(shape.color, shape.width)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    pen.setCapStyle(Qt.PenCapStyle.SquareCap if shape.kind == 'highlighter' else Qt.PenCapStyle.RoundCap)
    if shape.kind == 'rect':
        pen.setJoinStyle(Qt.PenJoinStyle.MiterJoin)
        painter.setPen(pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawRect(QRectF(*logic.rect_from_points(points[0], points[1])))
    elif shape.kind == 'arrow':
        geometry = logic.arrow_geometry(points[0], points[1], shape.width)
        if not geometry:
            return
        shaft, head = geometry
        if shaft:
            painter.setPen(pen)
            painter.drawLine(QPointF(*points[0]), QPointF(*shaft))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(shape.color)
        painter.drawPolygon(QPolygonF([QPointF(*point) for point in head]))
    elif len(points) == 1:
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(shape.color)
        painter.drawEllipse(QPointF(*points[0]), shape.width / 2, shape.width / 2)
    else:
        painter.setPen(pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPolyline(QPolygonF([QPointF(*point) for point in points]))


def _swatch(color):
    pixmap = QPixmap(16, 16)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.fillRect(1, 1, 14, 14, color)
    painter.setPen(QColor(128, 128, 128))
    painter.drawRect(1, 1, 13, 13)
    painter.end()
    return QIcon(pixmap)


def _native(sequence):
    return QKeySequence(sequence).toString(QKeySequence.SequenceFormat.NativeText)


class _Canvas(QWidget):
    def __init__(self, editor):
        super().__init__()
        self.editor = editor
        self.setAttribute(Qt.WidgetAttribute.WA_OpaquePaintEvent, True)
        self.setCursor(Qt.CursorShape.CrossCursor)

    def paintEvent(self, event):
        self.editor.paint_canvas(self, event)

    def mousePressEvent(self, event):
        self.editor.canvas_down(event)

    def mouseMoveEvent(self, event):
        self.editor.canvas_move(event)

    def mouseReleaseEvent(self, event):
        self.editor.canvas_up(event)


class _Host(QScrollArea):
    def __init__(self, editor):
        super().__init__()
        self.editor = editor
        self.setFrameShape(QScrollArea.Shape.NoFrame)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setWidgetResizable(False)
        viewport = self.viewport()
        palette = viewport.palette()
        palette.setColor(QPalette.ColorRole.Window, QColor(64, 64, 68))
        viewport.setPalette(palette)
        viewport.setAutoFillBackground(True)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.editor.update_layout()


class SnipEditor(QMainWindow):
    new_snip = Signal(str)
    closed = Signal()

    def __init__(self, image, path, status, icon=None):
        super().__init__(None)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, True)
        self.setWindowTitle('Snip')
        self.setMinimumSize(640, 400)
        if icon is not None:
            self.setWindowIcon(icon)
        self.prompt = True
        self.file_path = ''
        self.tool = 'pen'
        self.pen_color = COLORS[0][0]
        self.highlight_color = COLORS[1][0]
        self.width_index = 1
        self.zoom = 1.0
        self.scale = 1.0
        self.fit = True
        self.undo_states = []
        self.redo_states = []
        self.current = None
        self.saved = None
        self.rendered = None
        self.view = None
        self.drawing = None
        self.erasing = False
        self.erased = False
        self.cropping = False
        self.crop_start = (0.0, 0.0)
        self.crop_end = (0.0, 0.0)

        self.host = _Host(self)
        self.canvas = _Canvas(self)
        self.host.setWidget(self.canvas)
        self.setCentralWidget(self.host)
        self.message = QLabel()
        self.size_label = QLabel()
        self.statusBar().addWidget(self.message, 1)
        self.statusBar().addPermanentWidget(self.size_label)

        bar = self.addToolBar('Snip')
        bar.setMovable(False)
        bar.setFloatable(False)
        bar.setContextMenuPolicy(Qt.ContextMenuPolicy.PreventContextMenu)
        bar.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.bar = bar
        new_menu = QMenu(self)
        for mode, text in (('rect', 'Rectangle'), ('window', 'Window'), ('screen', 'Screen'), ('all', 'All screens')):
            new_menu.addAction(text).triggered.connect(lambda *_, m=mode: self.request_snip(m))
        new_button = QToolButton()
        new_button.setText('New snip')
        new_button.setToolTip(f'New snip ({_native("Ctrl+N")})')
        new_button.setPopupMode(QToolButton.ToolButtonPopupMode.MenuButtonPopup)
        new_button.setMenu(new_menu)
        new_button.clicked.connect(lambda *_: self.request_snip('rect'))
        bar.addWidget(new_button)
        bar.addSeparator()
        self.tool_actions = {}
        for ident, text, key in TOOLS:
            action = bar.addAction(text)
            action.setCheckable(True)
            action.setToolTip(f'{text} ({key})')
            action.triggered.connect(lambda *_, i=ident: self.select_tool(i))
            self.tool_actions[ident] = action
            QShortcut(QKeySequence(key), self, activated=lambda i=ident: self.select_tool(i))
        bar.addSeparator()
        color_menu = QMenu(self)
        for color, name in COLORS:
            color_menu.addAction(_swatch(color), name).triggered.connect(lambda *_, c=color: self.set_color(c))
        self.color_button = QToolButton()
        self.color_button.setText('Color')
        self.color_button.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.color_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.color_button.setMenu(color_menu)
        bar.addWidget(self.color_button)
        width_menu = QMenu(self)
        for index, (_, name) in enumerate(WIDTHS):
            width_menu.addAction(name).triggered.connect(lambda *_, i=index: self.set_width(i))
        self.width_button = QToolButton()
        self.width_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.width_button.setMenu(width_menu)
        bar.addWidget(self.width_button)
        bar.addSeparator()
        self.undo_action = self._button('Undo', 'Ctrl+Z', self.undo)
        self.redo_action = self._button('Redo', 'Ctrl+Y', self.redo)
        bar.addSeparator()
        self.fit_action = self._button('Fit to window', 'Ctrl+0', lambda: self.set_fit(not self.fit),
                                       'Fit to window or show at 100%')
        self.fit_action.setCheckable(True)
        bar.addSeparator()
        self._button('Copy', 'Ctrl+C', self.copy, 'Copy to the clipboard')
        self._button('Save', 'Ctrl+S', self.save)
        self._button('Save as...', 'Ctrl+Shift+S', self.save_as, 'Save as PNG or JPEG')
        for sequence, function in (('Ctrl+Z', self.undo), ('Ctrl+Y', self.redo), ('Ctrl+Shift+Z', self.redo),
                                   ('Ctrl+0', lambda: self.set_fit(not self.fit)), ('Ctrl+C', self.copy),
                                   ('Ctrl+S', self.save), ('Ctrl+Shift+S', self.save_as),
                                   ('Ctrl+N', lambda: self.request_snip('rect')), ('Esc', self.cancel_stroke)):
            QShortcut(QKeySequence(sequence), self, activated=function)

        self.load_image(image, path, status)
        self.place(image)

    def _button(self, text, sequence, function, tip=None):
        action = self.bar.addAction(text)
        action.setToolTip(f'{tip or text} ({_native(sequence)})')
        action.triggered.connect(lambda *_: function())
        return action

    def place(self, image):
        screen = QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        if screen is None:
            self.resize(900, 600)
            return
        area = screen.availableGeometry()
        ratio = screen.devicePixelRatio() or 1
        chrome_height = self.bar.sizeHint().height() + self.statusBar().sizeHint().height() + 40
        width = max(640, min(area.width() * 9 // 10, round(image.width() / ratio) + 40))
        height = max(400, min(area.height() * 9 // 10, round(image.height() / ratio) + chrome_height))
        width = max(width, min(area.width() * 9 // 10, self.bar.sizeHint().width() + 16))
        self.setGeometry(area.x() + (area.width() - width) // 2, area.y() + (area.height() - height) // 2, width,
                         height)

    def load_image(self, image, path, status):
        self.drawing = None
        self.erasing = self.cropping = False
        self.undo_states = []
        self.redo_states = []
        self.drop_cache()
        self.current = self.saved = State(image, [])
        self.file_path = str(path)
        self.fit = True
        self.set_message(status)
        self.update_layout()
        self.update_state()

    def show_editor(self):
        if not self.isVisible():
            self.show()
        if self.isMinimized():
            self.showNormal()
        self.raise_()
        self.activateWindow()

    def modified(self):
        return self.current is not self.saved

    def set_message(self, text):
        self.message.setText(text or '')

    def request_snip(self, mode):
        self.new_snip.emit(mode)

    def select_tool(self, ident):
        if not self.cropping and self.drawing is None:
            self.tool = ident
        self.update_state()

    def set_color(self, color):
        if self.tool == 'highlighter':
            self.highlight_color = color
        else:
            self.pen_color = color
        self.update_state()

    def set_width(self, index):
        self.width_index = index
        self.update_state()

    def set_fit(self, value):
        self.fit = value
        if not value:
            self.zoom = 1.0
        self.update_layout()
        self.update_state()

    def update_state(self):
        if self.current is None:
            return
        name = os.path.basename(self.file_path)
        self.setWindowTitle(f'{name}{" *" if self.modified() else ""} - Snip')
        for ident, action in self.tool_actions.items():
            action.setChecked(ident == self.tool)
        colored = self.tool in COLORED_TOOLS
        self.color_button.setEnabled(colored)
        self.width_button.setEnabled(colored)
        self.color_button.setIcon(_swatch(self.highlight_color if self.tool == 'highlighter' else self.pen_color))
        self.width_button.setText(WIDTHS[self.width_index][1])
        self.undo_action.setEnabled(bool(self.undo_states))
        self.redo_action.setEnabled(bool(self.redo_states))
        self.fit_action.setChecked(self.fit)
        image = self.current.image
        self.size_label.setText(f'{image.width()} \u00D7 {image.height()}   {round(self.zoom * 100)}%')

    def update_layout(self):
        if self.current is None:
            return
        image = self.current.image
        ratio = self.canvas.devicePixelRatioF() or 1.0
        previous = self.zoom, self.canvas.size()
        if self.fit and self.host.width() > 0 and self.host.height() > 0:
            self.zoom = logic.fit_zoom(self.host.width(), self.host.height(), image.width() / ratio,
                                       image.height() / ratio)
        self.scale = self.zoom / ratio
        size = QSize(max(1, round(image.width() * self.scale)), max(1, round(image.height() * self.scale)))
        if (self.zoom, size) != previous:
            self.view = None
        self.canvas.setFixedSize(size)
        self.canvas.update()
        self.update_state()

    def drop_cache(self):
        self.rendered = None
        self.view = None

    def changed(self):
        self.drop_cache()
        self.canvas.update()
        self.update_state()

    def push(self, state):
        self.undo_states.append(self.current)
        if len(self.undo_states) > UNDO_LIMIT:
            del self.undo_states[0]
        self.redo_states = []
        self.current = state
        self.changed()

    def undo(self):
        if not self.undo_states or self.drawing is not None or self.cropping:
            return
        self.redo_states.append(self.current)
        self.current = self.undo_states.pop()
        self.changed()
        self.update_layout()

    def redo(self):
        if not self.redo_states or self.drawing is not None or self.cropping:
            return
        self.undo_states.append(self.current)
        self.current = self.redo_states.pop()
        self.changed()
        self.update_layout()

    def rendered_image(self):
        if self.rendered is None:
            image = self.current.image.convertToFormat(QImage.Format.Format_RGB32)
            if self.current.shapes:
                painter = QPainter(image)
                painter.setRenderHint(QPainter.RenderHint.Antialiasing)
                for shape in self.current.shapes:
                    draw_shape(painter, shape)
                painter.end()
            self.rendered = image
        return self.rendered

    def view_image(self):
        if self.view is None:
            source = self.rendered_image()
            ratio = self.canvas.devicePixelRatioF() or 1.0
            width, height = round(self.canvas.width() * ratio), round(self.canvas.height() * ratio)
            if (width, height) == (source.width(), source.height()):
                view = QImage(source)
            else:
                view = source.scaled(width, height, Qt.AspectRatioMode.IgnoreAspectRatio,
                                     Qt.TransformationMode.SmoothTransformation)
            view.setDevicePixelRatio(ratio)
            self.view = view
        return self.view

    def flatten(self):
        return self.rendered_image()

    def to_image(self, event):
        position = event.position()
        return (position.x() / self.scale, position.y() / self.scale)

    def crop_rect(self):
        image = self.current.image
        return logic.rect_intersection(logic.rect_from_points(self.crop_start, self.crop_end),
                                       (0.0, 0.0, float(image.width()), float(image.height())))

    def canvas_down(self, event):
        if event.button() != Qt.MouseButton.LeftButton or self.current is None:
            return
        point = self.to_image(event)
        if self.tool == 'eraser':
            self.erasing = True
            self.erased = False
            self.erase_at(point)
        elif self.tool == 'crop':
            self.cropping = True
            self.crop_start = self.crop_end = point
            self.canvas.update()
        else:
            highlighter = self.tool == 'highlighter'
            color = QColor(self.highlight_color) if highlighter else QColor(self.pen_color)
            if highlighter:
                color.setAlpha(110)
            points = [point, point] if self.tool in ('rect', 'arrow') else [point]
            self.drawing = Shape(self.tool, color, WIDTHS[self.width_index][0] * (4 if highlighter else 1), points)
            self.canvas.update()

    def canvas_move(self, event):
        if self.current is None:
            return
        point = self.to_image(event)
        if self.drawing is not None:
            points = self.drawing.points
            if self.drawing.kind in ('rect', 'arrow'):
                points[1] = point
            else:
                last = points[-1]
                if abs(point[0] - last[0]) * self.scale < 1 and abs(point[1] - last[1]) * self.scale < 1:
                    return
                points.append(point)
            self.canvas.update()
        elif self.erasing:
            self.erase_at(point)
        elif self.cropping:
            self.crop_end = point
            self.canvas.update()

    def canvas_up(self, event):
        if event.button() != Qt.MouseButton.LeftButton or self.current is None:
            return
        if self.drawing is not None:
            shape, self.drawing = self.drawing, None
            if shape.kind in ('rect', 'arrow') and \
                    logic.segment_distance(shape.points[0], shape.points[1], shape.points[1]) * self.scale < 3:
                self.canvas.update()
                return
            self.push(State(self.current.image, self.current.shapes + [shape]))
        elif self.erasing:
            self.erasing = False
        elif self.cropping:
            self.cropping = False
            image = self.current.image
            area = logic.crop_area(self.crop_start, self.crop_end, image.width(), image.height())
            if area:
                self.apply_crop(area)
            else:
                self.canvas.update()

    def cancel_stroke(self):
        if self.cropping:
            self.cropping = False
            self.canvas.update()
        elif self.drawing is not None:
            self.drawing = None
            self.canvas.update()

    def erase_at(self, point):
        shapes = self.current.shapes
        for index in range(len(shapes) - 1, -1, -1):
            shape = shapes[index]
            if not logic.shape_hit(shape.kind, shape.points, shape.width, point, 6 / self.scale):
                continue
            state = State(self.current.image, shapes[:index] + shapes[index + 1:])
            if self.erased:
                self.current = state
                self.changed()
            else:
                self.erased = True
                self.push(state)
            return

    def apply_crop(self, area):
        image = self.current.image.copy(QRect(*area))
        if image.isNull():
            self.canvas.update()
            return
        shapes = [shape.moved(area[0], area[1]) for shape in self.current.shapes]
        self.push(State(image, shapes))
        self.update_layout()

    def paint_canvas(self, canvas, event):
        if self.current is None:
            return
        painter = QPainter(canvas)
        try:
            painter.drawImage(QPointF(0, 0), self.view_image())
            if self.drawing is not None:
                painter.save()
                painter.setRenderHint(QPainter.RenderHint.Antialiasing)
                painter.scale(self.scale, self.scale)
                draw_shape(painter, self.drawing)
                painter.restore()
            if self.cropping:
                rect = self.crop_rect()
                area = QRectF(*(value * self.scale for value in rect)) if rect else QRectF()
                region = QRegion(canvas.rect())
                if not area.isEmpty():
                    region = region.subtracted(QRegion(area.toAlignedRect()))
                painter.save()
                painter.setClipRegion(region)
                painter.fillRect(canvas.rect(), QColor(0, 0, 0, 120))
                painter.restore()
                if not area.isEmpty():
                    pen = QPen(WHITE, 1)
                    pen.setStyle(Qt.PenStyle.DashLine)
                    painter.setPen(pen)
                    painter.setBrush(Qt.BrushStyle.NoBrush)
                    painter.drawRect(area.adjusted(0, 0, -1, -1))
        finally:
            painter.end()

    def save(self):
        return self.save_to(self.file_path)

    def save_to(self, path):
        try:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            save_image(self.flatten(), path)
        except Exception as error:
            QMessageBox.warning(self, 'Snip', f'Could not save the snip:\n{error}')
            return False
        self.file_path = str(path)
        self.saved = self.current
        self.set_message(f'Saved: {path}')
        self.update_state()
        return True

    def save_as(self):
        png, jpeg = 'PNG image (*.png)', 'JPEG image (*.jpg)'
        path, chosen = QFileDialog.getSaveFileName(self, 'Save snip as', os.path.splitext(self.file_path)[0],
                                                   f'{png};;{jpeg}', jpeg if logic.is_jpeg(self.file_path) else png)
        if not path:
            return
        target = logic.snip_save_path(path, chosen == jpeg)
        if target != path and os.path.exists(target):
            answer = QMessageBox.question(self, 'Snip', f'{os.path.basename(target)} already exists. Replace it?')
            if answer != QMessageBox.StandardButton.Yes:
                return
        self.save_to(target)

    def copy(self):
        copied = copy_image(self.flatten())
        self.set_message('Copied to the clipboard.' if copied else
                         'Could not copy to the clipboard; another application may be using it.')

    def confirm_discard(self):
        if not self.modified():
            return True
        if not self.isVisible():
            self.show_editor()
        buttons = (QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No |
                   QMessageBox.StandardButton.Cancel)
        answer = QMessageBox.question(self, 'Snip', f'Save the changes to {os.path.basename(self.file_path)}?',
                                      buttons, QMessageBox.StandardButton.Yes)
        if answer == QMessageBox.StandardButton.Cancel:
            return False
        return answer == QMessageBox.StandardButton.No or self.save()

    def closeEvent(self, event):
        if self.prompt and not self.confirm_discard():
            event.ignore()
            return
        event.accept()
        self.closed.emit()


class SnipTool(QObject):
    hotkey = Signal(str)

    def __init__(self, controller):
        super().__init__()
        self.controller = controller
        self.paths = controller.paths
        self.snipping = False
        self.picker = None
        self.editors = []
        self.windows = None
        self.last_hotkey = 0.0
        self.active = []
        self.keys = []
        if IS_LINUX:
            self.keys = [(name, X11HotKeys(self.hotkey.emit, ((keysym, modifiers, 'snip'),), f'{name} snip hotkey', True,
                                           0x4D))
                         for name, keysym, modifiers in zip(KEY_NAMES, (0x73, 0xFF61), (0x41, 0))]
        elif IS_MAC:
            self.keys = [(KEY_NAMES[0], MacHotKeys(self.hotkey.emit, ((5, 1, 0x1800, 'snip'),), 'snip hotkey'))]
        self.hotkey.connect(self._hotkey)

    def unavailable(self):
        if IS_LINUX and (QGuiApplication.platformName() != 'xcb' or not os.environ.get('DISPLAY')):
            return 'Snipping needs an X11 session (Wayland is not supported).'
        return ''

    def exiting(self):
        return bool(self.controller.exit_requested or self.controller.finishing)

    def folder(self):
        return Path(self.controller.engine.record_dir) / 'Screenshots'

    def open_folder(self):
        folder = self.folder()
        folder.mkdir(parents=True, exist_ok=True)
        open_path(folder)

    def file_format(self):
        return logic.snip_format(get_setting(self.paths.settings, 'SnipFormat'))

    def editor_enabled(self):
        return get_setting(self.paths.settings, 'SnipEditor') is not False

    def key_wanted(self):
        return get_setting(self.paths.settings, 'SnipPrintScreen') is not False

    @property
    def key_enabled(self):
        return bool(self.active)

    def enable_key(self):
        if not self.keys or self.unavailable():
            return []
        failed = []
        for name, keys in self.keys:
            if name in self.active:
                continue
            if keys.enable():
                self.active.append(name)
                continue
            try:
                keys.disable()
            except Exception:
                pass
            failed.append(name)
        self.active.sort(key=KEY_NAMES.index)
        if failed:
            log(f'Could not register {" and ".join(failed)} to snip; the desktop or another application may be '
                'using it.')
        return failed

    def disable_key(self):
        self.active = []
        for name, keys in self.keys:
            try:
                keys.disable()
            except Exception as error:
                log(f'Could not release {name}: {error!r}')

    def set_key(self, enabled):
        set_setting(self.paths.settings, 'SnipPrintScreen', bool(enabled))
        if not enabled:
            self.disable_key()
            return
        failed = self.enable_key()
        if failed:
            self.controller.notify(f'Could not use {" and ".join(failed)} to snip; the desktop or another application '
                                   'may be using it.', 'warning')

    def _hotkey(self, name):
        now = time.monotonic()
        if now - self.last_hotkey < 0.4:
            return
        self.last_hotkey = now
        self.request('rect', delay=1)

    def request(self, mode='rect', editor=None, delay=250):
        if self.snipping or self.exiting():
            return
        reason = self.unavailable()
        if reason:
            self.controller.notify(reason, 'warning')
            return
        if editor is not None:
            if not editor.confirm_discard():
                return
            editor.hide()
        self.snipping = True
        QTimer.singleShot(max(1, delay), lambda: self._run(mode, editor))

    def _run(self, mode, editor):
        try:
            self.snip(mode, editor)
        except Exception:
            log('ERROR: snip: ' + traceback.format_exc())
        finally:
            self.snipping = False

    def mac_capture_allowed(self):
        try:
            graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
            graphics.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
            if graphics.CGPreflightScreenCaptureAccess():
                return True
            graphics.CGRequestScreenCaptureAccess.restype = ctypes.c_bool
            graphics.CGRequestScreenCaptureAccess()
        except Exception:
            return True
        self.controller.notify('Allow Scrcpy Monitor in System Settings > Privacy & Security > Screen Recording, '
                               'then snip again.', 'warning')
        return False

    def window_rects(self, shots, bounds):
        try:
            if IS_WINDOWS:
                from .screenrec import WinWindowList
                windows = WinWindowList()
                rects = [windows.window_rect(handle) for handle, _, _ in windows.list_windows()]
            else:
                if self.windows is None:
                    from .windowing import MacWindowList, X11Mover
                    if IS_MAC:
                        self.windows = MacWindowList()
                    else:
                        mover = X11Mover()
                        if not mover.available():
                            raise OSError(mover.reason)
                        self.windows = mover
                rects = self.windows.stacked_windows()
        except Exception as error:
            log(f'Could not list the windows to snip: {error!r}')
            return []
        if not IS_MAC:
            displays = [(shot.capture, shot.ratio) for shot in shots]
            rects = [logic.snip_native_to_logical(rect, displays) for rect in rects if rect]
        return logic.snip_window_rects(rects, _tuple(bounds))

    def capture(self, mode):
        if IS_MAC and not self.mac_capture_allowed():
            return None
        shots = [Shot(screen) for screen in QGuiApplication.screens() if not screen.geometry().isEmpty()]
        shots = [shot for shot in shots if not shot.image.isNull()]
        if not shots:
            log('Snip: could not capture the screen.')
            return None
        bounds = QRect()
        for shot in shots:
            bounds = bounds.united(shot.geometry)
        if mode == 'all' or (mode == 'screen' and len(shots) == 1):
            return compose(shots, bounds)
        picker = SnipPicker(shots, self.window_rects(shots, bounds), mode)
        self.picker = picker
        try:
            return picker.pick()
        finally:
            self.picker = None

    def snip(self, mode, editor):
        image = None
        try:
            image = self.capture(mode)
        finally:
            if image is None and editor is not None and editor in self.editors and not self.exiting():
                editor.show_editor()
        if image is None or self.exiting():
            return
        folder = self.folder()
        path = folder / logic.snip_file_name(datetime.now(), self.file_format())
        saved = True
        try:
            folder.mkdir(parents=True, exist_ok=True)
            save_image(image, path)
        except Exception as error:
            saved = False
            log(f'Could not save the snip to {path}: {error}')
        copied = copy_image(image)
        status = logic.snip_status(path, saved, copied)
        log(f'Snip: {status}')
        if editor is not None and editor in self.editors:
            editor.load_image(image, path, status)
            editor.show_editor()
        elif self.editor_enabled():
            self.show_editor(image, path, status)
        else:
            self.controller.notify(f'Snip: {status}', 'info' if saved or copied else 'warning')

    def show_editor(self, image, path, status):
        editor = SnipEditor(image, path, status, self.controller.icon)
        editor.new_snip.connect(lambda mode: self.request(mode, editor, 150))
        editor.closed.connect(lambda: self.editors.remove(editor) if editor in self.editors else None)
        self.editors.append(editor)
        editor.show_editor()

    def close_editors(self):
        for editor in list(self.editors):
            try:
                editor.prompt = False
                editor.close()
            except Exception as error:
                log(f'Could not close a snip editor: {error!r}')
        self.editors = []

    def shutdown(self):
        if self.picker is not None:
            self.picker.finish(None)
        self.close_editors()
        self.disable_key()
        if self.windows is not None and hasattr(self.windows, 'close'):
            try:
                self.windows.close()
            except Exception:
                pass
            self.windows = None

    def build_menu(self, menu):
        menu.clear()

        def add(text, function, checked=None, enabled=True):
            action = menu.addAction(text)
            action.setEnabled(enabled)
            if checked is not None:
                action.setCheckable(True)
                action.setChecked(checked)

            def run(*_):
                try:
                    function()
                except Exception:
                    log('ERROR: snip menu: ' + traceback.format_exc())
            action.triggered.connect(run)
            return action

        reason = self.unavailable()
        if reason:
            add(reason, lambda: None, enabled=False)
            return
        add('Snip an area' + (f'\t{self.active[0]}' if self.active else ''), lambda: self.request('rect'))
        add('Snip a window', lambda: self.request('window'))
        if len(QGuiApplication.screens()) > 1:
            add('Snip a screen', lambda: self.request('screen'))
            add('Snip all screens', lambda: self.request('all'))
        else:
            add('Snip full screen', lambda: self.request('all'))
        menu.addSeparator()
        file_format = self.file_format()
        add('Save snips as PNG', lambda: set_setting(self.paths.settings, 'SnipFormat', 'png'), file_format == 'png')
        add('Save snips as JPEG', lambda: set_setting(self.paths.settings, 'SnipFormat', 'jpg'), file_format == 'jpg')
        add('Open markup editor after snipping',
            lambda: set_setting(self.paths.settings, 'SnipEditor', not self.editor_enabled()), self.editor_enabled())
        if self.keys:
            add(f'Use {KEY_TEXT} to snip', lambda: self.set_key(not self.key_enabled), self.key_enabled)
        menu.addSeparator()
        add('Open snips folder', self.open_folder)
