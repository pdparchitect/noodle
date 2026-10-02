#!/usr/bin/env python3
"""Run the signed app's runtime checks against a local HTTP server. Run in a logged-in desktop.

The sandboxed app cannot listen, so this serves the endpoints its network checks reach and passes
their address to the check. The app is launched through LaunchServices, in the background, as in
test-rendering.sh; open does not pass on the app's exit status, so the check's last line decides."""
import http.server
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

root = pathlib.Path(__file__).resolve().parents[2]
app = (pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/Noodle Applet Dev.app').resolve()


class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == '/slow': time.sleep(3)
        if self.path == '/redirect':
            self.send_response(302); self.send_header('Location', '/data'); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        try: self.wfile.write(b'{"cors":"native","value":42}')
        except BrokenPipeError: pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(201); self.send_header('Content-Type', 'application/octet-stream'); self.end_headers(); self.wfile.write(body)


# Applet allows one copy, and open would wait on a running one rather than start the check.
if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS') + '/'], capture_output=True).returncode == 0:
    sys.exit(f'Quit {app} first: it is already running.')
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.NamedTemporaryFile(prefix='applet-smoke', suffix='.log') as log:
        subprocess.run(['open', '-g', '-n', '-W', '--stdout', log.name, '--stderr', log.name, '-a', str(app),
                        '--args', '--noodle-background', '--smoke-test', f'http://127.0.0.1:{server.server_port}'],
                       check=True, timeout=420)
        output = pathlib.Path(log.name).read_text()
finally:
    server.shutdown(); server.server_close()
print(output, end='')
lines = output.strip().splitlines()
assert lines and lines[-1] == 'APPLET SMOKE TEST PASSED', 'Applet smoke checks failed'
