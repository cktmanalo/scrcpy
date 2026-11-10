import ctypes
import ctypes.util
import os
import sys
from ctypes import POINTER, byref, c_bool, c_char, c_char_p, c_double, c_float, c_int, c_int32, c_long, c_ubyte, \
    c_uint, c_uint32, c_ulong, c_void_p

MAC_TITLE_BAR_HEIGHT = 28
WESTON_SHADOW_MARGIN = 32


class Window:
    __slots__ = ('handle', 'outer', 'client', 'client_origin')

    def __init__(self, handle, outer, client, client_origin=None):
        self.handle = handle
        self.outer = outer
        self.client = client
        self.client_origin = client_origin


class NoMover:
    def __init__(self, reason=''):
        self.reason = reason

    def available(self):
        return False

    def request_access(self):
        pass

    def find_windows(self, pids):
        return {}

    def move(self, window, rect):
        pass

    def close(self):
        pass


def create_mover():
    try:
        if sys.platform == 'darwin':
            return MacMover()
        if sys.platform.startswith('linux'):
            return X11Mover()
    except Exception as error:
        return NoMover(f'window control is unavailable ({error})')
    return NoMover('not supported on this system')


def _area(window):
    return window.client[0] * window.client[1]


class XWindowAttributes(ctypes.Structure):
    _fields_ = [('x', c_int), ('y', c_int), ('width', c_int), ('height', c_int), ('border_width', c_int),
                ('depth', c_int), ('visual', c_void_p), ('root', c_ulong), ('class_', c_int),
                ('bit_gravity', c_int), ('win_gravity', c_int), ('backing_store', c_int),
                ('backing_planes', c_ulong), ('backing_pixel', c_ulong), ('save_under', c_int),
                ('colormap', c_ulong), ('map_installed', c_int), ('map_state', c_int),
                ('all_event_masks', c_long), ('your_event_mask', c_long), ('do_not_propagate_mask', c_long),
                ('override_redirect', c_int), ('screen', c_void_p)]


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [('type', c_int), ('serial', c_ulong), ('send_event', c_int), ('display', c_void_p),
                ('window', c_ulong), ('message_type', c_ulong), ('format', c_int), ('data', c_long * 5)]


class XEvent(ctypes.Union):
    _fields_ = [('xclient', XClientMessageEvent), ('pad', c_long * 24)]


X_ERROR_HANDLER = ctypes.CFUNCTYPE(c_int, c_void_p, c_void_p)


