"""Offline native Claude regression: real tools and Seatbelt, synthetic API/login."""
import http.server
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import threading
import time
import uuid
import sys

HERE = Path(sys.argv[1]).resolve()
f = json.loads((HERE / 'fixture.json').read_text())
workspace = Path(f['workspace'])
config = Path(f['home']) / '.claude'
config.mkdir(parents=True, exist_ok=True)
session = f['session']
actions_sent = {}
original_configuration = Path(f['configuration']).read_bytes()
allowed = workspace / 'claude-written.txt'
requests = []
tool_results = []
state = {'stage': 0, 'resume': False}
stop = threading.Event()
mailbox = workspace / '.noodle/messenger-bridge'
mailbox.mkdir(parents=True, exist_ok=True)
(mailbox / 'session.json').write_text(json.dumps({'token': 'offline-fixture', 'processID': os.getpid()}))

def mailbox_worker():
    while not stop.wait(.03):
        for path in mailbox.glob('*.request'):
            try:
                request = json.loads(path.read_text())
                assert request['session'] == 'offline-fixture'
                response = {'exitCode': 0, 'standardOutput': '[]\n', 'standardError': ''}
                path.with_suffix('.response').write_text(json.dumps(response))
                path.unlink()
            except (OSError, ValueError):
                pass

