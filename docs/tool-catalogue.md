# Add a tool preset

The catalogue in **Settings → Tools → Add Tools** is defined in
[`ToolCatalog.swift`](../Sources/NoodleCore/ToolCatalog.swift). It is the source
for service names, endpoints, descriptions, instructions, and icon names.

1. Add a `ToolDefinition` with a unique ID and an MCP configuration.
2. Check that the endpoint meets the [connection requirements](mcp-connections.md#supported-servers).
3. Add its icon to `Support/ToolIcons` and record the origin in [SOURCES.md](../Support/ToolIcons/SOURCES.md).
4. Run `swift test --disable-sandbox --filter ToolCatalogTests` and the signed MCP fixture described in [connection tests](mcp-connections.md#developer-reference).

Metadata must identify the endpoint or its same-HTTPS-origin canonical root,
with matching issuer metadata, public-client registration, and S256 PKCE support.
A metadata check does not prove browser consent or tool calls work. Keep those
verification results distinct; do not add secret-bearing or account-specific URLs.

Icons are bundled, so browsing the catalogue makes no network requests. Missing
icons use a fallback. Brand marks identify providers and do not imply endorsement.

`ToolDefinition` contains shared display information; `ToolConfiguration` owns
type-specific settings. A new tool type needs its own configuration, setup, and
runtime implementation. Keep MCP credentials and OAuth behavior in the MCP layer.

[Gateway compatibility notes](mcp-gateways.md) · [Documentation](README.md)
