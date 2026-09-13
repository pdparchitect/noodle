#!/bin/bash
# Disposable guest only: no networking, host mounts, real accounts or credentials.
set -euo pipefail
export DISPLAY=:99 XAUTHORITY=/run/launcher-desktop/Xauthority
mkdir -p /run/launcher-desktop /run/user/1000 /var/log/launcher-desktop
chown agent:agent /run/launcher-desktop /run/user/1000 /var/log/launcher-desktop
chmod 700 /run/user/1000
touch "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" . "$(openssl rand -hex 16)"
chown agent:agent "$XAUTHORITY"
chmod 600 "$XAUTHORITY"

cleanup() {
    pkill -u agent -x chromium 2>/dev/null || true
    for pid in ${bus_pid:-} ${window_pid:-} ${display_pid:-}; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
Xvnc "$DISPLAY" -geometry 1024x768 -depth 24 -localhost -nolisten tcp \
    -auth "$XAUTHORITY" -publicIP 127.0.0.1 -noWebsocket -rfbport 5999 \
    -SecurityTypes None >/tmp/noodle-browser-display.log 2>&1 &
display_pid=$!
for attempt in $(seq 1 40); do
    if xdpyinfo >/dev/null 2>&1; then break; fi
    sleep 0.25
done
xdpyinfo >/dev/null
runuser -u agent -- openbox >/tmp/noodle-browser-openbox.log 2>&1 &
window_pid=$!
# Use the real Secret Service so persisted encrypted cookies are exercised.
runuser -u agent -- env HOME=/home/agent XDG_RUNTIME_DIR=/run/user/1000 \
    dbus-run-session -- /bin/sh -c '
        set -e
        printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" > /run/launcher-desktop/dbus-session-address
        desktop-keyring
        touch /run/launcher-desktop/test-keyring-ready
        exec sleep 300
    ' >/tmp/noodle-browser-keyring.log 2>&1 &
bus_pid=$!
for attempt in $(seq 1 40); do
    if [ -e /run/launcher-desktop/test-keyring-ready ]; then break; fi
    sleep 0.25
done
test -e /run/launcher-desktop/test-keyring-ready

node <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const { spawn, execFileSync } = require('node:child_process');
const { once } = require('node:events');
const puppeteer = require('/opt/noodle-browser/node_modules/puppeteer-core');
const { connect } = require('/opt/noodle-browser');

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(action, description) {
  const deadline = Date.now() + 30_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const result = await action();
      if (result) return result;
    } catch (error) { lastError = error; }
    await delay(200);
  }
  throw new Error('Timed out: ' + description, { cause: lastError });
}

const processes = [];
const log = fs.openSync('/tmp/noodle-browser-test.log', 'w');
function launch(program, args) {
  const child = spawn(program, args, { stdio: ['ignore', log, log] });
  child.on('error', error => { console.error(error); });
  processes.push(child);
  return child;
}
const server = http.createServer((request, response) => {
  if (request.url === '/login') {
    response.setHeader('Set-Cookie', 'noodle_session=fixture; HttpOnly; SameSite=Lax; Max-Age=3600; Path=/');
  }
  const signedIn = (request.headers.cookie || '').includes('noodle_session=fixture');
  response.setHeader('Content-Type', 'text/html');
  response.end('<title>Noodle Browser Fixture</title><h1>' +
    (signedIn ? 'Signed in' : 'Sign in') + '</h1><button onclick="this.textContent=\'Automated\'">Continue</button>');
});

