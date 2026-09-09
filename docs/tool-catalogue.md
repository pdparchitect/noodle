# Tool catalogue

Tools is the user-facing umbrella. MCP is the first supported **tool type**.

## Extension boundary

- `ToolDefinition` holds shared catalogue identity, name, summary, default instructions and icon.
- `ToolConfiguration` is a typed payload; `MCPToolConfiguration` alone owns an MCP endpoint.
- `ToolCatalogView` searches and presents definitions without protocol-specific fields.
- `ToolCreationSheet` dispatches to the setup UI for the selected type.
- MCP registration, OAuth, Keychain storage, assignments, broker and generated skills remain MCP-specific. No registry migration is required.
- A future tool type adds its own configuration and setup/runtime implementation; do not put unrelated credentials into `MCPConnectionRecord` or pretend it is an MCP.

## User flow

The bot assignment popover has **New Tool…** opposite **Done**. It dismisses before
opening the creation sheet. Settings → Tools → Add Tools uses the same catalogue.
Selecting a service adds it immediately with its fixed MCP endpoint, default
description and service-specific instructions, then opens browser sign-in.
Repeated additions get distinct suggested names (Notion, Notion 2, etc.).
**Custom MCP…** opens the manual MCP form. Both flows require browser sign-in
with automatic public-client registration; neither accepts API keys.

Nothing is saved or registered merely by browsing the catalogue, opening Custom
MCP, going Back or cancelling its form. Selecting a preset, or pressing
**Add & Connect** in the custom form, saves a separate account connection and
starts the existing authorization flow. From the bot picker it also selects the
new connection in that bot's unsaved draft. Saving the bot applies assignment; cancelling the bot
does not assign it, but the separately created account remains in Settings.
Multiple accounts for one service retain independent UUIDs, credentials and skills.
Users can customize the name, description and instructions through Edit in Settings
or the pencil beside an assigned tool. Saving customizations does not reconnect or
overwrite them with catalogue defaults. Edits apply to all bots sharing that connection.

## Catalogue inclusion check — 2026-09-09

The supplied list was filtered to fixed public HTTPS endpoints without secret
headers, secret URL parameters, per-account URLs or legacy SSE transport.
Only entries whose public metadata is compatible with Noodle's current discovery
path are included: an exact resource or same-HTTPS-origin canonical root resource,
exact issuer matching, a registration endpoint,
and no advertised exclusion of public clients or S256 PKCE.

These are **read-only metadata checks**, not end-to-end account authorization
certification. No registration POST, token exchange, account access or remote
tool call was made during catalogue verification. Providers can still restrict
redirect URIs, plans, organizations or registration. Existing errors and retry
controls remain authoritative. Cross-origin resources and unrelated resource paths
remain rejected; a canonical resource never rewrites the MCP transport endpoint.

