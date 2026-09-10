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
PY
