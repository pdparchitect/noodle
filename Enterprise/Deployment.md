# Deploying Noodle in an organisation

> **Enterprise feature.** Managing Noodle with a configuration profile is part of Noodle
> Enterprise. Its code, this guide, the Jamf schema and the sample profile are in the
> `Enterprise/` folder under the [PolyForm Small Business License 1.0.0](LICENSE): they are free
> for personal use and for small businesses (fewer than 100 people and under the licence's revenue
> threshold), and Noodle without a profile never needs a licence; larger organisations need a
> commercial licence from us to manage Noodle with profiles. For now we grant those free of charge
> or on favourable terms, so you can deploy Noodle today without worrying about licence costs. To
> ask for one, email [contact@usenoodle.app](mailto:contact@usenoodle.app?subject=Noodle%20Enterprise%20licence). Everything outside `Enterprise/` is
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
- Install apps in `/Applications`, or deploy the installer packages below.

### Installer packages

| Package | Installs | Choices |
| --- | --- | --- |
| [Noodle-Suite-Installer.pkg](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Suite-Installer.pkg) | Your choice | Noodle, Noodle Hub, Noodle Computer, Noodle Browser, Noodle Applet, Noodle Terminal |
| [Noodle-Installer.pkg](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Installer.pkg) | Noodle | Noodle Computer, Noodle Browser, Noodle Applet, Noodle Terminal |
| [Noodle-Hub-Installer.pkg](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Hub-Installer.pkg) | Noodle Hub | Noodle Computer, Noodle Browser, Noodle Applet, Noodle Terminal |

- All three are signed with a Developer ID Installer certificate and notarised by Apple, so your MDM
  can deploy them as they are. Each has a `.sha256` checksum beside it.
- Apps install in `/Applications`, and Noodle Terminal's `noodle` command in `/usr/local/bin`.
  Installing over existing apps keeps their data, and an app that has already updated itself to a
  newer version is left as it is.
