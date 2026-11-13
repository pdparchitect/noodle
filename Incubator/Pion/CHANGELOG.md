# Changelog

## [Unreleased]

### Fixed

- Smoother conversation scrolling: unchanged messages reuse their formatted text when rows redraw.

### Changed

- Sheets use Noodle-style top action bars and rounded text fields, with multiline descriptions and Return left to the focused field. Scenarios use generated agent names throughout their conversations and mentions.
- New agents start with generated names, with a Human option and a button to try another name. Agents and groups can be edited from their sidebar context menus or the conversation toolbar.
- The View menu separates the inspector from display options and keeps background effects together in a submenu.
- A Conversation menu replaces Investigation, with search, a conversation picker, separate conversation windows, Float on Top, dictation and Stop. Investigation status and closing stay in the investigation's toolbar.

### Added

- Pion's first version: Investigations, groups and agents in one sidebar, each Investigation with an objective, a scope, a status, a lead agent and a case record of entities, evidence, findings and proposed actions beside the conversation.
- Conversations read as documents: agents' messages fill a reading column with their name above, yours sit on the right, and nothing is folded away.
- A message field with @mentions, attachments and dictation that turns speech into text before you send it.
- An action policy that decides every action an agent proposes: allowed, waiting for your approval, or refused. Targets outside the scope and protected assets are always refused.
- An append-only audit log for every Investigation.
- Settings for harness sign-in, agents and MCP tools.
- Scenarios, played and photographed with `scripts/scenario.sh`.
