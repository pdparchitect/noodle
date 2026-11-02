// Node runs src/index.ts directly (type stripping, Node 22.18 and later): npm test.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import test from 'node:test'
import vm from 'node:vm'
import worker, { SCRIPT, STYLE } from '../src/index.ts'

const ORIGIN = 'https://embed.usenoodle.app'
const get = (path, method = 'GET') => worker.fetch(new Request(ORIGIN + path, { method }))
const hash = (text) => `'sha256-${createHash('sha256').update(text).digest('base64')}'`

test('serves the YouTube page for a valid id', async () => {
  const response = await get('/youtube?v=dQw4w9WgXcQ&t=42&autoplay=1')
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8')
  const body = await response.text()
  assert.match(body, /<div id="p" data-v="dQw4w9WgXcQ" data-t="42" data-autoplay="1"><\/div>/)
  assert.ok(body.includes(`<script>${SCRIPT}</script>`))
  assert.ok(body.includes("host: 'https://www.youtube-nocookie.com'"))
})

test('does not autoplay unless asked', async () => {
  for (const query of ['', '&autoplay=0']) {
    const body = await (await get(`/youtube?v=dQw4w9WgXcQ${query}`)).text()
    assert.match(body, /data-t="0" data-autoplay="0"/, query)
  }
})

test('refuses ids, times and autoplay values it does not accept', async () => {
  for (const query of ['', 'v=', 'v=short', 'v=dQw4w9WgXcQx', 'v=dQw4w9WgXc%22', 'v=dQw4w9WgX%3Cs',
                       'v=dQw4w9WgXcQ&t=-1', 'v=dQw4w9WgXcQ&t=1.5', 'v=dQw4w9WgXcQ&t=1m30s', 'v=dQw4w9WgXcQ&t=1234567890',
                       'v=dQw4w9WgXcQ&autoplay=true', 'v=dQw4w9WgXcQ&autoplay=']) {
    const response = await get(`/youtube?${query}`)
    assert.equal(response.status, 400, query)
    assert.equal(response.headers.get('cache-control'), 'no-store', query)
  }
})

test('answers nothing but GET and HEAD /youtube', async () => {
  for (const path of ['/', '/youtube/', '/YouTube?v=dQw4w9WgXcQ', '/vimeo?v=dQw4w9WgXcQ', '/youtube.html']) {
    assert.equal((await get(path)).status, 404, path)
  }
  for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH']) {
    assert.equal((await get('/youtube?v=dQw4w9WgXcQ', method)).status, 404, method)
  }
  const head = await get('/youtube?v=dQw4w9WgXcQ', 'HEAD')
  assert.equal(head.status, 200)
  assert.equal(await head.text(), '')
  assert.ok(head.headers.get('content-security-policy'))
})

test('sends a strict policy that allows only the YouTube player', async () => {
  const headers = (await get('/youtube?v=dQw4w9WgXcQ')).headers
  const policy = Object.fromEntries(headers.get('content-security-policy').split('; ').map((directive) => {
    const [name, ...values] = directive.split(' ')
    return [name, values]
  }))
  assert.deepEqual(policy, {
    'default-src': ["'none'"],
    'script-src': [hash(SCRIPT), 'https://www.youtube.com', 'https://s.ytimg.com'],
    'style-src': [hash(STYLE)],
    'frame-src': ['https://www.youtube-nocookie.com'],
    'object-src': ["'none'"],
    'base-uri': ["'none'"],
    'form-action': ["'none'"],
  })
  assert.equal(headers.get('referrer-policy'), 'strict-origin')
  assert.equal(headers.get('x-content-type-options'), 'nosniff')
  assert.equal(headers.get('cache-control'), 'public, max-age=86400')
  assert.equal(headers.get('set-cookie'), null)
  assert.equal(headers.get('x-frame-options'), null)
  const permissions = headers.get('permissions-policy')
  for (const feature of ['autoplay', 'fullscreen', 'encrypted-media', 'picture-in-picture']) {
    assert.ok(permissions.includes(`${feature}=(self "https://www.youtube-nocookie.com")`), feature)
  }
  for (const feature of ['camera', 'microphone', 'geolocation']) {
    assert.ok(permissions.includes(`${feature}=()`), feature)
  }
})

test('the page script still checks the id itself', () => {
  assert.ok(SCRIPT.includes('const ID = /^[A-Za-z0-9_-]{11}$/;'))
  assert.ok(SCRIPT.includes("if (e.source !== parent"))
})

test('the page obeys only well-formed commands from its parent', () => {
  const calls = []
  let listener
  const parent = { postMessage: () => {} }
  const context = {
    parent,
    location: { origin: ORIGIN },
    document: {
      getElementById: () => ({ dataset: { v: 'dQw4w9WgXcQ', t: '0', autoplay: '0' } }),
      createElement: () => ({}),
      head: { appendChild: () => {} },
    },
    addEventListener: (type, handler) => { if (type === 'message') listener = handler },
    setInterval: () => 0,
    clearInterval: () => {},
    YT: { Player: class {
      loadVideoById(options) { calls.push(['load', options]) }
      seekTo(seconds) { calls.push(['seek', seconds]) }
    } },
  }
  context.window = context
  vm.runInNewContext(SCRIPT, context)
  context.onYouTubeIframeAPIReady()
  const post = (data, source = parent) => listener({ source, data: { source: 'noodle-embed', ...data } })

  post({ cmd: 'load', v: ['dQw4w9WgXcQ'] })
  post({ cmd: 'load', v: { toString: () => 'dQw4w9WgXcQ' } })
  post({ cmd: 'load', v: 'dQw4w9WgXc' })
  post({ cmd: 'load', v: 'dQw4w9WgXcQ' }, {})
  post({ cmd: 'seek', t: '30' })
  post({ cmd: 'load', v: 'dQw4w9WgXcQ', t: '30' })
  post({ cmd: 'load', v: 'dQw4w9WgXcQ', t: 42 })
  post({ cmd: 'seek', t: 7 })
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [
    ['load', { videoId: 'dQw4w9WgXcQ', startSeconds: 0 }],
    ['load', { videoId: 'dQw4w9WgXcQ', startSeconds: 42 }],
    ['seek', 7],
  ])
})
