# Deploying Noodle in an organisation

> **Enterprise feature.** Managing Noodle with a configuration profile is part of Noodle
> Enterprise. Its code, this guide, the Jamf schema and the sample profile are in the
> `Enterprise/` folder under the [PolyForm Small Business License 1.0.0](LICENSE): they are free
> for personal use and for small businesses (fewer than 100 people and under the licence's revenue
> threshold), and Noodle without a profile never needs a licence; larger organisations need a
> commercial licence from us to manage Noodle with profiles. For now we grant those free of charge
> or on favourable terms, so you can deploy Noodle today without worrying about licence costs. To
> ask for one, email [pdp@gnucitizen.org](mailto:pdp@gnucitizen.org?subject=Noodle%20Enterprise%20licence). Everything outside `Enterprise/` is
> Apache-2.0. See [ENTERPRISE.md](../ENTERPRISE.md).
>
> Noodle never checks for a licence and never limits the feature without one.

This guide is for administrators who deploy Noodle to Macs with an MDM such as Jamf Pro,
Kandji, Microsoft Intune or Mosyle. Anything not supported is said so.

## Installing the apps

| App | Download | Bundle ID | Minimum macOS |
| --- | --- | --- | --- |
| Noodle | [Noodle-arm64.dmg](https://github.com/pdparchitect/noodle/releases/latest/download/Noodle-arm64.dmg) | `com.pdparchitect.noodle` | 26 |
| Noodle Computer | [Noodle-Computer-arm64.dmg](https://github.com/pdparchitect/noodle/releases/download/computer-latest/Noodle-Computer-arm64.dmg) | `com.pdparchitect.noodle.computer` | 26 |
| Noodle Browser | [Noodle-Browser-arm64.dmg](https://github.com/pdparchitect/noodle/releases/download/browser-latest/Noodle-Browser-arm64.dmg) | `com.pdparchitect.noodle.browser` | 26 |
| Noodle Applet | [Noodle-Applet-arm64.dmg](https://github.com/pdparchitect/noodle/releases/download/applet-latest/Noodle-Applet-arm64.dmg) | `com.pdparchitect.noodle.applet` | 15 |
| Noodle Hub | [Noodle-Hub-arm64.dmg](https://github.com/pdparchitect/noodle/releases/download/hub-latest/Noodle-Hub-arm64.dmg) | `com.pdparchitect.noodle.hub` | 26 |

- Every app is for Apple silicon only, signed with a Developer ID and notarised by Apple.
- Each release on the [releases page](https://github.com/pdparchitect/noodle/releases) also has a
  ZIP of each app with a `.sha256` checksum, convenient for packaging. A specific version is at
  `releases/download/vX.Y.Z/Noodle-arm64.zip`.
- Noodle Computer, Browser, Applet and Hub are optional. Deploy only those your people need.
- No installer package (`.pkg`) is published. Wrap the app in a package with your MDM's tools,
  or deploy the app bundle where your MDM supports it. Install apps in `/Applications`.

## Updates

Noodle updates itself with Sparkle, from
`https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml`. Updates are signed
and checked before they install. By default Noodle checks once a day, and people choose in
Settings › Update whether it checks and whether it downloads and installs updates by itself.

- To fix automatic checking, set `AutomaticUpdateChecks`. To fix automatic downloading and
  installing, set `AutomaticUpdateInstalls`. Settings shows the switch as managed.
- To leave updates to your MDM, set `AllowUpdates` to `false`. Noodle then turns off both
  automatic settings and never checks for an update by itself, and Check for Updates is
  unavailable.
- Removing a key puts back the person's own update settings.
- The companion apps update themselves too; they have no managed keys yet. Restrict them with
  your MDM, or deploy only the apps your people need.
- Noodle installs and updates some harnesses itself when the person chooses Managed by Noodle in
  Settings › Harness. No key controls this yet.

## Configuration profile

Noodle reads managed preferences from its preference domain, `com.pdparchitect.noodle`. Install
a configuration profile with a Custom Settings (`com.apple.ManagedClient.preferences`) payload for
that domain, or use your MDM's equivalent. Development builds use a different bundle ID and don't
read this domain.

- **Every key is optional.** Without a profile, or without a key, Noodle behaves as it does
  unmanaged: everything is allowed. A key only ever narrows what is allowed.
- **Only enforced values count.** Every key is a restriction the person can't change. Values
  delivered as a changeable default ("set once") are ignored in this version.
- **Wrong values are ignored, not guessed.** A value of the wrong type is ignored for that key
  and logged in Console under subsystem `com.pdparchitect.noodle`, category `ManagedPreferences`.
  A list keeps its valid entries and leaves out the rest. A mistake never widens what is
  allowed.
- **Deny wins.** A deny list wins over an allow list. An allow list, when present, means only
  what it lists; an empty allow list allows nothing.
- **Changes apply while Noodle runs.** Noodle follows its preference domain and reads it again at
  least every minute, so installing, changing or removing a profile takes effect without a
  restart. What a new policy forbids stops: bots on a blocked harness stop, a blocked tool
  connection, browser or computer stops working, Let My Devices Reach This Mac turns off, and joined Hubs
  are disconnected. Nothing is deleted.
- **Removing the profile** restores each person's own settings and Noodle's defaults: a Hub
  turned off by a policy turns on again if the person had it on, and bots start again.
- **User or device scope.** Both work. A device-scoped profile applies to every account on the
  Mac; a user-scoped one to that person only.
- **What people see.** A control the profile sets is unavailable and says Managed by your
  organisation. Settings › General lists every policy in force.

### Keys

<!-- BEGIN GENERATED KEYS: swift run NoodleEnterpriseFiles -->

| Key | Type | Default | Since | What it does |
| --- | --- | --- | --- | --- |
| `AllowedHarnesses` | Array of strings | All | 0.84.0 | The only harnesses people can use. Others are hidden in Settings and the fallback list, and bots set to one don't start. Missing: every harness. |
| `AllowUnrestrictedAccess` | Boolean | `true` | 0.84.0 | Whether people can turn off the macOS sandbox for a bot (Unrestricted access in Settings › Bots). When false, every bot runs sandboxed; bots that had unrestricted access restart sandboxed. |
| `AllowMCP` | Boolean | `true` | 0.84.0 | Whether people can sign in to and bots can use MCP tool connections at all. When false, every connection stops working; none is deleted. |
| `MCPAllowList` | Array of strings | Not set | 0.84.0 | The only connections from Noodle's catalogue people can use, by catalogue ID. Missing: all of them. Does not apply to custom connections. |
| `MCPDenyList` | Array of strings | Not set | 0.84.0 | Connections from Noodle's catalogue people can't use, by catalogue ID. Wins over the allowed list. |
| `AllowCustomMCP` | Boolean | `true` | 0.84.0 | Whether people can use MCP servers they add by URL, not from the catalogue. |
| `CustomMCPAllowList` | Array of strings | Not set | 0.84.0 | The only custom MCP servers people can use. Each entry is a host name, such as mcp.example.com, a domain with its subdomains, such as *.example.com, or a URL prefix starting with https://. Missing: any server. |
| `CustomMCPDenyList` | Array of strings | Not set | 0.84.0 | Custom MCP servers people can't use. Each entry is a host name, such as mcp.example.com, a domain with its subdomains, such as *.example.com, or a URL prefix starting with https://. Wins over the allowed list. |
| `AllowBrowser` | Boolean | `true` | 0.84.0 | Whether people and their bots can use Noodle Browser's browsers from Noodle. |
| `AllowComputers` | Boolean | `true` | 0.84.0 | Whether people and their bots can use Noodle Computer's computers from Noodle. |
| `AllowHubHosting` | Boolean | `true` | 0.84.0 | Whether people can turn on Let My Devices Reach This Mac in Settings › Hub, which serves their own devices from this Mac as a Hub does. When false, a Hub already on stops; the setting comes back when allowed again. |
| `AllowHubConnections` | Boolean | `true` | 0.84.0 | Whether people can join and use Noodle Hubs from this Mac. When false, joined Hubs are disconnected; none is left. |
| `HubAllowList` | Array of strings | Not set | 0.84.0 | The only Hub addresses Noodle connects to. Each entry is a host name or IP address, or a domain with its subdomains, such as *.example.com. Missing: any address. |
| `HubDenyList` | Array of strings | Not set | 0.84.0 | Hub addresses Noodle never connects to, in the same form. Wins over the allowed list. |
| `AllowUpdates` | Boolean | `true` | 0.84.0 | Whether Noodle checks for and installs its own updates. Set false to leave updates to your MDM. |
| `AutomaticUpdateChecks` | Boolean | `true` | 0.84.0 | Fixes Settings › Update › Automatically check for updates on or off. |
| `AutomaticUpdateInstalls` | Boolean | `false` | 0.84.0 | Fixes Settings › Update › Automatically download and install updates on or off. |

Values for `AllowedHarnesses`:

`codex` (Codex), `claude-code` (Claude Code), `muse` (Muse Code), `grok-build` (Grok Build), `fx` (FX), `opencode` (OpenCode), `antigravity` (Antigravity), `apple` (Apple Intelligence)

Values for `MCPAllowList` and `MCPDenyList`:

`agentmail` (AgentMail), `airtable` (Airtable), `amplitude` (Amplitude), `apify` (Apify), `apollo` (Apollo), `asana` (Asana), `atlassian` (Atlassian), `attio` (Attio), `axiom` (Axiom), `basecamp` (Basecamp), `buildkite` (Buildkite), `cal-com` (Cal.com), `calendly` (Calendly), `canva` (Canva), `circleback` (Circleback), `clay` (Clay), `clickhouse` (ClickHouse), `clickup` (ClickUp), `close` (Close), `cloudflare` (Cloudflare), `cloudinary` (Cloudinary), `coinbase` (Coinbase), `contentful` (Contentful), `convex` (Convex), `coupler` (Coupler.io), `crmkit` (crmkit), `datadog` (Datadog), `dropbox` (Dropbox), `elevenlabs` (ElevenLabs), `evernote` (Evernote), `exa` (Exa), `fal` (fal), `fathom` (Fathom), `fireflies` (Fireflies), `gamma` (Gamma), `grafana` (Grafana), `granola` (Granola), `guru` (Guru), `harmonic` (Harmonic), `hex` (Hex), `higgsfield` (Higgsfield), `honeycomb` (Honeycomb), `inkbox` (Inkbox), `intercom` (Intercom), `jam` (Jam), `jotform` (Jotform), `klaviyo` (Klaviyo), `kling` (Kling), `krea` (Krea), `linear` (Linear), `lucid` (Lucid), `mapbox` (Mapbox), `mem` (Mem), `mercury` (Mercury), `mermaid-chart` (Mermaid Chart), `mixpanel` (Mixpanel), `morningstar` (Morningstar), `motherduck` (MotherDuck), `neon` (Neon), `netlify` (Netlify), `notion` (Notion), `otter` (Otter), `parallelai-search` (Parallel Search), `parallelai-task` (Parallel Tasks), `paypal` (PayPal), `perplexity` (Perplexity), `pipedream` (Pipedream), `polar` (Polar), `posthog` (PostHog), `postman` (Postman), `prisma` (Prisma), `pulumi` (Pulumi), `railway` (Railway), `ramp` (Ramp), `read-ai` (Read AI), `readwise` (Readwise), `replit` (Replit), `revenuecat` (RevenueCat), `runway` (Runway), `sanity` (Sanity), `semgrep` (Semgrep), `sentry` (Sentry), `socket` (Socket), `sourcegraph` (Sourcegraph), `square` (Square), `stripe` (Stripe), `tavily` (Tavily), `tldv` (tl;dv), `todoist` (Todoist), `upstash` (Upstash), `webflow` (Webflow), `whimsical` (Whimsical), `wix` (Wix), `wordpress` (WordPress.com), `gmail` (Gmail), `google-calendar` (Google Calendar), `google-docs` (Google Docs), `google-drive` (Google Drive)

<!-- END GENERATED KEYS -->

Matching rules:

- `AllowedHarnesses` lists harness IDs. A bot whose harness isn't listed doesn't start, and the
  harness is hidden in Settings › Harness, in every harness picker and in the fallback list.
- `MCPAllowList` and `MCPDenyList` list connections from Noodle's catalogue by ID. They don't
  apply to servers people add by URL; those follow `AllowCustomMCP`, `CustomMCPAllowList` and
  `CustomMCPDenyList`, which match the server's address: a host such as `mcp.example.com`, a
  domain with its subdomains such as `*.example.com`, or a URL prefix such as
  `https://mcp.example.com/tools`, which matches whole path segments. Noodle connects only to
  remote MCP servers over HTTPS, so there is nothing to match by local command.
- `HubAllowList` and `HubDenyList` match each address a Hub gives, by host name or IP address or
  `*.domain`. Noodle uses only the Hub's addresses the lists allow, and refuses a Hub with none.

### Jamf Pro

1. In Jamf Pro, open Computers › Configuration Profiles and add a profile with an
   **Application & Custom Settings** payload. Choose **External Applications**, then **Add**, and
   **Custom Schema**.
2. Enter `com.pdparchitect.noodle` as the preference domain and paste the schema from
   [`Profiles/com.pdparchitect.noodle.json`](Profiles/com.pdparchitect.noodle.json). Use the schema
   from the release you deploy: it lists the keys that release reads.
3. Add the keys you need with **Add/Remove properties**, set them and scope the profile.

Jamf can't discover keys from the installed app, so only the keys in the schema exist.

### Other MDMs and testing by hand

[`Profiles/Noodle.mobileconfig`](Profiles/Noodle.mobileconfig) sets every key to what Noodle does
without it, so installing it unchanged changes nothing but shows each key as managed. Change the
values you need, remove the keys you don't, and give the profile your own `PayloadIdentifier` and
`PayloadUUID`s. Upload it to your MDM as a custom profile, or double-click it to install it by
hand in System Settings › General › Device Management. Allow lists aren't in the sample, because
one present means only what it lists.

## Login items and background services

- Noodle itself adds no login item. Bots run only while Noodle is open; to keep them working,
  add Noodle to the login items with your MDM.
- **Let My Devices Reach This Mac** (Settings › Hub) runs inside Noodle while it is open. It keeps the Mac
  from idle sleep while on. `AllowHubHosting` turns it off.
- **Noodle Hub** is a separate app. It registers itself as a login item. No Noodle key covers
  it; deploy it only to Macs meant to be Hubs.
- **Noodle Computer**'s Local Mac computers use a system service people approve in System
  Settings › General › Login Items & Extensions. You can approve or block it ahead of time with a
  Managed Login Items (`com.apple.servicemanagement`) payload for Noodle Computer.

## Network

Outbound connections, all HTTPS unless stated:

| Purpose | Hosts |
| --- | --- |
| Noodle and companion updates | `github.com` and the GitHub hosts its release downloads redirect to |
| Harnesses | Each harness talks to its own provider, as it does outside Noodle. Allow what the harnesses you permit need. |
| Harnesses Noodle installs (Managed by Noodle) | `api.github.com` and `releases.openai.com` (Codex), `downloads.claude.ai` (Claude Code), `releases.fx.sh` (FX), `x.ai` (Grok Build), `api.meta.ai` and `lookaside.facebook.com` (Muse Code), `opencode.ai` and `registry.npmjs.org` (OpenCode), `antigravity-cli-auto-updater-974169037036.us-central1.run.app` and `storage.googleapis.com` (Antigravity) |
| Tool connections | The MCP servers people connect, and their sign-in pages |
| Calls ringing on phones (Hubs) | `push.usenoodle.app`, and Apple's CloudKit |

Noodle Hubs talk to the devices that joined them over QUIC (UDP):

| Hub | Port |
| --- | --- |
| Noodle Hub app | UDP 38415 |
| Let My Devices Reach This Mac, in Noodle | UDP 38417 |

A Hub asks the router to forward its port with UPnP or NAT-PMP, for devices away from home.
Block those, or the ports, to keep Hubs on the local network.

## Hubs

- **Hosting a Hub.** Let My Devices Reach This Mac serves the person's own devices, such as Noodle Mobile,
  from their Mac. `AllowHubHosting` set to `false` turns it off and keeps it off. The Noodle Hub
  app isn't covered by a key; don't deploy it where Hubs aren't wanted.
- **Connecting to a company Hub.** People join a Hub with an invitation in Settings › Hub.
  `AllowHubConnections` set to `false` disconnects every joined Hub and refuses new ones.
  `HubAllowList` limits Noodle to your Hub's addresses; `HubDenyList` blocks addresses.
- A Hub runs bots for the people on it with the Hub's own settings. Policies on a person's Mac
  don't apply to bots that run on a Hub.

## Data and removal

- Noodle keeps bots, their workspaces, conversations and settings in its sandbox container,
  `~/Library/Containers/com.pdparchitect.noodle/`. Bots' data is under
  `Data/Library/Application Support/Noodle/` there.
- Sign-ins to tool connections are in the keychain.
- Harnesses keep their own sign-ins where they always do, such as `~/.codex` or `~/.claude`.
- To remove Noodle, quit it, delete it from `/Applications`, and delete its container and
  `~/Library/Group Containers/` folders whose names end in `com.pdparchitect.noodle.sharing`.
  Removing a configuration profile doesn't remove Noodle or its data.

## Not supported yet

- iPhone and iPad (Noodle Mobile) have no managed keys.
- The companion apps and Noodle Hub have no managed keys.
- Keys that only set a changeable default.