(async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    // Seed a prior desktop profile, then shut it down before the first migration.
    const legacyProcess = launch('runuser', ['-u', 'agent', '--', 'env',
      'HOME=/home/agent',
      'DBUS_SESSION_BUS_ADDRESS=' + fs.readFileSync('/run/launcher-desktop/dbus-session-address', 'utf8').trim(),
      '/usr/local/lib/noodle-chromium-base',
      '--user-data-dir=/home/agent/.config/chromium', '--remote-debugging-port=9333',
      '--remote-debugging-address=127.0.0.1', url + '/login']);
    browser = await until(() => puppeteer.connect({ browserURL: 'http://127.0.0.1:9333', defaultViewport: null }), 'legacy browser');
    const legacyPage = await until(async () => (await browser.pages()).find(page => page.url() === url + '/login'), 'legacy login tab');
    await legacyPage.waitForSelector('h1');
    await legacyPage.evaluate(() => localStorage.setItem('noodle_fixture', 'preserved'));
    assert.throws(() => execFileSync('chromium', [], { stdio: 'pipe' }), error =>
      error.status === 1 && error.stderr.toString().includes('Close existing Chromium windows'));
    assert.ok(!fs.existsSync('/home/agent/.config/noodle-browser'), 'never copy an active legacy profile');
    await browser.close();
    browser = null;
    await until(() => legacyProcess.exitCode !== null, 'legacy browser shutdown');

    // The exact product session hook opens the visible browser as agent.
    launch('runuser', ['-u', 'agent', '--', '/etc/desktop/session.d/noodle-browser']);
    browser = await until(connect, 'desktop browser');
    const endpoint = browser.wsEndpoint();
    assert.throws(() => execFileSync('chromium', ['--headless'], { stdio: 'pipe' }), error => error.status === 2);
    const listeners = execFileSync('ss', ['-H', '-ltn'], { encoding: 'utf8' })
      .split('\n').filter(line => /:9222\s/.test(line)).map(line => line.trim().split(/\s+/)[3]);
    assert.deepEqual(listeners, ['127.0.0.1:9222'], 'CDP must listen only on guest IPv4 loopback');

    // A native/provider-style root shell must open its URL in the SAME browser.
    const rootLaunch = launch('/usr/bin/env', ['-i',
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME=/root', 'DISPLAY=:99', 'chromium', url + '/account']);
    await until(() => rootLaunch.exitCode !== null, 'second browser launch');
    assert.equal(rootLaunch.exitCode, 0);
    let page = await until(async () => (await browser.pages()).find(page => page.url() === url + '/account'), 'shared account tab');
    await page.waitForSelector('h1');
    assert.equal(await page.$eval('h1', element => element.textContent), 'Signed in', 'migrated cookie');
    assert.equal(await page.evaluate(() => localStorage.getItem('noodle_fixture')), 'preserved');
    assert.equal(page.viewport(), null, 'attaching must not resize the desktop viewport');
    execFileSync('xdotool', ['search', '--onlyvisible', '--name', 'Noodle Browser Fixture']);
    const browserPids = execFileSync('pgrep', ['-x', 'chromium'], { encoding: 'utf8' }).trim().split('\n');
    for (const pid of browserPids) {
      assert.match(fs.readFileSync(`/proc/${pid}/status`, 'utf8'), /^Uid:\s+1000\s+1000\s+1000\s+1000$/m);
    }
    await page.click('button');
    assert.equal(await page.$eval('button', element => element.textContent), 'Automated');
    await browser.disconnect();
    browser = await connect();
    assert.equal(browser.wsEndpoint(), endpoint, 'disconnect must leave the browser alive');
    page = (await browser.pages()).find(page => page.url() === url + '/account');
    assert.equal(await page.$eval('button', element => element.textContent), 'Automated', 'same live tab');
    console.log('PASS: visible browser, migrated login, root/desktop share tabs, loopback CDP, disconnect preserves session');

    // Only this disposable test closes the browser; production scripts disconnect.
    await browser.close();
    browser = null;
    await until(() => {
      try { execFileSync('pgrep', ['-x', 'chromium'], { stdio: 'ignore' }); return false; }
      catch { return true; }
    }, 'browser shutdown');
    await assert.rejects(connect, /Cannot attach to the Noodle desktop browser/);
    launch('chromium', [url + '/account']);
    browser = await until(connect, 'reopened browser');
    page = await until(async () => (await browser.pages()).find(page => page.url() === url + '/account'), 'reopened account tab');
    await page.waitForSelector('h1');
    assert.equal(await page.$eval('h1', element => element.textContent), 'Signed in', 'login survives browser restart');
    assert.equal(await page.evaluate(() => localStorage.getItem('noodle_fixture')), 'preserved');
    assert.ok(fs.existsSync('/home/agent/.config/chromium/Default/Cookies'), 'original profile remains intact');
    console.log('PASS: saved login and local storage survive browser restart; unavailable browser reports a useful error');
  } finally {
    if (browser) await browser.close().catch(() => {});
    for (const child of processes) if (child.exitCode === null) child.kill();
    server.close();
    fs.closeSync(log);
  }
})().catch(error => {
  console.error(error);
  console.error(fs.readFileSync('/tmp/noodle-browser-test.log', 'utf8'));
  console.error(fs.readFileSync('/var/log/launcher-desktop/browser.log', 'utf8'));
  process.exitCode = 1;
});
JS