- Installed without choices, as most MDMs do, the Noodle and Hub packages install their main app with Noodle
  Computer, Noodle Browser and Noodle Applet, and leave out Noodle Terminal. The Suite selects every supported component by default, including Noodle, Hub and Terminal; every component can be deselected. To choose, pass a
  choices file to `installer`, for example from a script your MDM runs:
  `sudo installer -pkg Noodle-Suite-Installer.pkg -target / -applyChoiceChangesXML choices.xml`.
  All three installers offer `computer`, `browser`, `applet` and `terminal`; the Suite also offers `noodle` and `hub`. This file leaves out Noodle
  Computer and adds Noodle Terminal:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <array>
    <dict>
      <key>choiceIdentifier</key><string>computer</string>
      <key>choiceAttribute</key><string>selected</string>
      <key>attributeSetting</key><integer>0</integer>
    </dict>
    <dict>
      <key>choiceIdentifier</key><string>terminal</string>
      <key>choiceAttribute</key><string>selected</string>
      <key>attributeSetting</key><integer>1</integer>
    </dict>
  </array>
  </plist>
  ```

- Each app leaves a receipt under a package identifier that stays the same from release to
  release, for your MDM's inventory and smart groups:

  | Installs | Package identifier |
  | --- | --- |
  | Noodle | `com.pdparchitect.noodle.pkg.noodle` |
  | Noodle Computer | `com.pdparchitect.noodle.pkg.computer` |
  | Noodle Browser | `com.pdparchitect.noodle.pkg.browser` |
  | Noodle Applet | `com.pdparchitect.noodle.pkg.applet` |
  | Noodle Hub | `com.pdparchitect.noodle.pkg.hub` |
  | Noodle Terminal | `com.pdparchitect.noodle.pkg.terminal` |

  The receipt's version is the app's version at the time it was installed; apps update
  themselves afterwards.
- To uninstall, quit the apps, delete them from `/Applications` and the `noodle` command from
  `/usr/local/bin`, then remove their receipts, for example
  `sudo pkgutil --forget com.pdparchitect.noodle.pkg.noodle`.

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

`9a24199f-b107-4c69-b993-0c89c6006fb2` (AgentMail), `2c6facd0-a899-44c5-a7af-0440094e7756` (Airtable), `8eca4156-777b-4624-956e-de48fa373c15` (Amplitude), `00f74656-b55c-4e22-be51-3ec78d802923` (Apify), `19904597-3497-46a4-87fb-7c3161a877f9` (Apollo), `b3d0f00c-5777-4989-87b1-a18b539753af` (Asana), `e1cce3a2-3e55-4949-ad25-950a70fe3599` (Atlassian), `39765b37-9f5d-4fe7-b068-b5a6c10013e2` (Attio), `e0a407a2-a551-490a-a1b2-eed96f1190a7` (Axiom), `386a0209-9ea4-4f03-831a-88824150d10c` (Basecamp), `910b5ab3-9df3-4806-bf38-2caa097356d6` (Buildkite), `60bf0bf8-6b05-4244-adbb-bff4a0ec0740` (Cal.com), `98956aa9-a686-4040-8db4-fdb6778ada4b` (Calendly), `47f36da8-0af7-406e-a651-fc5919b240a6` (Canva), `080d0464-f4de-4549-a6ad-d161ea9090d0` (Circleback), `cd42193f-19b1-45c4-943b-08149224e315` (Clay), `76328455-0277-489f-ad3f-bb91e4337730` (ClickHouse), `5e664e9c-9547-46b4-b8a9-161aca318052` (ClickUp), `8683113a-d689-4c2d-ae1c-cea43c070307` (Close), `c9d74b1c-1e1c-4da2-91c7-0e7b625c6f51` (Cloudflare), `dde3e2a9-6a6e-487e-aed3-48e55a8833e8` (Cloudinary), `edb23681-463e-4431-9db0-51ab4565c88a` (Coinbase), `f9e78d63-c367-4689-aafd-449fe7e96e70` (Contentful), `175fbbec-f606-49d0-966e-408a1c4aaaf3` (Convex), `e8500d7b-4de3-411c-a77e-f4a3b03177e6` (Coupler.io), `4c1ebc1d-d69b-45c6-81c1-39a6b9d7b08a` (crmkit), `7f412e92-4f67-44ff-87c1-3831ebd975bb` (Datadog), `9f65bc97-6365-4e3a-8a85-82c99969988d` (Dropbox), `4a060bdc-0169-43a7-aed9-d982c47257da` (ElevenLabs), `54ff46e9-46f1-476e-ac55-6c5e1bcb570b` (Evernote), `c9b4449d-5c40-4e71-8b3f-7d65f31f3f75` (Exa), `3367399a-92a5-4562-8271-0dcc76bec2ef` (fal), `ee727f5e-ed97-41fa-aa26-74376d758b1a` (Fathom), `cbba5ea0-6d59-42a0-a6c1-346fd59c9a9e` (Fireflies), `1957c105-2d0b-49c4-a559-a58dcae6fc1d` (Gamma), `bc9a1647-6988-4051-b29c-035ba2bcdd5e` (Grafana), `2f2c5e15-ce90-4346-a7d1-a082cad934b6` (Granola), `930f6423-1113-49bf-8207-0f892b47eb47` (Guru), `08cc8547-55c3-4c13-828d-65e8e3ac459a` (Harmonic), `75cee859-d5e1-4595-af73-114cffa7fa3e` (Hex), `c5c608e5-a481-4bd0-bb52-0234846b205a` (Higgsfield), `c70b0318-fb98-4d9e-9c20-1708555045e1` (Honeycomb), `e043421d-9efb-4ed4-bf8e-5e2019eb6596` (Inkbox), `b81aa3a4-6433-4b53-83b3-cd4ca6ce12cc` (Intercom), `5807c6af-2240-41e2-916d-effc99f5829f` (Jam), `a3da3e01-299a-46ea-a6af-1ae03c15f5ae` (Jotform), `30c89ce0-b26a-4d99-9d2a-3bfd5acfed01` (Klaviyo), `c1a4e095-5f94-47a4-958a-89a69807ada8` (Kling), `27531095-a761-4c67-8628-86342aabe583` (Krea), `ec956078-71a2-4599-83d6-b9e5ef43ad9c` (Linear), `376068a2-e69f-42ef-bbee-cd9ebcbda39c` (Lucid), `e13d5a3e-cf29-43a5-a696-ee39da241459` (Mapbox), `d9a31366-521a-4f49-87b9-df9c04f90672` (Mem), `be00fd8b-60de-44e2-b005-292eab492cb8` (Mercury), `4c200a5a-ee1f-45b7-9b19-a071b4abb6f0` (Mermaid Chart), `35c1c36c-a474-4f6a-97ed-c3d1ec74811b` (Mixpanel), `30986ecf-be82-463f-9847-895ea308dfb1` (Morningstar), `03ca6937-c18a-4b0f-bd31-f21b05fe2ee9` (MotherDuck), `200c4b05-9777-446c-a182-1cb16e5cd906` (Neon), `956ce7f4-6a90-4364-9c10-3aa735bbdbf7` (Netlify), `21bd7ea0-d479-4f46-a705-bd4046a3dfec` (Notion), `9bc1bdd9-4906-49ec-87e1-fcc301ab3677` (Otter), `13c81353-d291-448c-83a4-0cc71bd67b05` (Parallel Search), `702f706c-b5ce-4385-8927-a910b22c0b77` (Parallel Tasks), `306dcb5d-fe32-4d81-ae07-af4546b2385e` (PayPal), `e2957e02-d584-4703-90f2-3d8528604a2c` (Perplexity), `4f97873a-ce49-4892-b6ca-816deda8141c` (Pipedream), `6861139e-bed2-47a8-8094-cbac1380cd11` (Polar), `be913b05-a221-4a9c-bd09-2929e5217554` (PostHog), `c34bb8c3-5342-4442-a478-a7dff6d31516` (Postman), `40f9ff2a-ad38-4700-a442-39c604ecf071` (Prisma), `0bfcac7d-c0b9-4ed8-a53b-20c18b518145` (Pulumi), `d95c530d-2a10-4009-b761-bb268415e452` (Railway), `73fd0cd8-8a5a-457c-a2da-6683af4c1299` (Ramp), `324eed39-fb3a-4a5c-9055-97a5c719690d` (Read AI), `2d8c57de-f53d-47eb-a1b3-5b73bdb72f09` (Readwise), `e1be21c8-ed1f-4c3a-afd3-22eac16ea3cc` (Replit), `bd725771-786a-4513-b537-ecfdea3ec004` (RevenueCat), `0c6b5372-f48e-405a-b593-ed06aa5590e2` (Runway), `0831fd1d-2253-483d-9709-713f1dbc6cb1` (Sanity), `2d121438-4335-4ac7-9705-b9a87b3c2312` (Semgrep), `2a6427cb-2fc5-4774-b077-2b2a4abc6308` (Sentry), `c0a4eff4-ac47-4b92-8fa2-209f9f304812` (Socket), `c754d63b-ae5d-4ef5-933e-a9ceae0a5465` (Sourcegraph), `d6b47281-748a-465a-bfab-9a03ed6d6e9a` (Square), `8c27769e-999e-420a-9f3b-ad0e769034ca` (Stripe), `05a1388d-8b94-493d-9bdb-21c0dbdee9dd` (Tavily), `dbf933f9-d507-452b-8f60-f439d4d82b51` (tl;dv), `3122870c-b92a-495e-a290-bf64cba23563` (Todoist), `776b0a4d-8e5a-4b0c-afbf-7fca6aa3d4c6` (Upstash), `0b8a3cb0-bae8-4697-adf4-84aa4c24240e` (Webflow), `1b3122f6-97a5-478e-8561-bac2e7f89b0e` (Whimsical), `fd556360-62f1-4315-84ac-70f9f711858d` (Wix), `cc750fdc-5af6-453c-9e15-d402639af1ef` (WordPress.com), `53ca3d88-e89b-4e77-8996-26506a836c03` (Gmail), `c3559334-2a72-496e-8821-e3dc02110264` (Google Calendar), `46de8e99-1594-4ae6-acf0-46b00a903ed6` (Google Docs), `f2969f64-d693-4010-bfce-a9bbeb3017ef` (Google Drive)

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
