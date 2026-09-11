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
```

Calls also accept a JSON object on stdin. Results preserve MCP structured content
and `isError`; tool errors exit nonzero.

The CLI sends requests through `.noodle/mcp-bridge`. Noodle checks the bot's session
and current assignment, then calls the server using the Swift MCP SDK. OAuth
credentials stay in Keychain. Requests are consumed before dispatch and are never
automatically replayed after a crash. Calls are serialized per account.

Use `swift test --disable-sandbox --filter NoodleMCPTests` for protocol tests and
`zsh Tests/mcp-fixture.sh --check` for the isolated signed CLI/broker check.
`zsh Tests/mcp-fixture.sh --open` opens an interactive sign-in fixture; it requires
a real provider account. Its discovery check does not execute provider tools.

[Agent access](security.md) · [Documentation](README.md)