class X11Mover:
    def __init__(self):
        self.reason = ''
        self.lib = None
        self.display = None
        self.root = 0
        self.shadow = 0
        self.previous_handler = None
        if not os.environ.get('DISPLAY'):
            self.reason = 'no X11 display; windows can only be arranged on X11 or XWayland'
            return
        lib = ctypes.CDLL(ctypes.util.find_library('X11') or 'libX11.so.6')
        lib.XOpenDisplay.argtypes = [c_char_p]
        lib.XOpenDisplay.restype = c_void_p
        lib.XCloseDisplay.argtypes = [c_void_p]
        lib.XDefaultRootWindow.argtypes = [c_void_p]
        lib.XDefaultRootWindow.restype = c_ulong
        lib.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]
        lib.XInternAtom.restype = c_ulong
        lib.XGetWindowProperty.argtypes = [c_void_p, c_ulong, c_ulong, c_long, c_long, c_int, c_ulong,
                                           POINTER(c_ulong), POINTER(c_int), POINTER(c_ulong), POINTER(c_ulong),
                                           POINTER(POINTER(c_ubyte))]
        lib.XFree.argtypes = [c_void_p]
        lib.XQueryTree.argtypes = [c_void_p, c_ulong, POINTER(c_ulong), POINTER(c_ulong),
                                   POINTER(POINTER(c_ulong)), POINTER(c_uint)]
        lib.XGetWindowAttributes.argtypes = [c_void_p, c_ulong, POINTER(XWindowAttributes)]
        lib.XTranslateCoordinates.argtypes = [c_void_p, c_ulong, c_ulong, c_int, c_int, POINTER(c_int),
                                              POINTER(c_int), POINTER(c_ulong)]
        lib.XMoveResizeWindow.argtypes = [c_void_p, c_ulong, c_int, c_int, c_uint, c_uint]
        lib.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_long, POINTER(XEvent)]
        lib.XSync.argtypes = [c_void_p, c_int]
        lib.XSetErrorHandler.argtypes = [c_void_p]
        lib.XSetErrorHandler.restype = c_void_p
        self.lib = lib
        self.ignore_errors = X_ERROR_HANDLER(lambda display, event: 0)
        self.atoms = {}

    def available(self):
        return self.lib is not None

    def request_access(self):
        pass

    def _open(self):
        if self.display:
            return
        display = self.lib.XOpenDisplay(None)
        if not display:
            raise OSError('cannot open the X11 display')
        self.display = display
        self.atoms = {}
        self.previous_handler = self.lib.XSetErrorHandler(ctypes.cast(self.ignore_errors, c_void_p))
        self.root = self.lib.XDefaultRootWindow(display)
        check = self._cardinals(self.root, '_NET_SUPPORTING_WM_CHECK')
        self.shadow = WESTON_SHADOW_MARGIN if check and self._text(check[0], '_NET_WM_NAME') == 'Weston WM' else 0

    def close(self):
        if not self.display:
            return
        display, self.display = self.display, None
        self.lib.XSync(display, 0)
        self.lib.XSetErrorHandler(self.previous_handler)
        self.lib.XCloseDisplay(display)

    def _atom(self, name):
        if name not in self.atoms:
            self.atoms[name] = self.lib.XInternAtom(self.display, name.encode(), 0)
        return self.atoms[name]

    def _property(self, window, name, size):
        actual_type, actual_format = c_ulong(), c_int()
        count, after, data = c_ulong(), c_ulong(), POINTER(c_ubyte)()
        status = self.lib.XGetWindowProperty(self.display, window, self._atom(name), 0, 1024, 0, 0,
                                             byref(actual_type), byref(actual_format), byref(count), byref(after),
                                             byref(data))
        if status != 0 or not data:
            return None
        try:
            if actual_format.value != size:
                return None
            if size == 8:
                return ctypes.string_at(data, count.value)
            values = ctypes.cast(data, POINTER(c_ulong))
            return [values[i] for i in range(count.value)]
        finally:
            self.lib.XFree(data)

    def _cardinals(self, window, name):
        return self._property(window, name, 32) or []

    def _text(self, window, name):
        return (self._property(window, name, 8) or b'').decode('utf-8', 'replace')

    def _children(self, window):
        root, parent, children, count = c_ulong(), c_ulong(), POINTER(c_ulong)(), c_uint()
        if not self.lib.XQueryTree(self.display, window, byref(root), byref(parent), byref(children), byref(count)):
            return [], 0
        try:
            return [children[i] for i in range(count.value)], parent.value
        finally:
            if children:
                self.lib.XFree(children)

    def _toplevel(self, window):
        for _ in range(16):
            _, parent = self._children(window)
            if not parent or parent == self.root:
                return window
            window = parent
        return window

    def find_windows(self, pids):
        self._open()
        wanted = set(pids)
        found = {}
        level = [self.root]
        for _ in range(3):
            following = []
            for parent in level:
                children, _ = self._children(parent)
                following += children
            for window in following:
                pid = self._cardinals(window, '_NET_WM_PID')
                if not pid or pid[0] not in wanted:
                    continue
                info = self._measure(window)
                if info and (pid[0] not in found or _area(info) > _area(found[pid[0]])):
                    found[pid[0]] = info
            level = following
        return found

    def _measure(self, window):
        attributes = XWindowAttributes()
        if not self.lib.XGetWindowAttributes(self.display, window, byref(attributes)):
            return None
        if attributes.map_state != 2 or attributes.override_redirect or attributes.width < 2 or attributes.height < 2:
            return None
        states = set(self._cardinals(window, '_NET_WM_STATE'))
        if (self._atom('_NET_WM_STATE_HIDDEN') in states or self._atom('_NET_WM_STATE_FULLSCREEN') in states
                or {self._atom('_NET_WM_STATE_MAXIMIZED_VERT'), self._atom('_NET_WM_STATE_MAXIMIZED_HORZ')} <= states):
            return None
        x, y, child = c_int(), c_int(), c_ulong()
        if not self.lib.XTranslateCoordinates(self.display, window, self.root, 0, 0, byref(x), byref(y), byref(child)):
            return None
        width, height = attributes.width, attributes.height
        extents = self._cardinals(window, '_NET_FRAME_EXTENTS')
        if len(extents) == 4 and max(extents) < 500:
            left, right, top, bottom = (max(0, value - self.shadow) for value in extents)
            outer = (x.value - left, y.value - top, width + left + right, height + top + bottom)
        else:
            frame = XWindowAttributes()
            top_window = self._toplevel(window)
            if top_window != window and self.lib.XGetWindowAttributes(self.display, top_window, byref(frame)):
                border = 2 * frame.border_width
                outer = (frame.x, frame.y, frame.width + border, frame.height + border)
            else:
                outer = (x.value, y.value, width, height)
        return Window(window, outer, (width, height), (x.value, y.value))

    def move(self, window, rect):
        x, y, width, height = rect
        outer_x, outer_y, outer_width, outer_height = window.outer
        client_width = max(1, width - (outer_width - window.client[0]))
        client_height = max(1, height - (outer_height - window.client[1]))
        if self._atom('_NET_MOVERESIZE_WINDOW') in self._cardinals(self.root, '_NET_SUPPORTED'):
            event = XEvent()
            message = event.xclient
            message.type = 33
            message.send_event = 1
            message.window = window.handle
            message.message_type = self._atom('_NET_MOVERESIZE_WINDOW')
            message.format = 32
            message.data[0] = 10 | 0xF00 | (2 << 12)
            message.data[1] = x + window.client_origin[0] - outer_x
            message.data[2] = y + window.client_origin[1] - outer_y
            message.data[3] = client_width
            message.data[4] = client_height
            self.lib.XSendEvent(self.display, self.root, 0, (1 << 19) | (1 << 20), byref(event))
        else:
            self.lib.XMoveResizeWindow(self.display, window.handle, x, y, client_width, client_height)


