// The noodle-embed Worker at embed.usenoodle.app: one static page that hosts YouTube's player for a
// noodlet. A noodlet page loads from a custom URL scheme, so a YouTube iframe in it sends no http(s)
// Referer and YouTube refuses to play (Error 153). A noodlet iframes this page instead, and the player
// inside it sees https://embed.usenoodle.app as its referrer. The page keeps no state, sets no cookies
// and logs nothing: observability is off in wrangler.toml and nothing here writes to the console.
//
// GET or HEAD /youtube?v=VIDEO_ID[&t=SECONDS][&autoplay=0|1]. Everything else is a 404.

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/
// Whole seconds; nine digits is decades, and keeps the number exact.
const SECONDS = /^[0-9]{1,9}$/

// The page's only script. It is the same for every video, so the policy can allow it by hash; the
// video comes from the #p element's data attributes, which the Worker fills in from validated values.
//
// Relay to parent (window.parent.postMessage, targetOrigin "*": nothing in them is private):
//   {source:"noodle-embed", type:"ready",  duration}
//   {source:"noodle-embed", type:"state",  state: "unstarted"|"ended"|"playing"|"paused"|"buffering"|"cued"}
//   {source:"noodle-embed", type:"time",   current, duration}   every second while playing
//   {source:"noodle-embed", type:"error",  code, message}       YouTube's codes 2/5/100/101/150/153, "bad-id" or "api"
// Parent to relay (postMessage to the iframe's contentWindow), accepted only from window.parent:
//   {source:"noodle-embed", cmd:"play"|"pause"|"mute"|"unmute"}
//   {source:"noodle-embed", cmd:"seek", t: seconds}
//   {source:"noodle-embed", cmd:"load", v: VIDEO_ID, t?: seconds}
// autoplay=1 starts the video once the player is ready; without it, or with autoplay=0, the viewer
// (or the parent's "play") starts it. A browser may still hold back playback with sound until a tap:
// the parent can send "mute" and then "play".
export const SCRIPT = `(() => {
  const ID = /^[A-Za-z0-9_-]{11}$/;
  const p = document.getElementById('p');
  const send = msg => parent !== window && parent.postMessage({ source: 'noodle-embed', ...msg }, '*');
  const v = p.dataset.v;
  if (!ID.test(v || '')) { send({ type: 'error', code: 'bad-id', message: 'Missing or invalid video id' }); return; }
  const start = Math.max(0, parseInt(p.dataset.t || '0', 10) || 0);
  const autoplay = p.dataset.autoplay === '1' ? 1 : 0;
  const STATES = { '-1': 'unstarted', 0: 'ended', 1: 'playing', 2: 'paused', 3: 'buffering', 5: 'cued' };
  const ERRORS = { 2: 'Invalid video id', 5: 'HTML5 player error', 100: 'Video not found or private', 101: 'Embedding disabled by owner', 150: 'Embedding disabled by owner', 153: 'The player was loaded without a referrer' };
  let player = null, timer = null;

  window.onYouTubeIframeAPIReady = () => {
    player = new YT.Player('p', {
      host: 'https://www.youtube-nocookie.com',
      videoId: v,
      playerVars: { autoplay, start, rel: 0, playsinline: 1, origin: location.origin },
      events: {
        onReady: () => send({ type: 'ready', duration: player.getDuration() }),
        onStateChange: e => {
          send({ type: 'state', state: STATES[e.data] || String(e.data) });
          clearInterval(timer);
          if (e.data === 1) timer = setInterval(() => send({ type: 'time', current: player.getCurrentTime(), duration: player.getDuration() }), 1000);
        },
        onError: e => send({ type: 'error', code: e.data, message: ERRORS[e.data] || 'Playback error' }),
      },
    });
  };

  addEventListener('message', e => {
    if (e.source !== parent || !player || !e.data || e.data.source !== 'noodle-embed') return;
    const d = e.data;
    switch (d.cmd) {
      case 'play': player.playVideo(); break;
      case 'pause': player.pauseVideo(); break;
      case 'mute': player.mute(); break;
      case 'unmute': player.unMute(); break;
      case 'seek': if (Number.isFinite(d.t)) player.seekTo(Math.max(0, d.t), true); break;
      case 'load': if (ID.test(d.v || '')) player.loadVideoById({ videoId: d.v, startSeconds: Math.max(0, +d.t || 0) }); break;
    }
  });

  const s = document.createElement('script');
  s.src = 'https://www.youtube.com/iframe_api';
  s.onerror = () => send({ type: 'error', code: 'api', message: 'Could not load the YouTube player' });
  document.head.appendChild(s);
})();`

