# Connect tools

Give bots access to services such as Notion, Linear, and Pipedream through MCP.

1. Open **Settings → Tools → Add Tools**.
2. Choose a service, or **Custom MCP…** for a public HTTPS MCP endpoint.
3. Complete sign-in in your browser.
4. Create or edit a bot, add the connection in **Tools**, and save the bot.

You can also choose **New Tool…** from the bot's tool picker. The connection is
saved separately; cancelling the bot editor leaves it in Settings without assigning it.

## Accounts and permissions

For two accounts on the same service, add two connections with clear names such
as **Notion Work** and **Notion Personal**. Each has separate credentials. Editing
a connection's description or instructions affects every bot assigned to it.

Assignment lets the bot use the provider permissions you approved, without a
separate Noodle approval for every call. Noodle must stay open to run tools.
Remove a bot's assignment to stop future access. Remove a connection to delete its
local credentials; revoke the provider's grant in its connected-app settings too.
Calls already sent cannot be undone. If a write times out, check the result before retrying.

Reconnecting may select a different account while keeping existing bot assignments.
Add a separate connection when you need account separation.

## Supported servers

Noodle supports public HTTPS MCP servers using Streamable HTTP and browser OAuth
with dynamic client registration. Servers must accept a native app callback and
PKCE. Local stdio servers, API-key entry, manual client secrets, and legacy SSE
endpoints are not supported.

Catalogue entries are checked for compatible metadata, but providers may still
restrict accounts, plans, or sign-in callbacks. Follow the error shown in Settings.
Register only servers you trust. See [gateway notes](mcp-gateways.md) for Pipedream
and Zapier, or [catalogue maintenance](tool-catalogue.md) to add a preset.

## Developer reference

Noodle generates a skill for each assigned connection in the bot's `.agents/skills`.
Run these commands from that skill's directory:

```sh
./mcpshim tools
./mcpshim inspect --tool TOOL_NAME
./mcpshim call --tool TOOL_NAME --input '{"argument":"value"}'
./mcpshim resources
./mcpshim read-resource --uri 'reports://monthly/123'
```

Calls also accept a JSON object on stdin. Results preserve text, metadata,
`structuredContent`, and `isError`; tool errors exit nonzero.

### Files

Binary images, audio, and embedded resource blobs are saved automatically under
`<bot-workspace>/.noodle/mcp-attachments/<call-id>/`. Each binary block in the CLI
output becomes a Noodle `file` block with an absolute `path`, `mimeType`, decoded
`bytes`, and original `sourceType` (`image`, `audio`, or `resource`). Other fields,
including annotations and embedded resource metadata, remain; only the encoded
`data` or `blob` is removed. Filenames are generated from content positions and MIME
types, with `.bin` for unknown types. Files remain after the command exits and can
be inspected or sent through Messenger; extraction does not post a message.

Use `--raw` on `call` or `read-resource` to return the original MCP result JSON
without saving files. Resource links are not fetched automatically. Use
`read-resource --uri URI` to retrieve an MCP resource through the assigned server;
its binary `contents` entries become file blocks in the same way. Resource listing
and reading require a server that supports those operations.

For file inputs, put an `@file` reference in the JSON field accepted by the tool:

```sh
./mcpshim call --tool upload_document --input '{"filename":"report.pdf","mimeType":"application/pdf","data":"@report.pdf"}'
```

The tool and field names above are examples; inspect the actual tool schema first.
Any JSON string value starting with `@` reads a file and substitutes its base64
content, including values inside nested objects and arrays. `@@name` sends the
literal string `@name`. Property names are never expanded. Filename and MIME
fields are not inferred. `--raw` affects output only; input references still expand.

Paths resolve from the current directory, which is the skill directory in the
examples above. Absolute paths within the bot workspace also work. Input files
must be regular workspace files without symlinks, hard links, or `..` components.
Missing files and oversized inputs fail before the remote call.

Arguments are limited to **1 MiB after expansion**, including JSON and base64
overhead. Result JSON is limited to **8 MiB before extraction**. These limits still
apply with `--raw`. Malformed binary results fail without retaining partial files;
the remote operation may already have completed, so verify changes before retrying.

### Bridge and tests

The CLI sends requests through `.noodle/mcp-bridge`. Noodle checks the bot's session
and current assignment, then calls the server using the Swift MCP SDK. OAuth
credentials stay in Keychain. Requests are consumed before dispatch and are never
automatically replayed after a crash. Calls are serialized per account.

Use `swift test --disable-sandbox --filter NoodleMCPTests` for protocol tests and
`zsh Tests/mcp-fixture.sh --check` for the isolated signed CLI/broker check.
`zsh Tests/mcp-fixture.sh --open` opens an interactive sign-in fixture; it requires
a real provider account. Its discovery check does not execute provider tools.
`zsh Tests/mcp-window-routing.sh` checks repeated main-window launches, closing and
reopening, separate conversation windows, and synthetic sign-in callbacks in a
sandboxed app without accounts or bots.

[Agent access](security.md) · [Documentation](README.md)
