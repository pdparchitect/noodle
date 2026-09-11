# Security notice

Noodle agents can run commands, change files, and use connected services. Give
them access appropriate to the work you want done.

## Agent access

The Noodle app is sandboxed, but agents with autonomous access run outside that
sandbox as your Mac user. They can access files and signed-in services beyond
their workspace. Noodle accepts supported tool approvals automatically.

Codex starts restricted and supports optional autonomous access. Claude Code,
FX, Grok Build, and Muse Code require autonomous access.

## Data and credentials

Conversations and workspaces are stored locally. Your harness sends work to its
model provider; connected tools can send data to their services. Local storage
does not make model processing local.

Noodle stores connected-tool credentials in Keychain. Voice transcription runs
on your Mac; sending a voice message shares its audio and transcript with the agents.

## Shared computers

Noodle Computer runs Linux workspaces in virtual machines without sharing host
folders or the clipboard. Agents assigned to the same computer share its files
and services. Guest networking can reach your LAN.

## Updates

Public app releases are signed and notarized. In-app updates verify signed
archives before installation.

See [agent access and privacy](docs/security.md) for access controls and revocation.
