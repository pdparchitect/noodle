# Scenarios

A scenario puts the real Noodle app into a prepared state for screenshots. Each folder
here is one scenario. They are loaded by path, never bundled, and the code that loads
them exists only in development builds.

```
Scenarios/
  family-butler/
    scenario.json     what to show and what happens
    assets/           avatars, attachments and wallpapers the JSON names
    root/             optional files laid over the seeded workspace as they are
    shots/            capture output, ignored by Git
```

## Run one

```sh
zsh scripts/scenario.sh                 # the picker
zsh scripts/scenario.sh family-butler   # one scenario; Return in the terminal is Next Step
zsh scripts/scenario.sh --shots --all   # save every capture step of every scenario
```

The script builds `.build/Noodle Scenarios.app`, a copy of the development app with its
own identifier and container and no network, account, group or helper entitlement. The
loader refuses to run anywhere else. Every launch discards the previous workspace and
preferences and seeds the scenario again.

In the app, the **Scenarios** menu lists every scenario with a checkmark on the open
one. Choosing one relaunches into it. **Reload** (⌥⌘R) relaunches the current scenario
and picks up edits to its files. **Next Step** (⌥⌘→) continues a timeline stopped at
`waitFor: key`. **Show Picker** lists the scenarios with any that do not load and why.
**Reveal in Finder** shows the open scenario's folder. The last choice is remembered, so
opening the bundle again returns to it.

`--shots` is driven by the script: the app announces each `capture` step, the script
photographs the main window with `screencapture` into `shots/NAME.png`, and the app
quits at the end of the timeline. It needs a terminal with Screen Recording permission.
During a capture run `waitFor: key` does not stop, and `waitFor: userMessage` sends the
draft in the composer.

`swift test --disable-sandbox --filter ScenarioTests` loads, seeds and plays every
folder here. Unknown keys, missing assets and references to bots, conversations or
messages that do not exist all fail, in the tests and in the picker.

## scenario.json

```json
{
  "version": 1,
  "title": "Group review with one bot working",
  "clock": "14:20",
  "settings": { "chatAttachmentLayout": "wrap" },
  "harnesses": {
    "claude-code": { "models": "builtin" },
    "codex": { "models": [ { "id": "gpt-5.2-codex", "name": "GPT-5.2 Codex",
      "efforts": ["low", "medium", "high"], "defaultEffort": "medium", "default": true } ] }
  },
  "agents": [ … ],
  "conversations": [ … ],
  "present": { … },
  "timeline": [ … ]
}
```

| Key | Meaning |
| --- | --- |
| `version` | `1`. |
| `title` | Shown in the picker and the menu. |
| `clock` | `"HH:mm"` today, the time the scenario opens at. Without it, the time of launch. Messages sent while it runs are stamped with the clock plus the time elapsed. |
| `appearance` | `"dark"` or left out. Noodle has no light appearance. |
| `settings` | Preferences by their defaults key: `chatAttachmentLayout`, `BotNameStyle`, `Noodle.firstBotSetup.dismissed`, `Noodle.composer.showBotDescriptions`, `Noodle.floatingConversations.keepsOne`, `Noodle.linkPreview.timeoutSeconds`. Message delivery is always `queue`. |
| `harnesses` | The harnesses that look installed, by identifier: `claude-code`, `codex`, `fx`, `grok-build`, `muse`, `opencode`, `antigravity`. `models` is `"builtin"` for Claude Code or the list the harness would report. Nothing is installed or run. |

### Times

`"at"` is `"HH:mm"` on the scenario's day, `"-2d HH:mm"` on an earlier day, or `"-15m"` and
`"-3h"` before the clock. Messages in a conversation are in time order. The sidebar shows
a time for today and a date otherwise; chat bubbles show neither.

### agents

```json
{ "key": "mira", "name": "Mira", "harness": "claude-code", "model": "opus", "effort": "high",
  "description": "Reviews changes and keeps the release notes",
  "backstory": "You review changes carefully and write in plain language.",
  "avatar": { "image": "assets/mira.jpg" },
  "status": { "phase": "ready" },
  "unrestricted": false,
  "autoReplies": ["On it.", "Done. Take a look."] }
```

- `key` names the bot everywhere else in the file. `harness` is one of `harnesses`, and
  `model` and `effort` are ones it lists.
- `avatar` is an `image`, or a `symbol` from the bot icon editor with a `colour` index.
  The colour defaults to the bot's position in the list.
- `status` is what the sidebar dot, the Activity window and Settings report: `phase` is
  `ready`, `working`, `starting`, `offline` or `failed`, with an optional `detail`. A
  failed status needs a `detail` and may carry a `failure` of `usageLimit`,
  `authenticationRequired`, `missingSession` or `recoveryFailed`, which is what makes Kick
  ask for confirmation. Only Grok Build and OpenCode report these failures. After a
  confirmed Kick the bot comes back ready; for `missingSession` the app reports that
  recovery could not be prepared, as there is no saved session.
