#!/usr/bin/env python3
"""Exercise the signed app through its shipped CLI. Run in a logged-in desktop."""
import json
import http.server
import threading
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
app = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/Noodle Applet.app'
cli = app / 'Contents/Helpers/noodlet'
output = root / '.build/applet/smoke'
output.mkdir(parents=True, exist_ok=True)
sessions, imported = [], []


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


def package(directory, name, runtime, source):
    path = directory / (name + '.noodlet')
    path.mkdir()
    entry = 'index.html' if runtime == 'html' else 'Main.swift'
    (path / 'noodlet.json').write_text(json.dumps(dict(version=1, title='Applet smoke ' + name, runtime=runtime, entry=entry, network=False)))
    (path / entry).write_text(source)
    return path


def track(reply):
    if reply.get('sessionID'):
        sessions.append(reply['sessionID'])
    if reply.get('path'):
        imported.append(pathlib.Path(reply['path']))
    return reply['sessionID']


try:
    with tempfile.TemporaryDirectory(prefix='noodlet-smoke-') as temporary:
        directory = pathlib.Path(temporary)
        html = package(directory, 'HTML', 'html', '''<!doctype html><title>Smoke</title>
        <style>body{background:#123456;color:white;font:30px system-ui}button{padding:25px}</style>
        <button id="go" onclick="this.textContent='Clicked';console.log('clicked')">Start</button>
        <canvas id="canvas" width="300" height="120"></canvas>
        <script>const ctx=canvas.getContext('2d');let t=0;setInterval(()=>{ctx.fillStyle=`hsl(${t++*5},80%,60%)`;ctx.fillRect(0,0,300,120)},80);console.log('ready');</script>''')
        sid = track(call('open', html, '--mode', 'headless'))
        alias = directory / 'Alias.noodlet'
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
        for name in ['web.png', 'web.mp4', 'native.png']:
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
            api = package(directory, 'Network', 'html', '<title>Network test</title><h1>API</h1>')
            manifest = json.loads((api/'noodlet.json').read_text()); manifest['network'] = True
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
            assert 'network: true' in denied['error'], denied
            call('terminate', '--session', local)
            viewport = json.loads(call('inspect', '--session', network)['value'])['viewport']
            assert viewport == dict(width=320,height=350), viewport
            call('terminate', '--session', network)
            print('PASS native CORS-free GET, binary POST, redirects, abort, network denial and manifest viewport', flush=True)
        finally: server.shutdown(); server.server_close()


        # A failed compilation must preserve structured session identity and diagnostics.
        broken = package(directory, 'Broken', 'swift', 'import SwiftUI\nstruct Noodlet: View { var body: some View { DefinitelyMissing() } }')
        bad = call('build', broken, success=False)
        failed_id = track(bad)
        assert 'DefinitelyMissing' in call('logs', '--session', failed_id)['text']
        print('PASS native compiler diagnostics and session recovery', flush=True)

        # Probe containment using a harmless file that this test owns outside the app container.
        secret = directory / 'outside.txt'
        secret.write_text('must not be readable by the native runtime')
        swift = package(directory, 'Native', 'swift', '''import SwiftUI
        struct Noodlet: View {var body: some View {Text("Native smoke").padding(60).onAppear {
            do { _ = try String(contentsOfFile: %s, encoding: .utf8); print("SANDBOX_ESCAPE") }
            catch { print("SANDBOX_DENIED") }
        }}}''' % json.dumps(str(secret)).replace('\\/', '/'))
        built = track(call('build', swift))
        assert call('status', '--session', built)['state'] == 'built'
        native = track(call('open', swift, '--mode', 'headless'))
        assert call('status', '--session', native)['state'] == 'running'
        viewport = json.loads(call('inspect', '--session', native)['value'])['viewport']
        assert viewport == {'width': 900, 'height': 620}, viewport
        logs = call('logs', '--session', native)['text']
        assert 'SANDBOX_DENIED' in logs and 'SANDBOX_ESCAPE' not in logs, logs
        call('screenshot', '--session', native, '--output', output / 'native.png')
        assert (output / 'native.png').read_bytes().startswith(b'\x89PNG')
        call('terminate', '--session', native)
        print('PASS native execution, capture and denied outside-file access', flush=True)
        manifest = json.loads((swift / 'noodlet.json').read_text())
        manifest['window'] = dict(type='preview', background='translucent', width=360, height=320, minWidth=360, maxWidth=360, minHeight=320, maxHeight=320, resizable=False, rememberFrame=True)
        (swift / 'noodlet.json').write_text(json.dumps(manifest))
        panel = track(call('open', swift, '--mode', 'headless'))
        viewport = json.loads(call('inspect', '--session', panel)['value'])['viewport']
        assert viewport == dict(width=360,height=320), viewport
        call('terminate', '--session', panel)
        print('PASS native preview panel and manifest sizing', flush=True)

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
    # Only remove imports made from this invocation's ephemeral fixtures.
    for path in set(imported):
        if path.suffix == '.noodlet' and '/NoodleApplet/Noodlets/Imports/' in str(path):
            shutil.rmtree(path, ignore_errors=True)

print('Signed Applet smoke checks passed. Captures:', output)
