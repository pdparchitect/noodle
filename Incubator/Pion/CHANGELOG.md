# Changelog

## [Unreleased]

### Fixed

- Smoother conversation scrolling: unchanged messages reuse their formatted text when rows redraw.
- Background effects and working agents' rings no longer slow the app: both are drawn outside the main thread.
- Dictation no longer changes the message field's height, and its waveform fills the field.
- The message field's + button opens Noodle's attachment menu.
- Evidence and team tool rows expand when clicked anywhere, not only on the chevron.
- A conversation's heading no longer sits under the toolbar.

### Changed

- Pion no longer asks for the camera, calendars or reminders, which it does not use.
- Agents have generated marks of their own, kept through renames, in place of symbols.
- The audit log reads as a timeline grouped by day, with each event named and marked.
- Team members are added and removed as in Noodle's groups, in place of checkboxes. Members are changed from the editor, so the Members toolbar button is gone, as are the sidebar's plus buttons.
- Dictation stops with Return or the stop button; the Done button is gone.
- The agent editor's Runtime section is now Harness, with Noodle's harness, model and reasoning choosers.
- The Grid background ripples with pings that lift and push the dots they pass.
- Background effects carry on under the sidebar and inspector, softened by their frosted glass, and are fainter, so text stands out.
- Scanlines now have a sweeping refresh beam and flickers of interference.
- Sheets use Noodle-style top action bars and rounded text fields, with multiline descriptions and Return left to the focused field. Scenarios use generated agent names throughout their conversations and mentions.
- New agents start with generated names, with a Human option and a button to try another name. Agents and groups can be edited from their sidebar context menus or the conversation toolbar.
- The View menu separates the inspector from display options and keeps background effects together in a submenu.
- A Conversation menu replaces Investigation, with search, a conversation picker, separate conversation windows, Float on Top, dictation and Stop. Investigation status and closing stay in the investigation's toolbar.

### Added

- Attachments work as in Noodle: add a file, a photo or a capture of a window from the + menu; files show as pictures and cards in messages and open in Quick Look; annotate a file, a link, a region or selected text, from the preview or with Conversation › Add Annotation and Annotate Region.
- Clicking an agent's mark opens its profile, with buttons to message or edit it.
- Chess and Chase background effects: a famous game replayed across the whole window, and a maze cleared by a hunter chased by ghosts.
- General, Permissions and Update settings. Released builds update themselves from Pion's own channel, and Pion › Check for Updates looks now.
- Keep Mac awake while agents work, in General settings, as in Noodle.
- Assign shared folders with read-only or read-and-write access to agents, groups and investigations. Agent editors now have General, Runtime and Tools sections, including harness profiles and reasoning effort. Add, configure and assign tool connections to agents, including from team editors; assignments reach the running agents and can be revoked. Investigations can be edited from their toolbar or context menu.
- Pion's first version: Investigations, groups and agents in one sidebar, each Investigation with an objective, a scope, a status, a lead agent and a case record of entities, evidence, findings and proposed actions beside the conversation.
- Conversations read as documents: agents' messages fill a reading column with their name above, yours sit on the right, and nothing is folded away.
- A message field with @mentions, attachments and dictation that turns speech into text before you send it.
- An action policy that decides every action an agent proposes: allowed, waiting for your approval, or refused. Targets outside the scope and protected assets are always refused.
- An append-only audit log for every Investigation.
- Settings for harness sign-in, agents and MCP tools.
- Scenarios, played and photographed with `scripts/scenario.sh`.
