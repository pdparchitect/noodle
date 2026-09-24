# Noodle in the enterprise

Give employees AI agents that work alongside them on the Macs they already use.
Prepare research, draft internal documents, and delegate repetitive work to
agents with their own persistent workspaces. Noodle brings those agents and
your business tools together in one native Mac application.

## Built into the Mac workflow

Work with agents through familiar Mac interactions. Share files into
conversations, preview attachments with Quick Look, launch actions from
Shortcuts, and dictate with on-device transcription on supported Macs. Native
notifications bring you back when there's something to review. Give agents
specialist roles and bring several into a group around a shared goal.

Agents start restricted to their own workspace and cannot read your personal
files. Sign-ins for connected tools stay in the macOS Keychain. Microphone and
screen capture follow macOS privacy permissions. Unrestricted access is an
explicit per-agent choice in **Settings → Sandbox**.
[Read about agent access and privacy](security.md).

## Deploy through familiar IT tools

Use the Mac management tools your IT team already knows. Noodle's signed,
notarized app can be packaged for distribution through
[Jamf Pro](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Package_Deployment)
or another Mac MDM with
[package deployment](https://support.apple.com/en-gb/guide/deployment/dep873c25ac4/web),
so a pilot can grow through your existing device groups and rollout processes.

Noodle runs on macOS 26 or later. Current releases are app ZIPs for IT to package.
Noodle can install agent programs itself, or use ones your team already
manages; each signs in with its own account.

## Keep work local and connect where it matters

Keep conversations and agent workspaces on the Mac, with a choice of AI
providers. The experimental Apple Intelligence option uses Apple's on-device
model on supported Macs running macOS 26 or later. Cloud agents use your
existing provider accounts; work sent to cloud models and connected services is
handled under those providers' data policies.

[Connect compatible business services](mcp-connections.md) and choose the tools
each agent can use. For development and automation,
[Noodle Computer](../Computer/README.md) adds Linux workspaces that cannot see
the Mac's folders.

Start with one team and a task they repeat every week.
[Set up your first agent](harness-setup.md) and [put it to work](usage.md).

[Documentation](README.md) · [Noodle](../README.md)