class API(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        requests.append({'path': self.path, 'model': body.get('model'), 'tools': [x['name'] for x in body.get('tools', [])]})
        for message in body.get('messages', []):
            for block in message.get('content', []) if isinstance(message.get('content'), list) else []:
                if block.get('type') == 'tool_result':
                    tool_results.append(block)
        if 'count_tokens' in self.path:
            self.json_response({'input_tokens': 100})
            return
        if not self.path.startswith('/v1/messages'):
            self.json_response({})
            return
        if not body.get('tools'):
            content = [{'type': 'text', 'text': 'Offline fixture'}]
        else:
            actions = [
                ('Write', {'file_path': str(allowed), 'content': 'WORKSPACE_OK\n'}),
                ('Read', {'file_path': str(allowed)}),
                ('Read', {'file_path': f['outside']}),
                ('Write', {'file_path': f['configuration'], 'content': 'FORBIDDEN_CHANGE'}),
                ('Bash', {'command': 'printf SHELL_OK > shell-written.txt; /bin/cat claude-written.txt', 'description': 'Exercise workspace shell'}),
                ('Bash', {'command': '/bin/cat ' + shlex.quote(f['outside']), 'description': 'Check denied fixture read'}),
                ('Bash', {'command': shlex.quote(f['messenger']) + ' --agent-directory ' + shlex.quote(str(workspace)) + ' --list-conversations', 'description': 'Exercise local Messenger CLI'}),
            ] if not state['resume'] else [('Read', {'file_path': str(allowed)})]
            stage = state['stage']
            state['stage'] += 1
            if stage < len(actions):
                name, arguments = actions[stage]
                tool_id = ('resume_' if state['resume'] else 'initial_') + str(stage)
                actions_sent[tool_id] = name
                content = [{'type': 'tool_use', 'id': tool_id, 'name': name, 'input': arguments}]
            else:
                content = [{'type': 'text', 'text': 'RESUME_DONE' if state['resume'] else 'FIXTURE_DONE'}]
        message = {'id': 'msg_' + str(uuid.uuid4()), 'type': 'message', 'role': 'assistant',
            'model': body.get('model', 'claude-sonnet-4-6'), 'content': content,
            'stop_reason': 'tool_use' if content[0]['type'] == 'tool_use' else 'end_turn',
            'stop_sequence': None, 'usage': {'input_tokens': 100, 'output_tokens': 20}}
        if not body.get('stream'):
            self.json_response(message)
            return
        events = [('message_start', {'type': 'message_start', 'message': dict(message, content=[], stop_reason=None)})]
        for index, block in enumerate(content):
            initial = dict(block)
            if block['type'] == 'tool_use':
                initial['input'] = {}
                delta = {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}
            else:
                initial['text'] = ''
                delta = {'type': 'text_delta', 'text': block['text']}
            events.extend([
                ('content_block_start', {'type': 'content_block_start', 'index': index, 'content_block': initial}),
                ('content_block_delta', {'type': 'content_block_delta', 'index': index, 'delta': delta}),
                ('content_block_stop', {'type': 'content_block_stop', 'index': index})])
        events.extend([
            ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': message['stop_reason'], 'stop_sequence': None}, 'usage': {'output_tokens': 20}}),
            ('message_stop', {'type': 'message_stop'})])
        payload = ''.join('event: ' + kind + '\ndata: ' + json.dumps(data) + '\n\n' for kind, data in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def json_response(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

api = http.server.ThreadingHTTPServer(('127.0.0.1', 0), API)
threading.Thread(target=api.serve_forever, daemon=True).start()
threading.Thread(target=mailbox_worker, daemon=True).start()
environment = dict(f['environment'], PATH='/usr/bin:/bin:/usr/sbin:/sbin',
    TMPDIR=f['temporary'], TMPPREFIX=f['temporary'] + '/zsh', USER=os.environ.get('USER', ''),
    ANTHROPIC_API_KEY='sk-ant-offline-fixture', ANTHROPIC_BASE_URL='http://127.0.0.1:' + str(api.server_port),
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL='1',
    API_TIMEOUT_MS='10000')
base = ['/usr/bin/sandbox-exec', '-f', f['policy'], f['executable']]

def run(arguments, data=None):
    child = subprocess.Popen(base + arguments, cwd=workspace, env=environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        output, error = child.communicate(data, timeout=45)
        return child.returncode, output, error
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

summary = {}
try:
    # Verify the exact private credential file produced by Swift's storage code.
    api_key = environment.pop('ANTHROPIC_API_KEY')
    code, output, error = run(['auth', 'status'])
    auth = json.loads(output)
    assert code == 0 and auth.get('loggedIn') and auth.get('authMethod') == 'claude.ai', (code, output, error)
    (config / '.credentials.json').unlink()
    code, output, error = run(['auth', 'status'])
    assert not json.loads(output).get('loggedIn'), (code, output, error)
    summary['private_oauth_recognized'] = True
    environment['ANTHROPIC_API_KEY'] = api_key
    code, output, error = run(['--version'])
    summary['version'] = {'exit': code, 'output': output.strip(), 'stderr': error.strip()}
    for name, resume in [('initial', False), ('resume', True)]:
        state.update(stage=0, resume=resume)
        arguments = f['resumeArguments' if resume else 'arguments']
        user = {'type': 'user', 'message': {'role': 'user', 'content': 'Run the offline sandbox fixture.'}}
        code, output, error = run(arguments, json.dumps(user) + '\n')
        (HERE / (name + '.jsonl')).write_text(output)
        (HERE / (name + '.stderr')).write_text(error)
        events = [json.loads(line) for line in output.splitlines() if line.startswith('{')]
        summary[name] = {'exit': code, 'event_types': [e.get('type') for e in events],
            'results': [e for e in events if e.get('type') == 'result'],
            'initialized': any(e.get('type') == 'system' and e.get('subtype') == 'init' for e in events),
            'tools': next((e.get('tools') for e in events if e.get('subtype') == 'init'), None),
            'stderr': error.strip()}
        print(name + ': exit ' + str(code), flush=True)
        if code != 0:
            break
    summary['workspace_write'] = allowed.exists() and allowed.read_text() == 'WORKSPACE_OK\n'
    summary['shell_write'] = (workspace / 'shell-written.txt').exists()
    summary['configuration_unchanged'] = Path(f['configuration']).read_bytes() == original_configuration
    # The tool call includes the marker file's path, never its private contents.
    summary['outside_marker_not_returned'] = 'OUTSIDE_PRIVATE_MARKER' not in json.dumps(tool_results)
    summary['requests'] = requests
    summary['tool_results'] = tool_results
finally:
    stop.set()
    api.shutdown()
    (HERE / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps({k: v for k, v in summary.items() if k not in ['requests', 'tool_results', 'initial', 'resume']}, indent=2))

assert summary['version']['exit'] == 0, summary['version']
for name in ['initial', 'resume']:
    result = summary[name]
    assert result['exit'] == 0 and result['initialized'], result
    assert len(result['results']) == 1 and not result['results'][0]['is_error'], result
    assert result['results'][0]['session_id'] == session, result
    assert {'Bash', 'Read', 'Write', 'Edit', 'Skill', 'WebFetch', 'WebSearch'} <= set(result['tools']), result['tools']
    init = next(e for e in map(json.loads, (HERE / (name + '.jsonl')).read_text().splitlines()) if e.get('subtype') == 'init')
    assert {'messenger', 'applet'} <= set(init.get('skills', [])), init.get('skills')
for key in ['workspace_write', 'shell_write', 'configuration_unchanged', 'outside_marker_not_returned']:
    assert summary[key], key
results = {block['tool_use_id']: block for block in tool_results}
assert set(results) == set(actions_sent), (set(results), set(actions_sent))
for key in ['initial_0', 'initial_1', 'initial_4', 'initial_6', 'resume_0']:
    assert not results[key].get('is_error'), results[key]
for key in ['initial_2', 'initial_3', 'initial_5']:
    assert results[key].get('is_error'), results[key]
    assert any(word in str(results[key]) for word in ['EPERM', 'Operation not permitted']), results[key]
assert '[]' in str(results['initial_6']), results['initial_6']
print('PASS: native startup, private OAuth discovery, tools, Messenger, outside denials, session resume')
