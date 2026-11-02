# Noodle Embed

The Cloudflare Worker `noodle-embed` at https://embed.usenoodle.app. It serves one static page that hosts
YouTube's player, so a noodlet can show a YouTube video.

## Why

A noodlet page loads from a custom URL scheme, so an iframe in it sends no http(s) `Referer`, and YouTube's
player refuses to play without one (Error 153). A noodlet iframes this page instead; the player inside it
sees `https://embed.usenoodle.app` as its referrer. The page keeps nothing: no cookies, no storage, no
request logs.

embed.usenoodle.app is a separate host but the same site as usenoodle.app. YouTube's scripts run in its
origin and could set cookies for `.usenoodle.app`. That is fine today, because neither the website nor
Push uses cookies. If usenoodle.app ever does, move this page to a separate registrable domain.

## URL contract

`GET /youtube?v=VIDEO_ID[&t=SECONDS][&autoplay=0|1]`

- `v`: an 11-character YouTube id (`[A-Za-z0-9_-]`). Required.
- `t`: where to start, in whole seconds. Default 0.
- `autoplay`: `1` starts the video when the player is ready; `0`, the default, waits for the viewer or the
  noodlet's `play`.

Anything else is a 400 (bad values) or a 404 (other paths and methods; `HEAD /youtube` works).

A noodlet lists both sites in its manifest's `embeds` and iframes the page:

```json
"embeds": ["https://embed.usenoodle.app", "https://www.youtube-nocookie.com"]
```

```html
<iframe src="https://embed.usenoodle.app/youtube?v=dQw4w9WgXcQ"
        sandbox="allow-scripts allow-same-origin allow-presentation"
        allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen></iframe>
```

The page talks to its parent with `postMessage`, every message carrying `source: "noodle-embed"`:

- It sends `{type: "ready", duration}`, `{type: "state", state}` (`unstarted`, `ended`, `playing`,
  `paused`, `buffering`, `cued`), `{type: "time", current, duration}` every second while playing, and
  `{type: "error", code, message}`.
- It accepts, from its parent only, `{cmd: "play" | "pause" | "mute" | "unmute"}`, `{cmd: "seek", t}` and
  `{cmd: "load", v, t}`, with `v` a string id and `t` a number of seconds; it ignores anything else.
- A noodlet should trust a message only if `event.origin` is `"https://embed.usenoodle.app"` and
  `event.source` is the iframe's `contentWindow`.

## Headers

A Content-Security-Policy that allows the page's own script and style by hash, YouTube's IFrame API
scripts and the youtube-nocookie.com player frame, and nothing else. It sets no `frame-ancestors`: the
parent is a noodlet page with a custom scheme, which `*` would not match. `Referrer-Policy: strict-origin`
gives YouTube the origin and no more. Also `X-Content-Type-Options: nosniff`, a `Permissions-Policy` that
passes only autoplay, fullscreen, encrypted media and picture in picture to the player, and a day of public
caching.

## Develop and deploy

```sh
npm ci
npm run check   # typecheck
npm test        # node:test, Node 22.18 or later
npx wrangler dev
```

`.github/workflows/embed.yml` tests every change to `Embed/` and deploys from `main` with
`wrangler deploy`, from the `embed-production` environment's `CLOUDFLARE_ACCOUNT_ID` and
`CLOUDFLARE_API_TOKEN` (its own token, not Push's, that can only edit Workers scripts and the
usenoodle.app zone's routes). The custom domain in
`wrangler.toml` creates the DNS record and certificate on the first deploy.