export const STYLE = 'html,body{margin:0;height:100%;background:#000;overflow:hidden}#p,iframe{position:absolute;inset:0;width:100%;height:100%;border:0}'

// Only the values VIDEO_ID and SECONDS accept reach the page, so none of them needs escaping.
function page(video: string, start: number, autoplay: boolean): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Noodle video</title>
<style>${STYLE}</style>
</head>
<body>
<div id="p" data-v="${video}" data-t="${start}" data-autoplay="${autoplay ? 1 : 0}"></div>
<script>${SCRIPT}</script>
</body>
</html>
`
}

async function sha256(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))
  return `'sha256-${btoa(String.fromCharCode(...digest))}'`
}

let policy: Promise<string> | undefined

// What YouTube's IFrame API needs and nothing more: our one script and style by hash, its loader from
// www.youtube.com (older loaders fetch the widget script from s.ytimg.com), and the player frame from
// youtube-nocookie.com. There is deliberately no frame-ancestors: a noodlet page has a custom scheme,
// and CSP's "*" matches only http(s) ancestors (WebKit blocks a noodlet-package: parent under
// "frame-ancestors *"). The page has nothing to protect from being framed, so every parent may show it.
export function contentSecurityPolicy(): Promise<string> {
  policy ??= Promise.all([sha256(SCRIPT), sha256(STYLE)]).then(([script, style]) => [
    "default-src 'none'",
    `script-src ${script} https://www.youtube.com https://s.ytimg.com`,
    `style-src ${style}`,
    'frame-src https://www.youtube-nocookie.com',
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join('; '))
  return policy
}

// The player frame gets autoplay, fullscreen, encrypted media and picture in picture; nothing else.
// The noodlet's iframe has to allow the same for them to reach the player.
const PLAYER = '(self "https://www.youtube-nocookie.com")'
export const PERMISSIONS_POLICY = [
  `autoplay=${PLAYER}`, `fullscreen=${PLAYER}`, `encrypted-media=${PLAYER}`, `picture-in-picture=${PLAYER}`,
  'camera=()', 'microphone=()', 'geolocation=()', 'payment=()', 'usb=()', 'display-capture=()',
].join(', ')

function headers(type: string, cache: string, csp: string): Headers {
  return new Headers({
    'Content-Type': type,
    'Cache-Control': cache,
    'Content-Security-Policy': csp,
    // YouTube needs an https referrer; the origin is all it gets.
    'Referrer-Policy': 'strict-origin',
    'X-Content-Type-Options': 'nosniff',
    'Permissions-Policy': PERMISSIONS_POLICY,
  })
}

function refuse(status: 400 | 404, method: string): Response {
  const body = status === 400 ? 'Bad request\n' : 'Not found\n'
  return new Response(method === 'HEAD' ? null : body, {
    status,
    headers: headers('text/plain; charset=utf-8', 'no-store', "default-src 'none'; frame-ancestors 'none'"),
  })
}

export async function handle(request: Request): Promise<Response> {
  const url = new URL(request.url)
  const method = request.method
  if (url.pathname !== '/youtube' || (method !== 'GET' && method !== 'HEAD')) return refuse(404, method)

  const video = url.searchParams.get('v') ?? ''
  const start = url.searchParams.get('t') ?? '0'
  const autoplay = url.searchParams.get('autoplay') ?? '0'
  if (!VIDEO_ID.test(video) || !SECONDS.test(start) || (autoplay !== '0' && autoplay !== '1')) {
    return refuse(400, method)
  }

  const body = page(video, Number(start), autoplay === '1')
  // The page for a given address never changes, so browsers and the edge may keep it for a day.
  const response = headers('text/html; charset=utf-8', 'public, max-age=86400', await contentSecurityPolicy())
  return new Response(method === 'HEAD' ? null : body, { status: 200, headers: response })
}

export default {
  fetch: (request: Request) => handle(request),
}
