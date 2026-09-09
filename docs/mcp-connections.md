# Built-in MCP connections

Settings → Tools → Add Tools offers a searchable [tool catalogue](tool-catalogue.md)
and a **Custom MCP…** form. The bot assignment picker also offers **New Tool…**
beside Done. Tools is the umbrella; MCP is a connection type.

The custom MCP form registers named account connections. Start with
https://mcp.notion.com/mcp: add a name, URL, optional short description and instructions,
then complete the provider's consent screen. Use distinct names such as **Notion Work**
and **Notion Personal** when adding the same endpoint twice.

Each registration has a UUID, its own OAuth client registration and credentials,
and its own stable skill name. URLs and display names are never credential keys.
Renaming a connection preserves its identity. Removing it removes all bot assignments
and its local Keychain item, but does not revoke the provider's grant: use the
provider's connected-app settings for that.

## Assigning and using a connection

Create/Edit Bot → Tools includes an add/remove connection picker. General holds the
description and backstory; Harness holds harness, model and effort settings. Tabs
preserve unsaved edits and fit the sheet to their contents, with Reduce Motion respected.
The Tools picker can select a saved connection
before sign-in, but calls require a successful sign-in. Assignment makes the provider's
tools available to that bot under the scopes the user consented to; there is no extra
per-tool approval dialog in Noodle. Agents must still follow user authorization.

Workspace synchronization writes one generated skill per assigned connection under
`.agents/skills` **relative to the bot workspace**, not the user's home. Each skill
includes the name and description in frontmatter, with instructions and CLI usage in
the body. No account UUID appears in the file or directory name. Stable, readable
names such as `mcp-notion` use numbered suffixes for duplicate names (`mcp-notion-2`).
Existing UUID-suffixed skills migrate automatically without changing account identities,
credentials or assignments. Renaming a connection does not rename its generated skill.
Existing Claude skill links expose the same generated skill to Claude.

Synchronization runs on application load, bot creation/edit, connection changes and
every agent launch/retry. Removing access deletes only this generator's files, preserving
unrelated skills and notes. No harness-native MCP configuration is created or modified.

The symlinked, bundled `mcpshim` executable offers:

~~~sh
./mcpshim tools
./mcpshim inspect --tool TOOL_NAME
./mcpshim call --tool TOOL_NAME --input '{"argument":"value"}'
~~~

Run these commands from the directory containing SKILL.md. The skill-local executable
infers its connection from that directory; Noodle resolves the name against the bot's
current assignments. This routing convention is not an authorization boundary.
The shared CLI still accepts `--connection UUID` for existing integrations, but the
skill-local CLI rejects explicit connection overrides.
Calls also accept a JSON object on stdin. Tool discovery handles pagination; inspection
returns the complete schema. Calls return the MCP result, including structured content
and `isError`. An MCP tool error exits nonzero. This is a Noodle-built Swift CLI inspired
by mcpshim, not a claim of command-line compatibility with that project.

## Client/broker boundary

~~~text
Harness → generated skill → bundled mcpshim
                              ↓ private workspace request files
                         Noodle app
                              ↓ OAuth + official Swift MCP client
                         Remote MCP server
~~~

Noodle is the MCP client. It uses the official Swift SDK's Streamable HTTP transport
and protocol implementation. The app must remain open; no daemon or TCP listener is
installed. CLI request/response files live in each bot's `.noodle/mcp-bridge` directory.

The broker validates an app-generated per-agent session capability and the current
assignment before dispatch and before calling a tool. Removing assignment denies queued
calls and suppresses undelivered results. A request already sent to the provider cannot
be undone. Requests are consumed before dispatch and never automatically replayed after
a crash. A timeout may follow a successful remote write: verify before retrying.

Calls are serialized per account to avoid rotating-refresh-token races. A fresh MCP
protocol session is used per operation, avoiding shared server session state between bots.
Arguments are limited to 1 MiB, each remote response to 8 MiB, and each active operation
to 90 seconds within its 120-second request deadline. There are at most 16 active broker
requests. Errors are sanitized; tokens are not written to workspaces, skills or logs.

## OAuth and storage