[Notion's client guide](https://developers.notion.com/guides/mcp/build-mcp-client)
and [Linear's MCP documentation](https://linear.app/docs/mcp) document the keyless
dynamic-registration flow. Each provider's checked discovery sources follow:

| Tool | MCP endpoint | Resource metadata | Authorization metadata |
| --- | --- | --- | --- |
| Apollo | https://mcp.apollo.io/mcp | [Resource](https://mcp.apollo.io/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.apollo.io/.well-known/oauth-authorization-server) |
| Attio | https://mcp.attio.com/mcp | [Resource](https://mcp.attio.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://app.attio.com/.well-known/oauth-authorization-server) |
| Buildkite | https://mcp.buildkite.com/mcp | [Resource](https://mcp.buildkite.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.buildkite.com/.well-known/oauth-authorization-server) |
| Canva | https://mcp.canva.com/mcp | [Resource](https://mcp.canva.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.canva.com/.well-known/oauth-authorization-server) |
| Clay | https://api.clay.com/v3/mcp | [Resource](https://api.clay.com/.well-known/oauth-protected-resource/v3/mcp) | [Authorization](https://api.clay.com/.well-known/oauth-authorization-server) |
| ClickUp | https://mcp.clickup.com/mcp | [Resource](https://mcp.clickup.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.clickup.com/.well-known/oauth-authorization-server) |
| Cloudflare | https://mcp.cloudflare.com/mcp | [Resource](https://mcp.cloudflare.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.cloudflare.com/.well-known/oauth-authorization-server) |
| crmkit | https://api.crmkit.ai/mcp | [Resource](https://api.crmkit.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://api.crmkit.ai/.well-known/oauth-authorization-server) |
| Exa | https://mcp.exa.ai/mcp | [Resource](https://mcp.exa.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://auth.exa.ai/.well-known/oauth-authorization-server) |
| Fireflies | https://api.fireflies.ai/mcp | [Resource](https://api.fireflies.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://api.fireflies.ai/.well-known/oauth-authorization-server) |
| Granola | https://mcp.granola.ai/mcp | [Resource](https://mcp.granola.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp-auth.granola.ai/.well-known/oauth-authorization-server) |
| Higgsfield | https://mcp.higgsfield.ai/mcp | [Resource](https://mcp.higgsfield.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://clerk.higgsfield.ai/.well-known/oauth-authorization-server) |
| Jam | https://mcp.jam.dev/mcp | [Resource](https://mcp.jam.dev/.well-known/oauth-protected-resource) | [Authorization](https://api.jam.dev/.well-known/oauth-authorization-server) |
| Jotform | https://mcp.jotform.com | [Resource](https://mcp.jotform.com/.well-known/oauth-protected-resource) | [Authorization](https://oauth2.jotform.com/.well-known/oauth-authorization-server) |
| Linear | https://mcp.linear.app/mcp | [Resource](https://mcp.linear.app/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.linear.app/.well-known/oauth-authorization-server) |
| Mapbox | https://mcp.mapbox.com/mcp | [Resource](https://mcp.mapbox.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.mapbox.com/.well-known/oauth-authorization-server) |
| Morningstar | https://mcp.morningstar.com/mcp | [Resource](https://mcp.morningstar.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.morningstar.com/.well-known/oauth-authorization-server/mcp) |
| Neon | https://mcp.neon.tech/mcp | [Resource](https://mcp.neon.tech/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.neon.tech/.well-known/oauth-authorization-server) |
| Netlify | https://netlify-mcp.netlify.app/mcp | [Resource](https://netlify-mcp.netlify.app/.well-known/oauth-protected-resource/mcp) | [Authorization](https://netlify-mcp.netlify.app/.well-known/oauth-authorization-server) |
| Notion | https://mcp.notion.com/mcp | [Resource](https://mcp.notion.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.notion.com/.well-known/oauth-authorization-server) |
| Parallel Search | https://search-mcp.parallel.ai/mcp | [Resource](https://search-mcp.parallel.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://platform.parallel.ai/.well-known/oauth-authorization-server) |
| Parallel Tasks | https://task-mcp.parallel.ai/mcp | [Resource](https://task-mcp.parallel.ai/.well-known/oauth-protected-resource/mcp) | [Authorization](https://platform.parallel.ai/.well-known/oauth-authorization-server) |
| PayPal | https://mcp.paypal.com/mcp | [Resource](https://mcp.paypal.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.paypal.com/.well-known/oauth-authorization-server) |
| Pipedream | https://mcp.pipedream.net/v2 | [Resource](https://mcp.pipedream.net/.well-known/oauth-protected-resource) | [Authorization](https://mcp.pipedream.com/.well-known/oauth-authorization-server) |
| Polar | https://mcp.polar.sh/mcp/polar-mcp | [Resource](https://mcp.polar.sh/.well-known/oauth-protected-resource/mcp/polar-mcp) | [Authorization](https://api.polar.sh/.well-known/oauth-authorization-server) |
| Prisma | https://mcp.prisma.io/mcp | [Resource](https://mcp.prisma.io/.well-known/oauth-protected-resource/mcp) | [Authorization](https://auth.prisma.io/.well-known/oauth-authorization-server) |
| Pulumi | https://mcp.ai.pulumi.com/mcp | [Resource](https://mcp.ai.pulumi.com/.well-known/oauth-protected-resource) | [Authorization](https://mcp.ai.pulumi.com/.well-known/oauth-authorization-server) |
| Ramp | https://ramp-mcp-remote.ramp.com/mcp | [Resource](https://ramp-mcp-remote.ramp.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://ramp-mcp-remote.ramp.com/.well-known/oauth-authorization-server) |
| RevenueCat | https://mcp.revenuecat.ai/mcp | [Resource](https://mcp.revenuecat.ai/.well-known/oauth-protected-resource) | [Authorization](https://mcp.revenuecat.ai/.well-known/oauth-authorization-server) |
| Runway | https://mcp.runwayml.com/mcp | [Resource](https://mcp.runwayml.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.runwayml.com/.well-known/oauth-authorization-server) |
| Sanity | https://mcp.sanity.io | [Resource](https://mcp.sanity.io/.well-known/oauth-protected-resource) | [Authorization](https://mcp.sanity.io/.well-known/oauth-authorization-server) |
| Sentry | https://mcp.sentry.dev/mcp | [Resource](https://mcp.sentry.dev/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.sentry.dev/.well-known/oauth-authorization-server) |
| Stripe | https://mcp.stripe.com | [Resource](https://mcp.stripe.com/.well-known/oauth-protected-resource) | [Authorization](https://access.stripe.com/.well-known/oauth-authorization-server/mcp) |
| Todoist | https://ai.todoist.net/mcp | [Resource](https://ai.todoist.net/.well-known/oauth-protected-resource/mcp) | [Authorization](https://todoist.com/.well-known/oauth-authorization-server) |
| Webflow | https://mcp.webflow.com/mcp | [Resource](https://mcp.webflow.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.webflow.com/.well-known/oauth-authorization-server) |
| Wix | https://mcp.wix.com/mcp | [Resource](https://mcp.wix.com/.well-known/oauth-protected-resource/mcp) | [Authorization](https://mcp.wix.com/.well-known/oauth-authorization-server) |

### Deferred entries from the supplied list

These results describe compatibility with **this client at check time**, not a
claim that the provider does not support OAuth. Trailing-slash/resource differences,
for example, must be separately investigated without silently rewriting the endpoint.

| Entry | Reason |
| --- | --- |
| box | no matching issuer metadata |
| cloudinary | no discoverable resource metadata |
| apify | resource mismatch: https://mcp.apify.com |
| ahrefs | resource mismatch: https://api.ahrefs.com/ |
| figma | public clients not advertised |
| intercom | no discoverable resource metadata |
| tally | resource mismatch: https://api.tally.so |
| amplitude | resource mismatch: https://mcp.amplitude.com |
| amplitude-eu | resource mismatch: https://mcp.eu.amplitude.com |
| miro | public clients not advertised |
| zoominfo | resource mismatch: https://mcp.zoominfo.com |
| explorium | no discoverable resource metadata |
| atlassian | no discoverable resource metadata |
| vercel | resource mismatch: https://mcp.vercel.com/ |
| huggingface | resource mismatch: https://huggingface.co/mcp |
| close | resource mismatch: https://mcp.close.com/ |
| docusign | no discoverable resource metadata |
| supabase | public clients not advertised |
| grafbase | no discoverable resource metadata |
| hubspot | missing registration_endpoint |
| stackoverflow | no discoverable resource metadata |
| slack | resource mismatch: https://mcp.slack.com |
| asana | missing registration_endpoint |

Key/header-auth entries, account-specific endpoints, and SSE-only entries were
excluded before discovery (including GitHub, Better Stack, Buffer, PagerDuty,
Isometric, Hunter, Tavily, PostHog, Context7, Firecrawl, Linkup, Dropbox,
Instantly, Google Maps/BigQuery, Zapier, Workato, MongoDB, Twilio, Elasticsearch,
Grafana, GitLab, Heroku, Square and monday.com). No supplied catalogue instructions
or secret identifiers are imported into the app.

Pipedream was subsequently added using its public end-user `/v2` endpoint, not
the developer endpoint from the original supplied list. The catalogue now contains
36 presets. See [MCP gateways](mcp-gateways.md) for its account scope and the
separate Zapier compatibility investigation. Previously deferred entries have not
been automatically admitted following the canonical-root compatibility change.

## Icons and privacy

Provider website icons are bundled locally in `Support/ToolIcons`, copied into the
signed app by the build script, and decoded as images only. Opening the catalogue
makes **no network requests**. They also provide icons for existing connections
whose exact endpoint matches a preset. Server-supplied connection icons take
precedence after sign-in. Missing assets fall back to a monogram; custom MCPs use
the existing generic connection icon. See `Support/ToolIcons/SOURCES.md` for origin
URLs. These brand marks identify third-party services and do not imply endorsement.

## App boundary and verification

This feature adds no entitlements or executable helpers. The existing app sandbox,
application group, outbound-network and user-selected-read-only access remain;
the existing Sparkle Mach lookup and home-relative harness file exceptions are
unchanged. Messenger and mcpshim remain signed embedded command-line helpers.
The opt-in Agent Host remains the existing separately signed, zero-entitlement
autonomous runtime boundary; the catalogue never starts it.

Core tests cover catalogue invariants, search, independent identities and default
names. The isolated native fixture decodes every icon and exercises preset creation,
customization and unassigned state without authorizing an account. The full smoke
suite checks signed app/helper boundaries and exact icon copies in the app bundle.
