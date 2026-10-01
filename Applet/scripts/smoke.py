#!/usr/bin/env python3
"""Exercise the signed app through its shipped CLI. Run in a logged-in desktop."""
import json
import hashlib
import http.server
import threading
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
app = (pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/Noodle Applet Dev.app').resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
bundle_id = info['CFBundleIdentifier']
assert bundle_id in ['com.pdparchitect.noodle.applet', 'com.pdparchitect.noodle.applet.local']
extension = '.noodlet-dev' if bundle_id.endswith('.local') else '.noodlet'
cli = app / 'Contents/Helpers/noodlet'
output = root / '.build/applet/smoke'
output.mkdir(parents=True, exist_ok=True)
sessions = []


def call(*args, success=True):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True, timeout=195)
    try:
        reply = json.loads(result.stdout)
    except ValueError:
        raise AssertionError((args, result.stdout, result.stderr))
    if success and (result.returncode or reply.get('error')):
        if reply.get('sessionID'):
            track(reply)
            logs = subprocess.run([str(cli), 'logs', '--session', reply['sessionID'], '--text-output'], capture_output=True, text=True, timeout=35)
            print(logs.stdout[-8000:], flush=True)
        raise AssertionError((args, reply, result.stderr))
    if not success:
        assert result.returncode == 1 and reply.get('error'), reply
    return reply


def package(directory, name, source):
    path = directory / (name + extension)
    path.mkdir()
    (path / 'noodlet.json').write_text(json.dumps(dict(version=1, title='Applet smoke ' + name, runtime='html', entry='index.html')))
    (path / 'index.html').write_text(source)
    # Applet uses only noodlets it lists, so open this one in the app as a person would, then
    # close what that opened so the checks start from a headless session of their own.
    subprocess.run(['open', '-g', '-a', app, path], check=True, timeout=30)
    for _ in range(150):
        item = next((item for item in call('list').get('items', [])
                     if pathlib.Path(item['path']).resolve() == path.resolve()), None)
        if item and item.get('sessionID'):
            call('terminate', '--session', item['sessionID'])
            return path
        time.sleep(.2)
    raise AssertionError(('not listed after opening in the app', path))


def launch(directory):
    # Agrees to local-network for the Network noodlet as the person would, without the question
    # that would hold a headless run: arguments take precedence over the app's saved settings.
    # Applet keys a noodlet by its resolved path, less the /private that /var leads to.
    resolved = str(directory.resolve() / ('Network' + extension))
    if resolved.startswith('/private/') and pathlib.Path(resolved[len('/private'):]).parent.exists():
        resolved = resolved[len('/private'):]
    executable = str(app / 'Contents/MacOS' / info['CFBundleExecutable'])
    subprocess.run(['pkill', '-f', executable], timeout=30)
    for _ in range(150):
        if subprocess.run(['pgrep', '-f', executable], capture_output=True).returncode: break
        time.sleep(.2)
    else:
        raise AssertionError(('still running', executable))
    granted = '-permissions.' + hashlib.sha256(resolved.encode()).hexdigest()
    subprocess.run(['open', '-g', '-a', app, '--args', granted, '(local-network)'], check=True, timeout=30)


def track(reply):
    if reply.get('sessionID'):
        sessions.append(reply['sessionID'])
    return reply['sessionID']


