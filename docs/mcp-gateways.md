# MCP gateways

Gateway connections can expose several services through one MCP connection.
Noodle assignments apply to that connection as a whole, so check the intended
service and account before acting.

## Pipedream

Pipedream is included in the catalogue at `https://mcp.pipedream.net/v2`.
Use this [end-user endpoint](https://pipedream.com/docs/connect/mcp/users);
the developer Connect endpoint requires a different setup.

Its OAuth metadata uses the same-origin root as the resource while tool requests
stay on `/v2`. Metadata checks on 2026-09-09 passed. Browser consent and live tool
discovery still need verification with a real account. Users complete any further
account-connection links in their browser.

## Zapier

Zapier is not included. Metadata checks on 2026-09-09 looked compatible, but
acceptance of Noodle's native sign-in callback remains unverified. Zapier's
[unlisted-client setup](https://docs.zapier.com/mcp/get-started/connect/other)
uses a manual token, which Noodle does not support.

Before adding it, verify registration, browser consent, and tool discovery with a
test account. Metadata compatibility alone is insufficient.

[Connect tools](mcp-connections.md)