The initial implementation supports public HTTPS remote MCP endpoints with protected
resource metadata, authorization-server discovery and dynamic client registration for
public clients. Authorization Code + PKCE S256 opens the normal default browser, so
existing profiles and password-manager extensions remain available, and returns through
the app's registered URL callback. State, callback target and issuer are validated.
SwiftUI routes callbacks to an existing chat scene instead of creating another window,
then restores the Settings window that initiated sign-in, including if it was minimized.
Unrelated or stale callbacks cannot consume an active sign-in; cancellation and a
three-minute timeout clear the pending request. Choose the intended account in the
provider's browser UI when connecting another account; connections retain separate credentials.
Redirects are not followed during metadata, registration, token or MCP HTTP requests.

Client registration is persisted before opening the browser and reused after restart.
Access and rotated refresh tokens are saved together in the macOS login Keychain with
the system-created calling-app ACL. Existing items retain their access controls when
tokens are refreshed. This matches Noodle's signed, non-provisioned distribution;
it does not use a plaintext token file or a shared Keychain access group.
Apple documents the implicit calling-app access list in
[SecAccessCreate](https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:)).
The signed MCP fixture checks synthetic credential creation, cross-process reads,
in-place refresh and metadata preservation, and deletion without touching user sign-ins.
An invalid refresh grant requires reconnecting and is not repeatedly retried.

The Swift SDK is pinned in Package.swift/Package.resolved. Version 0.12.1 supplies MCP
protocol handling and metadata URL construction. Noodle owns the OAuth flow because
that version's built-in flow does not expose persistent dynamic client registration
and only accepts HTTPS/loopback redirects. Native URL callbacks avoid an incoming-network
entitlement. SDK and dependency licenses ship as Resources/*-LICENSE.txt.

## Limits and trust

- OAuth resource metadata must identify the exact endpoint or a canonical root on
  the same HTTPS origin (including effective port). Unrelated paths, cross-origin
  resources, credentials and fragments are rejected. The canonical resource is used
  for authorization, token exchange and refresh only; requests still go to the
  saved MCP endpoint. This supports Pipedream's root resource with its `/v2` transport.
- No stdio servers, API-key entry, manual OAuth client secrets, legacy HTTP+SSE endpoints,
  resources/prompts commands or automatic incremental-consent flow in this first version.
- A server must accept dynamic registration with a native custom-scheme redirect.
  Other registration methods need explicit future support.
- Public-URL checks reject credentials and literal/local private hosts, but are not a
  DNS-rebinding defense. Register only servers you trust. OAuth metadata, tool descriptions,
  results and icon data are untrusted. Metadata images are restricted to bounded raster
  data or same-origin HTTPS, fetched without OAuth credentials; other icons use a system symbol.
- Assignment checks are not hard isolation against a deliberately unrestricted agent
  that can read another agent's workspace or access the user's system. Restricted harness
  workspace boundaries remain important. The CLI has no additional entitlements.
- Reconnecting an existing account may choose a different provider account. Its existing
  assignments remain; add a separate connection when account separation is intended.

## Verification

`swift test --disable-sandbox` covers duplicate endpoints, stable identity, skill lifecycle,
request bounds, OAuth state validation, persistent registrations, refresh serialization,
invalid-grant handling and real SDK tool discovery/call results using a mocked transport.

`zsh Tests/mcp-fixture.sh --open` builds a separately signed, sandboxed test app using the
actual Settings, assignment picker and broker, with isolated data and no harness runtime.
Connect Notion, assign it to the test bot and press **Test CLI Tool Discovery**. This tests
CLI → app → MCP without executing any provider tools. Close/reopen to test persistence;
add another named connection to test separate consent. Live OAuth requires user consent
and is not part of unattended tests.

After closing the interactive fixture, run `zsh Tests/mcp-fixture.sh --check-live` to
verify the saved Notion Test connection through the CLI without running a harness.
This uses only tool discovery, then restores the test bot's previous assignments.
The live check passed on 2026-09-09: native Notion authorization, saved Keychain/client
registration across restart, and 42 tools returned through the signed CLI and broker.
No Notion tools were executed and no pages were read or changed.

`zsh Tests/mcp-fixture.sh --check` uses disposable data and no provider calls to verify
unassigned rejection, missing-sign-in handling, skill generation and removal through
the real signed CLI and app-side broker.

`zsh Tests/smoke-test.sh` verifies the complete signed bundle, helper signatures, unchanged
seven-key app sandbox policy, dependency linkage and bundled licenses.

References: [mcpshim](https://github.com/mcpshim/mcpshim),
[official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk),
[Notion client guidance](https://developers.notion.com/guides/mcp/build-mcp-client),
[Apple's macOS Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
