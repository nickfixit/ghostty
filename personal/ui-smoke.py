#!/usr/bin/env python3
"""Exercise the personal picker on an isolated Xvfb display and session bus.

Requires system Python with gi/Atspi and Pillow, Xvfb, dbus-run-session.
Never connects to or sends input to the user's desktop.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

if "--session" not in sys.argv:
    display = ":197"
    server = subprocess.Popen(["Xvfb", display, "-screen", "0", "1200x900x24", "-nolisten", "tcp"])
    try:
        time.sleep(1)
        if server.poll() is not None:
            raise RuntimeError("Private Xvfb could not start; refusing to use an existing display")
        env = dict(os.environ, DISPLAY=display, GDK_BACKEND="x11", GTK_A11Y="atspi", LIBGL_ALWAYS_SOFTWARE="1", QT_QPA_PLATFORM="xcb")
        env.pop("WAYLAND_DISPLAY", None)
        sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, __file__, "--session"], env=env))
    finally:
        server.terminate()
        server.wait()

import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio

# openSUSE's accessibility service delegates registry activation to systemd;
# this isolated bus has no user systemd, so launch its registry explicitly.
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
address = bus.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", None, None, Gio.DBusCallFlags.NONE, 10000, None).unpack()[0]
os.environ["AT_SPI_BUS_ADDRESS"] = address
registry = subprocess.Popen(["/usr/libexec/at-spi2/at-spi2-registryd"], env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))

ROOT = Path(__file__).resolve().parents[1]
log = open("/tmp/ghostty-ui.log", "w")
app = subprocess.Popen([
    str(ROOT / "zig-out/bin/ghostty"), "--config-default-files=false",
    "--gtk-single-instance=false", "--window-decoration=client", "--theme=Nord",
    "--background-opacity=1", "--unfocused-split-opacity=1", "--window-width=100", "--window-height=30",
    "--confirm-close-surface=false", "--command=/bin/bash --noprofile --norc",
], cwd=ROOT, stdout=log, stderr=log)

def walk(node, depth=0):
    yield node, depth
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child:
            yield from walk(child, depth + 1)

def find(name, role=None):
    for n, _ in walk(Atspi.get_desktop(0)):
        if n.get_name() == name and (role is None or n.get_role_name() == role):
            return n
    raise AssertionError(f"Missing widget: {name} ({role})")

def click(name, role=None):
    n = find(name, role)
    a = n.get_action_iface()
    assert a and a.get_n_actions(), f"No action: {name}"
    assert a.do_action(0)
    time.sleep(0.5)

def dump():
    for n, d in walk(Atspi.get_desktop(0)):
        print(" " * d, n.get_role_name(), repr(n.get_name()), flush=True)

# Only this private Xvfb display receives synthetic keys.
import ctypes
x11 = ctypes.CDLL("libX11.so.6")
xtst = ctypes.CDLL("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XStringToKeysym.restype = ctypes.c_ulong
x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XFlush.argtypes = [ctypes.c_void_p]
xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
display = x11.XOpenDisplay(os.environ["DISPLAY"].encode())
assert display
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x11.XDefaultRootWindow.restype = ctypes.c_ulong
x11.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
x11.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
x11.XFree.argtypes = [ctypes.c_void_p]

def focus_window():
    root, parent = ctypes.c_ulong(), ctypes.c_ulong()
    children = ctypes.POINTER(ctypes.c_ulong)()
    count = ctypes.c_uint()
    x11.XQueryTree(display, x11.XDefaultRootWindow(display), ctypes.byref(root), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
    found = False
    for window in list(children[:count.value]):
        name = ctypes.c_char_p()
        x11.XFetchName(display, window, ctypes.byref(name))
        if name.value:
            title = name.value.decode(errors="replace")
            if str(ROOT) in title:
                x11.XSetInputFocus(display, window, 2, 0)
                found = True
            x11.XFree(name)
    x11.XFree(children)
    x11.XFlush(display)
    assert found, "Ghostty test window not found"

def keys(*names):
    codes = [x11.XKeysymToKeycode(display, x11.XStringToKeysym(n.encode())) for n in names]
    for code in codes:
        xtst.XTestFakeKeyEvent(display, code, 1, 0)
    for code in reversed(codes):
        xtst.XTestFakeKeyEvent(display, code, 0, 0)
    x11.XFlush(display)
    time.sleep(1)

def pick(name, current="Use configured theme", apply=True):
    click("Main Menu", "toggle button")
    click("", "menu item")  # Theme picker is the first main-menu item.
    click(current, "toggle button")
    assert find("", "entry").get_editable_text_iface().set_text_contents(name)
    time.sleep(0.7)
    find(name, "label")  # Search must actually filter to the requested item.
    # Xvfb test window is fixed at 1000x630. GTK's popup accessibility
    # coordinates are local to the popup, so click its visible first row.
    xtst.XTestFakeMotionEvent(display, -1, 420, 420, 0)
    xtst.XTestFakeButtonEvent(display, 1, 1, 0)
    xtst.XTestFakeButtonEvent(display, 1, 0, 0)
    x11.XFlush(display)
    time.sleep(0.5)
    find(name, "combo box")
    click("Apply" if apply else "Cancel", "button")
    time.sleep(0.8)

def background(expected, point=(400, 300)):
    actual = ImageGrab.grab().getpixel(point)[:3]
    ImageGrab.grab().save("/tmp/ghostty-ui.png")
    assert actual == expected, (actual, expected)

try:
    for _ in range(60):
        time.sleep(0.5)
        nodes = list(walk(Atspi.get_desktop(0)))
        if any(n.get_name() == "Main Menu" for n, _ in nodes):
            break
        if app.poll() is not None:
            raise RuntimeError("Ghostty exited during startup")
    from PIL import ImageGrab
    focus_window()
    time.sleep(1)
    nord, dracula = (46, 52, 64), (40, 42, 54)
    background(nord)
    pick("Dracula")
    background(dracula)
    pick("Nord", "Dracula", apply=False)
    background(dracula)
    keys("Control_L", "Shift_L", "t")
    background(nord)
    keys("Control_L", "Page_Up")
    background(dracula)
    keys("Control_L", "Shift_L", "comma")
    background(dracula)
    pick("Use configured theme", "Dracula")
    background(nord)
    pick("Dracula")
    keys("Control_L", "Shift_L", "o")
    background(dracula, (200, 300))
    background(nord, (700, 300))
    ImageGrab.grab().save("/tmp/ghostty-ui.png")
    print("PASS: search, apply, cancel, independent tabs/splits, reload persistence, reset", flush=True)
finally:
    app.terminate()
    app.wait(timeout=10)
    registry.terminate()
    registry.wait(timeout=10)
