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
Providers may restrict accounts or plans.

Gateway connections can expose several services. Assigning one to a bot grants
access to the connection as a whole; check the intended service and account
before acting. For Pipedream, choose its catalogue entry, which uses the
end-user endpoint at `https://mcp.pipedream.net/v2`, and complete any additional
account-connection steps in your browser. Zapier is not in the catalogue;
its manual-token setup is unsupported.

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
in sync. In the Google Cloud project that owns the clients, enable each product
and MCP API and declare the consent scopes. Follow Google's setup guides for [Gmail](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server),
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

### JavaScript workflows

Use the macOS JavaScriptCore runtime to filter results, loop, or chain calls on
the connection selected by the skill-local shim:

```sh
./mcpshim eval 'print(mcp.tools().tools.map(t => t.name))'
./mcpshim run workflow.js
./mcpshim run - <<'JS'
const tools = mcp.tools().tools;
print(tools.filter(tool => /search/i.test(tool.name)));
JS
```

Scripts have these synchronous methods:

| Method | Result |
| --- | --- |
| `mcp.tools()` | Tool listing, including `tools` |
| `mcp.inspect(name)` | One tool's schema and metadata |
| `mcp.call(name, input = {}, options = {})` | Complete MCP tool result |
| `mcp.resources()` | Resource listing, including `resources` |
| `mcp.readResource(uri, options = {})` | Complete resource result |

Results are JavaScript objects with the same fields as CLI JSON. Both methods
with `options` accept `{raw: true}` to skip binary extraction. File references
(`@file`, `@@literal`) and saved attachments work as described above. Paths
resolve from the invocation's current directory, including when the script is
in a different workspace subdirectory.

`print(value)` writes one JSON value followed by a newline to stdout.
`console.log`, `info`, `warn`, `error`, `debug`, and `dir` write diagnostics to
stderr. Logging handles `undefined`, errors (including their stacks), and
circular objects. The logging methods support `%s`, `%d`, `%i`, `%f`, `%o`,
`%O`, and `%%` formatting; `dir` inspects its first argument directly.
`console.trace(...values)` prints a labelled call stack, and
`console.assert(condition, ...values)` logs when the condition is false.
Console logging, including `error` and `assert`, does not change the exit status.
Results and the final expression do not print implicitly. Bridge failures and tool results with
`isError: true` throw; tool errors retain the complete result as `error.result`:

```js
try {
  const result = mcp.call('TOOL_NAME', {argument: 'value'});
  print(result.structuredContent ?? result.content);
} catch (error) {
  console.log(error.message, error.result ?? null);
  throw error;
}
```

Uncaught errors print a readable message, source location, and available stack
frames to stderr, then exit nonzero. Syntax errors include their source line;
runtime and MCP errors retain the script's calling functions and line numbers.
Caught operation errors may be handled and the
workflow continued; calls are never automatically retried. Each invocation
uses a fresh context and one connection. There are no imports, Node/browser
APIs, shell execution, or general filesystem/network APIs. Async workflows
are unsupported; use ordinary loops and synchronous calls.

Script files must be regular UTF-8 files inside the bot workspace, without
symlinks, hard links, or `..` components. Source is limited to **1 MiB**.
Each invocation allows **100 MCP operations**, **8 MiB combined stdout and
diagnostic output**, and **300 seconds**, including input loading and remote
calls. Use `--timeout SECONDS` after the file or code to choose **1–3600 seconds**.
Call/output limit failures remain fatal even if caught. The deadline also stops
infinite loops. Timing out cannot undo remote changes or guarantee cancellation
of an in-flight call; verify writes before retrying. Existing per-call limits
still apply.

Scripts execute in the helper under the harness's existing process sandbox.
Noodle authorizes every request through the same workspace broker, and retains
the credentials. JavaScriptCore adds no external runtime or helper entitlements.

Validate catalogue, protocol, and scripting changes with:

```sh
swift test --disable-sandbox --filter 'ToolCatalogTests|NoodleMCPTests|NoodleMCPScriptingTests'
zsh Tests/build-sandbox-cli-fixture.sh
NOODLE_TEST_CLI_APPLICATION="$PWD/.build/Sandbox CLI Tests.app" \
  swift test --disable-sandbox --filter BridgeCLISandboxTests
zsh Tests/mcp-fixture.sh --check
```

Use `--open` for the interactive sign-in fixture. `zsh Tests/mcp-window-routing.sh`
checks window routing and synthetic callbacks. Real provider consent and tool calls
need separate verification.

[Agent access](security.md) · [Documentation](README.md)