try:
    with tempfile.TemporaryDirectory(prefix='noodlet-smoke-') as temporary:
        directory = pathlib.Path(temporary)
        launch(directory)
        html = package(directory, 'HTML', '''<!doctype html><title>Smoke</title>
        <style>body{background:#123456;color:white;font:30px system-ui}button{padding:25px}</style>
        <button id="go" onclick="this.textContent='Clicked';console.log('clicked')">Start</button>
        <canvas id="canvas" width="300" height="120"></canvas>
        <script>const ctx=canvas.getContext('2d');let t=0;setInterval(()=>{ctx.fillStyle=`hsl(${t++*5},80%,60%)`;ctx.fillRect(0,0,300,120)},80);console.log('ready');</script>''')
        sid = track(call('open', html, '--mode', 'headless'))
        alias = directory / ('Alias' + extension)
        alias.symlink_to(html, target_is_directory=True)
        assert call('open', alias, '--mode', 'headless')['sessionID'] == sid
        call('click', '--session', sid, '--target', '#go')
        assert json.loads(call('eval', '--session', sid, '--text', 'return go.textContent;')['value']) == 'Clicked'
        assert 'clicked' in call('logs', '--session', sid)['text']
        call('eval', '--session', sid, '--text', 'await noodle.storage.set("test",42); return true;')
        call('eval', '--session', sid, '--text', 'await noodle.data.writeText("../escape","bad");', success=False)
        call('eval', '--session', sid, '--text', 'setTimeout(()=>{throw Error("smoke exception")},0); return true;')
        time.sleep(.2)
        assert 'smoke exception' in call('logs', '--session', sid)['text']
        for name in ['web.png', 'web.mp4']:
            (output / name).unlink(missing_ok=True)
        call('screenshot', '--session', sid, '--output', output / 'web.png')
        assert (output / 'web.png').read_bytes().startswith(b'\x89PNG')
        call('record', 'start', '--session', sid, '--duration', '2')
        time.sleep(2.2)
        call('record', 'stop', '--session', sid, '--output', output / 'web.mp4')
        assert (output / 'web.mp4').stat().st_size > 1000
        sid = track(call('restart', '--session', sid))
        assert json.loads(call('eval', '--session', sid, '--text', 'return await noodle.storage.get("test");')['value']) == 42
        call('terminate', '--session', sid)
        assert call('status', '--session', sid)['state'] == 'stopped'
        print('PASS HTML interaction, logs, persistence, canonical lock, PNG and MP4', flush=True)

        class API(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                if self.path == '/slow': time.sleep(3)
                if self.path == '/redirect':
                    self.send_response(302); self.send_header('Location', '/data'); self.end_headers(); return
                self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
                try: self.wfile.write(b'{"cors":"native","value":42}')
                except BrokenPipeError: pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                self.send_response(201); self.send_header('Content-Type','application/octet-stream'); self.end_headers(); self.wfile.write(body)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        address = 'http://127.0.0.1:' + str(server.server_port)
        try:
            api = package(directory, 'Network', '<title>Network test</title><h1>API</h1>')
            manifest = json.loads((api/'noodlet.json').read_text()); manifest['permissions'] = ['local-network']
            manifest['window'] = dict(type='floating', background='translucent', width=320, height=350, minWidth=260, minHeight=300, maxWidth=480, maxHeight=520, resizable=False, rememberFrame=True)
            (api/'noodlet.json').write_text(json.dumps(manifest))
            network = track(call('open', api, '--mode', 'headless'))
            value = json.loads(call('eval', '--session', network, '--text', 'return await (await fetch('+json.dumps(address+'/data')+')).json();')['value'])
            assert value == dict(cors='native', value=42), value
            source = 'const r=await noodle.fetch('+json.dumps(address+'/echo')+', {method:"POST",headers:{"X-Test":"no-preflight"},body:new Uint8Array([0,128,255])}); return {status:r.status,bytes:[...new Uint8Array(await r.arrayBuffer())]};'
            assert json.loads(call('eval', '--session', network, '--text', source)['value']) == dict(status=201, bytes=[0,128,255])
            assert json.loads(call('eval', '--session', network, '--text', 'return (await fetch('+json.dumps(address+'/redirect')+')).redirected;')['value']) is True
            source = 'try { await fetch('+json.dumps(address+'/slow')+',{signal:AbortSignal.timeout(100)});return "missed"; } catch(e) {return e.name;}'
            assert json.loads(call('eval', '--session', network, '--text', source)['value']) == 'AbortError'
            local = track(call('open', html, '--mode', 'headless'))
            denied = call('eval', '--session', local, '--text', 'return await fetch('+json.dumps(address+'/data')+');', success=False)
            assert 'local-network' in denied['error'], denied
            call('terminate', '--session', local)
            viewport = json.loads(call('inspect', '--session', network)['value'])['viewport']
            assert viewport == dict(width=320,height=350), viewport
            call('terminate', '--session', network)
            print('PASS native CORS-free GET, binary POST, redirects, abort, network denial and manifest viewport', flush=True)
        finally: server.shutdown(); server.server_close()


        # Termination must break an outstanding unresponsive WebKit operation.
        hung = track(call('open', html, '--mode', 'headless'))
        blocked = subprocess.Popen([str(cli), 'eval', '--session', hung, '--text', 'while(true) {}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(.5)
        call('terminate', '--session', hung)
        blocked.communicate(timeout=10)
        assert blocked.returncode == 1
        print('PASS termination of blocked JavaScript', flush=True)
finally:
    for sid in sessions:
        try:
            call('terminate', '--session', sid)
        except Exception:
            pass
    # Applet allows one copy, so leave none running for the check that follows.
    running = str(app / 'Contents/MacOS') + '/'
    subprocess.run(['pkill', '-f', running])
    for _ in range(50):
        if subprocess.run(['pgrep', '-f', running], capture_output=True).returncode:
            break
        time.sleep(.2)
    else:
        raise AssertionError(('still running after the checks', app))

print('Signed Applet smoke checks passed. Captures:', output)
