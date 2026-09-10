#!/bin/sh
# Run via stdin in a disposable container, with networking disabled and no mounts.
set -eu
sh /usr/local/lib/noodle-image-check desktop
export DISPLAY=:99
# Test-only X server: loopback RFB, no web server or host-published ports.
Xvnc "$DISPLAY" -geometry 1024x768 -depth 24 -localhost -nolisten tcp \
  -publicIP 127.0.0.1 -noWebsocket -rfbport 5999 -SecurityTypes None \
  >/tmp/noodle-display-test.log 2>&1 &
display_pid=$!
trap 'kill "$display_pid" 2>/dev/null || true' EXIT
attempt=0
until xdpyinfo >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 10 ]; then
    cat /tmp/noodle-display-test.log >&2
    exit 1
  fi
  sleep 0.5
done
feh --no-fehbg --bg-fill /usr/share/backgrounds/desktop-wallpaper.svg
xprop -root _XROOTPMAP_ID | grep -q 'PIXMAP'
# Check rendered pixels, not just whether feh accepted the SVG. XGetImage reads
# the isolated guest framebuffer; it never captures the user's host desktop.
python3 - <<'PY'
import ctypes as c
import os
import struct
import subprocess as sp
import time
import zlib

x = c.CDLL('libX11.so.6')
x.XOpenDisplay.argtypes = [c.c_char_p]
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XGetImage.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_int,
                       c.c_uint, c.c_uint, c.c_ulong, c.c_int]
x.XGetImage.restype = c.c_void_p
x.XGetPixel.argtypes = [c.c_void_p, c.c_int, c.c_int]
x.XGetPixel.restype = c.c_ulong
x.XDestroyImage.argtypes = [c.c_void_p]
x.XCloseDisplay.argtypes = [c.c_void_p]
display = x.XOpenDisplay(None)
assert display, 'No test display'
snapshot = x.XGetImage(display, x.XDefaultRootWindow(display), 0, 0,
                       1024, 768, c.c_ulong(-1), 2)
assert snapshot, 'No wallpaper framebuffer'
try:
    colours = [x.XGetPixel(snapshot, px, py)
               for py in (100, 380, 650) for px in (100, 500, 900)]
    assert len(set(colours)) >= 4, 'Wallpaper did not render its gradients/ribbons'
    rgb = [(v >> shift) & 255 for v in colours for shift in (16, 8, 0)]
    assert sum(rgb) / len(rgb) > 120, 'Wallpaper unexpectedly dark or blank'
finally:
    x.XDestroyImage(snapshot)
    x.XCloseDisplay(display)
print('PASS: desktop wallpaper renders as a bright, non-blank framebuffer')

# Exercise the real panel and terminal, not just their configuration files.
processes = []
def geometry(name):
    window = sp.check_output(['xdotool', 'search', '--onlyvisible', '--name', name], text=True).splitlines()[-1]
    fields = sp.check_output(['xdotool', 'getwindowgeometry', '--shell', window], text=True)
    return {key: int(value) for key, value in (line.split('=') for line in fields.splitlines())}

try:
    log = open('/tmp/noodle-theme-test.log', 'w')
    processes.append(sp.Popen(['openbox'], stdout=log, stderr=log))
    time.sleep(1)
    processes.append(sp.Popen(['tint2', '-c', '/etc/xdg/tint2/tint2rc'], stdout=log, stderr=log))
    processes.append(sp.Popen(['kitty', '--config', '/etc/xdg/kitty/theme.conf',
                              '--title', 'Noodle Theme Verification',
                              '-o', 'initial_window_width=640', '-o', 'initial_window_height=420',
                              '-o', 'window_padding_width=8', '-o', 'cursor_blink_interval=0',
                              '/bin/sh', '-c', 'printf "Noodle Computer\\nBlack terminal. Rounded panel.\\n"; sleep 60'],
                             env={**os.environ, 'LIBGL_ALWAYS_SOFTWARE': '1'}, stdout=log, stderr=log))
    for attempt in range(30):
        try:
            panel, terminal = geometry('^tint2$'), geometry('^Noodle Theme Verification$')
            break
        except sp.CalledProcessError:
            time.sleep(0.5)
    else:
        raise AssertionError('Panel or terminal did not appear')
    time.sleep(2)
    display = x.XOpenDisplay(None)
    snapshot = x.XGetImage(display, x.XDefaultRootWindow(display), 0, 0, 1024, 768, c.c_ulong(-1), 2)
    def pixel(px, py):
        value = x.XGetPixel(snapshot, px, py)
        return tuple((value >> shift) & 255 for shift in (16, 8, 0))
    assert max(pixel(panel['X'] + panel['WIDTH'] // 2, panel['Y'] + 18)) < 30, 'Panel must remain black'
    for px in (panel['X'], panel['X'] + panel['WIDTH'] - 1):
        assert min(pixel(px, panel['Y'])) > 80, 'Panel corner must reveal the wallpaper, not a square black corner'
    assert max(pixel(terminal['X'] + terminal['WIDTH'] // 2,
                     terminal['Y'] + terminal['HEIGHT'] // 2)) < 10, 'Terminal background must be black'
    # Save the guest framebuffer for visual review, without capturing the host.
    rows = b''.join(b'\x00' + bytes(channel for px in range(1024) for channel in pixel(px, py)) for py in range(768))
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1024, 768, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
    with open('/tmp/noodle-desktop-theme.png', 'wb') as output:
        output.write(png)
    x.XDestroyImage(snapshot)
    x.XCloseDisplay(display)
    print('PASS: real terminal is black and both panel corners are rounded')
finally:
    for process in reversed(processes):
        process.terminate()
    for process in processes:
        process.wait(timeout=5)
PY
