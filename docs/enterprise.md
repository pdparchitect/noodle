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

The same integration carries through to security: Noodle runs in App Sandbox,
macOS enforces restricted agents' file access, and Keychain holds connected-tool
OAuth credentials. Microphone and screen capture follow macOS privacy
permissions. Unrestricted access is an explicit per-agent choice in
**Settings → Security**. [Explore the security model](security.md).

## Deploy through familiar IT tools

Use the Mac management tools your IT team already knows. Noodle's signed,
notarized app can be packaged for distribution through
[Jamf Pro](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Package_Deployment)
or another Mac MDM with
[package deployment](https://support.apple.com/en-gb/guide/deployment/dep873c25ac4/web),
so a pilot can grow through your existing device groups and rollout processes.

Noodle runs on macOS 15 or later. Current releases are app ZIPs for IT to package;
external agent providers have their own installation and sign-in steps.

## Keep work local and connect where it matters

Keep conversations and agent workspaces on the Mac, with a choice of AI
providers. The experimental Apple Intelligence integration offers direct access
to Apple's on-device model on supported Macs running macOS 26 or later.
Cloud agents use your existing provider accounts; work sent to cloud models and
connected services is processed under those providers' data policies.

[Connect compatible business services](mcp-connections.md) through MCP and assign
the tools each agent needs. For development and automation,
[Noodle Computer](../Computer/README.md) adds Linux workspaces without mounting
host folders.

Start with one team and a task they repeat every week.
[Set up your first agent](harness-setup.md) and [put it to work](usage.md).

[Documentation](README.md) · [Noodle](../README.md)