class CGPoint(ctypes.Structure):
    _fields_ = [('x', c_double), ('y', c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [('width', c_double), ('height', c_double)]


class MacMover:
    ATTRIBUTES = ('AXWindows', 'AXPosition', 'AXSize', 'AXMinimized', 'AXFullScreen')

    def __init__(self):
        self.reason = ''
        ax = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        ax.AXIsProcessTrusted.restype = c_bool
        ax.AXIsProcessTrustedWithOptions.argtypes = [c_void_p]
        ax.AXIsProcessTrustedWithOptions.restype = c_bool
        ax.AXUIElementCreateApplication.argtypes = [c_int]
        ax.AXUIElementCreateApplication.restype = c_void_p
        ax.AXUIElementSetMessagingTimeout.argtypes = [c_void_p, c_float]
        ax.AXUIElementSetMessagingTimeout.restype = c_int32
        ax.AXUIElementCopyAttributeValue.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
        ax.AXUIElementCopyAttributeValue.restype = c_int32
        ax.AXUIElementSetAttributeValue.argtypes = [c_void_p, c_void_p, c_void_p]
        ax.AXUIElementSetAttributeValue.restype = c_int32
        ax.AXValueCreate.argtypes = [c_uint32, c_void_p]
        ax.AXValueCreate.restype = c_void_p
        ax.AXValueGetValue.argtypes = [c_void_p, c_uint32, c_void_p]
        ax.AXValueGetValue.restype = c_bool
        cf.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
        cf.CFStringCreateWithCString.restype = c_void_p
        cf.CFRelease.argtypes = [c_void_p]
        cf.CFRetain.argtypes = [c_void_p]
        cf.CFRetain.restype = c_void_p
        cf.CFGetTypeID.argtypes = [c_void_p]
        cf.CFGetTypeID.restype = c_ulong
        cf.CFArrayGetTypeID.restype = c_ulong
        cf.CFBooleanGetTypeID.restype = c_ulong
        cf.CFArrayGetCount.argtypes = [c_void_p]
        cf.CFArrayGetCount.restype = c_long
        cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
        cf.CFArrayGetValueAtIndex.restype = c_void_p
        cf.CFBooleanGetValue.argtypes = [c_void_p]
        cf.CFBooleanGetValue.restype = c_bool
        cf.CFDictionaryCreate.argtypes = [c_void_p, c_void_p, c_void_p, c_long, c_void_p, c_void_p]
        cf.CFDictionaryCreate.restype = c_void_p
        self.ax, self.cf = ax, cf
        self.strings = {name: cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
                        for name in self.ATTRIBUTES}
        self.retained = []

    def available(self):
        if self.ax.AXIsProcessTrusted():
            self.reason = ''
            return True
        self.reason = ('allow Scrcpy Monitor in System Settings > Privacy & Security > Accessibility, '
                       'then arrange the windows again')
        return False

    def request_access(self):
        try:
            key = c_void_p.in_dll(self.ax, 'kAXTrustedCheckOptionPrompt').value
            value = c_void_p.in_dll(self.cf, 'kCFBooleanTrue').value
            keys, values = (c_void_p * 1)(key), (c_void_p * 1)(value)
            options = self.cf.CFDictionaryCreate(
                None, keys, values, 1, ctypes.addressof(c_char.in_dll(self.cf, 'kCFTypeDictionaryKeyCallBacks')),
                ctypes.addressof(c_char.in_dll(self.cf, 'kCFTypeDictionaryValueCallBacks')))
            if options:
                try:
                    self.ax.AXIsProcessTrustedWithOptions(options)
                finally:
                    self.cf.CFRelease(options)
        except (OSError, ValueError, AttributeError):
            pass

    def _copy(self, element, name):
        value = c_void_p()
        if self.ax.AXUIElementCopyAttributeValue(element, self.strings[name], byref(value)) != 0:
            return None
        return value.value

    def _flag(self, element, name):
        value = self._copy(element, name)
        if not value:
            return False
        try:
            return self.cf.CFGetTypeID(value) == self.cf.CFBooleanGetTypeID() and self.cf.CFBooleanGetValue(value)
        finally:
            self.cf.CFRelease(value)

    def _value(self, element, name, kind, structure):
        value = self._copy(element, name)
        if not value:
            return None
        try:
            result = structure()
            return result if self.ax.AXValueGetValue(value, kind, byref(result)) else None
        finally:
            self.cf.CFRelease(value)

    def find_windows(self, pids):
        found = {}
        for pid in pids:
            app = self.ax.AXUIElementCreateApplication(pid)
            if not app:
                continue
            try:
                self.ax.AXUIElementSetMessagingTimeout(app, 1.0)
                windows = self._copy(app, 'AXWindows')
                if not windows:
                    continue
                try:
                    if self.cf.CFGetTypeID(windows) != self.cf.CFArrayGetTypeID():
                        continue
                    for index in range(self.cf.CFArrayGetCount(windows)):
                        element = self.cf.CFArrayGetValueAtIndex(windows, index)
                        if not element:
                            continue
                        self.ax.AXUIElementSetMessagingTimeout(element, 1.0)
                        info = self._measure(element)
                        if info and (pid not in found or _area(info) > _area(found[pid])):
                            self.retained.append(self.cf.CFRetain(element))
                            found[pid] = info
                finally:
                    self.cf.CFRelease(windows)
            finally:
                self.cf.CFRelease(app)
        return found

    def _measure(self, element):
        if not element or self._flag(element, 'AXMinimized') or self._flag(element, 'AXFullScreen'):
            return None
        position = self._value(element, 'AXPosition', 1, CGPoint)
        size = self._value(element, 'AXSize', 2, CGSize)
        if not position or not size:
            return None
        width, height = round(size.width), round(size.height)
        if width < 2 or height <= MAC_TITLE_BAR_HEIGHT + 1:
            return None
        return Window(element, (round(position.x), round(position.y), width, height),
                      (width, height - MAC_TITLE_BAR_HEIGHT))

    def move(self, window, rect):
        x, y, width, height = rect
        point, size = CGPoint(x, y), CGSize(width, height)
        position_value = self.ax.AXValueCreate(1, byref(point))
        size_value = self.ax.AXValueCreate(2, byref(size))
        try:
            if size_value:
                self.ax.AXUIElementSetAttributeValue(window.handle, self.strings['AXSize'], size_value)
            if position_value:
                self.ax.AXUIElementSetAttributeValue(window.handle, self.strings['AXPosition'], position_value)
            if size_value:
                self.ax.AXUIElementSetAttributeValue(window.handle, self.strings['AXSize'], size_value)
        finally:
            for value in (position_value, size_value):
                if value:
                    self.cf.CFRelease(value)

    def close(self):
        retained, self.retained = self.retained, []
        for element in retained:
            if element:
                self.cf.CFRelease(element)
