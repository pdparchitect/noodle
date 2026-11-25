---
guides: [setup]
order: 0
---

# Setting up Pion

This guide is for the administrators who prepare the accounts and access that
Pion's tools use. Pion reaches your services only through the tools you connect
in **Settings → Tools**, each with an account, app or key of its own.

## What to prepare

- A harness account for each person using Pion: Codex, Claude Code, or Apple
  Intelligence on the Mac itself.
- For each service the team should use, the account, app or key its tool asks
  for. Every tool's own steps are under **Setup Steps** on its form in
  **Settings → Tools**; the chapters that follow explain the services that need
  the most setting up.

## Good practice

- Give every tool an account of its own, used for nothing else, so its activity
  stands out in the service's own logs and you can revoke it without breaking
  anything else.
- Keep a service's detection and containment tools apart: the detection tool
  only reads, and the containment tool holds only the actions it takes.
- Give each tool the least access its Setup Steps list, and no more.
- Protect the accounts that sign in as administrators with the strongest
  sign-in the service offers.
- Revoke a tool's account or key when it is no longer used, or when the Mac
  running Pion changes hands.
