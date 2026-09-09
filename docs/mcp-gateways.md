# MCP gateways: Pipedream and Zapier

Checked 2026-09-09. Public documentation and unauthenticated metadata were inspected;
no real OAuth client was registered, account authorized or provider tool executed.

## Pipedream — included in the catalogue

The [end-user setup guide](https://pipedream.com/docs/connect/mcp/users) specifies
`https://mcp.pipedream.net/v2`. This is distinct from the developer Connect endpoint,
which requires project credentials and user-routing parameters.

Its path-specific resource discovery URL returns 404. The
[root metadata](https://mcp.pipedream.net/.well-known/oauth-protected-resource)
declares `https://mcp.pipedream.net` as its resource and
`https://mcp.pipedream.com` as its issuer. The
[authorization metadata](https://mcp.pipedream.com/.well-known/oauth-authorization-server)
advertises dynamic registration, public clients, authorization-code/refresh grants
and S256 PKCE.

Noodle now accepts a same-origin canonical root resource, retaining `/v2` as the
actual MCP endpoint. It does not accept another host, effective port or unrelated
resource path. Tests cover discovery fallback, audience preservation during sign-in
and refresh, unchanged transport routing, and rejection before registration.

Selecting Pipedream creates an ordinary independent Noodle MCP connection with a
bundled provider icon and editable defaults. Instructions require checking the
target service/account and asking when ambiguous. Returned account-connection links
are for the user to complete in the browser, not for bots to collect credentials.
Assignment controls the Pipedream connection, not individual downstream accounts.
The developer API documents explicit account IDs; that behavior has not been
verified for the public `/v2` tools. Native callback acceptance and real tool
discovery still require a user-authorized sign-in test.

## Zapier — research only, not added

The [connection guide](https://docs.zapier.com/mcp/overview/how-connections-work)
uses the shared endpoint `https://mcp.zapier.com/api/v1/connect` over Streamable
HTTP. OAuth auto-provisions a server for the client. The
[tool guide](https://docs.zapier.com/mcp/overview/how-tools-work) describes dynamic
action discovery/enabling and an alternative fixed manual toolset.

Live checks found:

- [Resource metadata](https://mcp.zapier.com/.well-known/oauth-protected-resource/api/v1/connect)
  exactly matches that MCP endpoint and identifies `https://mcp.zapier.com` as issuer.
- [Authorization metadata](https://mcp.zapier.com/.well-known/oauth-authorization-server)
  advertises `/api/v1/oauth/register`, public-client authentication (`none`), S256,
  and authorization-code/refresh grants. These match Noodle's discovery requirements.

The metadata therefore looks compatible, but does not prove that registration will
accept Noodle's native custom-scheme callback. Zapier's
[unlisted-client guide](https://docs.zapier.com/mcp/get-started/connect/other)
documents a manually generated connection token instead. Noodle does not currently
offer token entry. Do not impersonate a supported client or place tokens in URLs.

Next verification: with approval to create a test connection, register Noodle using
its real client name and callback, complete browser consent, and inspect tools
without executing app actions. If custom registration is rejected, use a separately
designed Keychain-backed bearer-token option or arrange supported-client onboarding;
neither is implemented by this change.
