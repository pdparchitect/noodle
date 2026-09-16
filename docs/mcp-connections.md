# Connect tools

1. Open **Settings → Tools → Add Tools**.
2. Choose a service, or **Custom MCP…** for a public HTTPS MCP endpoint.
3. Complete sign-in in your browser.
4. Add the connection under **Tools** when creating or editing a bot, then save.

**New Tool…** in the bot's tool picker opens the same flow. Connections are saved
separately; cancelling the bot editor leaves the connection unassigned.

## Accounts and permissions

Add separate, clearly named connections for different accounts. Each has its own
credentials. Reconnecting can change the account while keeping bot assignments.
Editing a connection's instructions affects every bot assigned to it.

Assigned bots can use the approved permissions without per-call Noodle approval.
Noodle must remain open. Removing an assignment stops future access; removing a
connection deletes its local credentials. Revoke access at the provider too when
needed. Check timed-out writes before retrying: the operation may have completed.

## Supported servers

Public HTTPS MCP servers using Streamable HTTP, browser OAuth, native app callbacks
and S256 PKCE. Clients use dynamic registration or catalogue-supplied configuration.
Local stdio, API-key entry, manual client secrets and legacy SSE are unsupported.
Providers may restrict accounts or plans; see [gateway notes](mcp-gateways.md).

### Google Workspace (Experimental)

Each service is a separate connection with multiple-account support:

| Service | Capabilities | Scopes under `https://www.googleapis.com/auth/` |
| --- | --- | --- |
| Gmail | Read mail, create drafts, manage labels; no send tool currently. | `gmail.modify` |
| Google Docs | Read and edit documents; use Drive to find or create them. | `documents` |
| Google Drive | Find, read, download, create and copy files. | `drive.readonly`, `drive.file` |
| Google Calendar | Find availability and manage events and invitations. | `calendar.calendarlist.readonly`, `calendar.events` |

The preview is limited to configured test accounts. Testing refresh tokens expire
in seven days; permission changes also require reconnection. Revoking Google access
can affect that account across the project. Drive writes are limited to files
available to the app, and Google's [file eligibility rules](https://developers.google.com/workspace/drive/api/guides/drive-mcp-server-file-eligibility)
can further restrict access.

## Add a catalogue entry

Add the endpoint, description, instructions and icon name to
[`ToolCatalog.swift`](../Sources/NoodleCore/ToolCatalog.swift). Set maturity to
`.experimental` for a badge and placement at the end of the list. Bundle its `.icon`
in `Support/ToolIcons` and record the update URL in [SOURCES.md](../Support/ToolIcons/SOURCES.md).
Set `MCPToolConfiguration.oauth` for a fixed public client; leave it unset for discovery
and registration. Configuration is matched by exact endpoint; the OAuth engine stays generic.

Google's shared native clients live in
[`ToolOAuthConfigurations.swift`](../Sources/NoodleCore/ToolOAuthConfigurations.swift).
Keep their reversed-ID callback schemes in `Support/Info.plist` and `scripts/build-app.sh`
in sync. Project `noodle-508811` needs each product and MCP API enabled and the consent
scopes declared. Follow Google's setup guides for [Gmail](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server),
[Docs](https://developers.google.com/workspace/docs/api/guides/configure-mcp-server),
[Drive](https://developers.google.com/workspace/drive/api/guides/configure-mcp-server) and
[Calendar](https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server).
Check per-tool scopes for writes; setup examples may be read-only.

## Developer reference

Run from the connection's generated skill directory in the bot's `.agents/skills`:

```sh
./mcpshim tools
./mcpshim inspect --tool TOOL_NAME
./mcpshim call --tool TOOL_NAME --input '{"argument":"value"}'
./mcpshim resources
./mcpshim read-resource --uri 'reports://monthly/123'
```

Calls also accept JSON on stdin. Results preserve text, metadata, `structuredContent`
and `isError`; tool errors exit nonzero. Binary results are saved under
`<bot-workspace>/.noodle/mcp-attachments/<call-id>/` and returned as `file` blocks
with `path`, `mimeType`, `bytes` and `sourceType`. Files remain after the call.
Use `--raw` on `call` or `read-resource` for original JSON without extraction.
Resource links are not fetched automatically; resource operations require server support.

In input JSON, `"@report.pdf"` substitutes a workspace file's base64 content;
`"@@name"` sends literal `"@name"`. Inspect the tool schema for the correct field.
Paths resolve from the current directory; absolute workspace paths work too.
Symlinks, hard links and `..` components are rejected. Filename and MIME fields
are not inferred. Limits are **1 MiB arguments after expansion** and **8 MiB result
JSON before extraction**, including with `--raw`.

Requests use `.noodle/mcp-bridge`. Noodle checks the session and assignment, keeps
credentials in Keychain and serializes calls per account. Consumed requests are
never automatically replayed after a crash.

Validate catalogue and protocol changes with:

```sh
swift test --disable-sandbox --filter 'ToolCatalogTests|NoodleMCPTests'
zsh Tests/mcp-fixture.sh --check
```

Use `--open` for the interactive sign-in fixture. `zsh Tests/mcp-window-routing.sh`
checks window routing and synthetic callbacks. Real provider consent and tool calls
need separate verification.

[Agent access](security.md) · [Documentation](README.md)
