---
guides: [setup]
order: 0
---

# Setting up Rook

This guide is for whoever prepares Rook for a team. Rook needs no accounts in
the systems it tests: its agents work from Linux computers on the Mac itself,
and each Mission's computers reach only that Mission's scope.

## What to prepare

- A harness account for each person using Rook: Codex, Claude Code, or Apple
  Intelligence on the Mac itself.
- Written authorization to test every target you put in a Mission's scope.

## Good practice

- Keep each Mission's scope to what the authorization covers, and put `deny` in
  front of anything inside it that is out of scope.
- Open services under **Exceptions** only when agents need them, such as lookup
  sites.
- Export a Mission when it closes: the export includes its network and DNS
  logs.