- `autoReplies` are given in turn when you write to the bot after the timeline has ended.

Every bot has a direct conversation whether or not `conversations` describes it.

### conversations

```json
{ "key": "launch",
  "group": { "name": "Launch prep", "description": "Onboarding and notes", "members": ["mira", "juno"] },
  "background": { "image": "assets/dusk-hills.jpg" },
  "unread": true,
  "messages": [
    { "key": "mockup", "at": "13:10", "from": "wren", "text": "Here is the layout.",
      "attachments": [ { "file": "assets/onboarding-mockup.png" } ],
      "reactions": [ { "from": "user", "emoji": "👏" } ] },
    { "at": "13:31", "from": "user", "text": "Agreed.", "delivery": "failed" } ] }
```

- A conversation is `"direct": "botKey"` or a `group`.
- `background` is a `preset` (`sunset`, `ocean`, `forest`, `dusk`) or an `image`.
- `from` is `"user"` or a member's key. `text` is Markdown. A web address in the text asks
  for a link preview, which the scenarios bundle cannot fetch.
- `delivery` for the user's messages is `delivered` (the default), `saved` or `failed`,
  shown as Delivered, Saved and Not delivered. Sent is what a `say` step to a stopped bot
  shows.
- An attachment is a `file` under the scenario folder or a `link` to a public web page.
- A message `key` lets `present.scroll` and `react` refer to it.
- `unread` marks the conversation in the sidebar and the Dock badge. The main window reads
  what it shows, so `present.select` must then name another conversation.

### present

The state of the windows, at launch and again in any `present` step.

```json
{ "window": { "size": [1160, 810], "origin": [120, 90] },
  "sidebar": "visible",
  "select": "launch",
  "search": "",
  "draft": "Ship it when the tests pass",
  "draftAttachments": ["assets/onboarding-mockup.png"],
  "scroll": { "launch": "mockup" },
  "windows": [
    { "conversation": "mira", "frame": [1300, 160, 760, 810], "floating": false },
    { "activity": "juno" },
    { "settings": "sandbox" } ],
  "sheet": { "editBot": "mira" } }
```

- Positions are in points from the top left of the main screen.
- `scroll` is `"bottom"` or the key of the message to open at.
- `windows` opens conversations in their own window or floating, a bot's Activity
  window, or Settings on a tab: `general`, `chat`, `harnesses`, `mcps`, `heartbeats`,
  `sandbox`, `keybindings`, `permissions`, `companions`, `updates`. The Harnesses tab
  checks versions and accounts as it opens, which the scenarios bundle cannot reach.
- `sheet` opens one of `newBot`, `newGroup`, `firstBotSetup` (each `true`), `editBot`
  (a bot), `groupInfo` or `background` (a conversation). `{}` closes them.

### timeline

Steps run in order once the window is up. A step does one thing, after an optional
`wait` in seconds; a step with only `wait` is a delay.

| Step | What happens |
| --- | --- |
| `{ "agent": "juno", "status": { … } }` | The bot's status changes. |
| `{ "agent": "juno", "in": "launch", "reply": { "key": "build", "text": "…", "attachments": [ … ] } }` | The bot sends a message, which arrives as any reply does: unread marker, Dock badge, transition. `in` defaults to the bot's direct conversation. |
| `{ "in": "launch", "say": { "text": "…" } }` | You send a message. A running bot fetches it, which turns Sent into Delivered. |
| `{ "agent": "wren", "react": { "message": "build", "emoji": "🚀" } }` | A reaction from the bot, or from you without `agent`. `"remove": true` takes it away. |
| `{ "agent": "juno", "stream": { "text": "…", "chunk": 12, "interval": 0.05 } }` | Output appears piece by piece in the bot's Activity window. |
| `{ "agent": "juno", "toolCall": { "input": "swift test", "output": "…", "exit": 0, "duration": 1.5 } }` | A command runs and completes in the Activity window. `title` replaces Running command. |
| `{ "error": "…" }` | The app's error alert. |
| `{ "waitFor": "userMessage", "agent": "mira" }` | Waits until you write to the bot. |
| `{ "waitFor": "key" }` | Waits for Scenarios > Next Step, or Return in the terminal. |
| `{ "present": { … } }` | Changes the presentation. |
| `{ "capture": "02-replied" }` | With `--shots`, saves the main window as `shots/02-replied.png`. Otherwise nothing. |

## root/

Files under `root/` are copied over the seeded workspace before the app reads it, for
state the JSON does not describe, such as `MCP/connections.json`, `computers.json` or
`browsers.json`.

## Content

Scenarios appear in public screenshots. Write the conversations as believable product
use, keep real people and companies out of them, and make every asset yourself.
