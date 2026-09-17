#!/usr/bin/env python3
"""Local, fake-account fixture. No real credentials or external websites."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import io
import wave
import sys
from pathlib import Path

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Browser verification</title>
<style>body{font:20px system-ui;background:#eee9dd;color:#152450;padding:40px}button,input{font:inherit;margin:12px;padding:12px}h1{color:#1259ff}</style>
<h1>Noodle Browser verification</h1><form id="login"><input id="username" autocomplete="off"><button id="sign-in">Sign in</button></form>
<button id="click" onclick="this.dataset.count=String(Number(this.dataset.count||0)+1)">Click counter</button>
<input id="file" type="file"><input id="key" onkeydown="this.dataset.key=event.key">
<button id="blob" onclick="const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['noodle-download-contents'],{type:'text/plain'}));a.download='report.txt';a.click()">Download</button>
<button id="popup" onclick="window.open('/popup')">Popup</button><button id="confirm" onclick="setTimeout(()=>{window.dialogResult=confirm('Confirm fixture')},10)">Confirm</button>
<iframe src="/frame" title="Embedded fixture"></iframe>
<script>document.querySelector('#login').onsubmit=async e=>{e.preventDefault();await fetch('/login',{method:'POST'});localStorage.setItem('remembered','yes');document.body.dataset.signedIn='yes'};</script>'''

silent = io.BytesIO()
with wave.open(silent, 'wb') as audio:
    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
    audio.writeframes(bytes(16000))
SILENT_AUDIO = silent.getvalue()

POINTER_PAGE = b'''<!doctype html><meta charset="utf-8"><title>Virtual pointer fixture</title>
<style>
body{font:18px system-ui;margin:40px;color:#153247;background:#eff5f7}
button{font:inherit;padding:14px;border:1px solid #638997;border-radius:10px;background:white}
#menu{display:inline-block;padding:20px;background:#d1e7eb;border-radius:16px}
#menu-button{display:none}#menu:hover #menu-button{display:block}
#menu:hover{background:#9fd8e5}
#drag{margin-top:25px;width:360px;height:90px;background:#184e64;color:white;border-radius:14px;touch-action:none;padding:20px}
#covered{position:absolute;left:650px;top:300px}#cover{position:absolute;left:640px;top:290px;width:180px;height:100px;background:#999}
iframe{display:block;width:500px;height:100px;margin-top:25px;border:2px solid #184e64}
</style>
<h1>Agent pointer</h1><div id="menu">Hover to reveal<button id="menu-button">Revealed action</button></div>
<button id="click">Click / double click</button><button id="away">Move away</button>
<div id="drag">The cyan marker shows where the agent is pointing.</div><button id="covered">Covered target</button><div id="cover"></div>
<iframe id="same" src="/pointer-frame"></iframe>
<script>
window.events=[];window.clicks=0;window.doubles=0;window.menuClicks=0;
for(const type of ['pointerover','pointerenter','pointermove','pointerout','pointerleave','pointerdown','pointerup','mousemove','mousedown','mouseup','click','dblclick'])
document.addEventListener(type,e=>events.push({type,target:e.target.id,trusted:e.isTrusted,x:e.clientX,y:e.clientY,buttons:e.buttons}),true);
document.querySelector('#click').onclick=()=>clicks++;
document.querySelector('#click').ondblclick=()=>doubles++;
document.querySelector('#menu-button').onclick=()=>menuClicks++;
const cross=document.createElement('iframe');cross.id='cross';cross.src=location.origin.replace('127.0.0.1','localhost')+'/pointer-frame';document.body.append(cross);
</script>'''
POINTER_FRAME = b'''<!doctype html><meta charset="utf-8"><style>body{margin:8px}button{padding:15px}button:hover{background:rgb(0, 200, 100)}</style>
<button id="frame-button">Frame hover and click</button><script>window.clicks=0;document.querySelector('button').onclick=()=>clicks++;</script>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        if self.path != '/login': self.send_error(404); return
        self.send_response(200)
        self.send_header('Set-Cookie', 'fixture_login=authenticated; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax')
        self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'OK')
    def do_GET(self):
        if self.path in ['/webmcp', '/webmcp-blocked', '/webmcp-domain']:
            data = Path(__file__).with_name('webmcp.html').read_bytes().replace(b'PORT', str(self.server.server_port).encode()); mime = 'text/html'
        elif self.path == '/webmcp-frame':
            data = b'''<title>WebMCP frame</title><script>document.modelContext?.registerTool({name:'frame_echo',description:'Frame tool',execute:()=>location.origin});</script>'''; mime = 'text/html'
        elif self.path.startswith('/webmcp-result'):
            data = b'<title>WebMCP result</title><p id="webmcp-result">Form navigated</p>'; mime = 'text/html'
        elif self.path == '/silent.wav': data = SILENT_AUDIO; mime = 'audio/wav'
        elif self.path == '/pointer': data = POINTER_PAGE; mime = 'text/html'
        elif self.path == '/pointer-frame': data = POINTER_FRAME; mime = 'text/html'
        elif self.path == '/auth-state':
            data = json.dumps({'authenticated': 'fixture_login=authenticated' in self.headers.get('Cookie','')}).encode()
            mime = 'application/json'
        elif self.path == '/frame': data = b'<title>Frame</title><p id="frame-text">Frame control works</p>'; mime = 'text/html'
        elif self.path == '/popup': data = b'<title>Popup</title><p>Popup profile</p>'; mime = 'text/html'
        else: data = PAGE; mime = 'text/html'
        self.send_response(200); self.send_header('Content-Type', mime); self.send_header('Content-Length', str(len(data)))
        if self.path == '/webmcp-blocked': self.send_header('Permissions-Policy', 'tools=()')
        if self.path == '/webmcp-domain': self.send_header('Origin-Agent-Cluster', '?0')
        self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv)>1 else 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
