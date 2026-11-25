---
guides: [setup]
---

# Hunt.io

Pion has two Hunt.io tools, each added with a key of its own:

- **Hunt.io Detection** looks attacker infrastructure up in Hunt.io: whether an
  IP address hosts known malware or C2, is named in threat reports, is a TOR
  exit node or VPN and which threat actor it is linked to; a domain's DNS,
  WHOIS and subdomains; a certificate by its fingerprint; the threat reports
  in IOC Hunter; an open directory AttackCapture indexed; and threat actors.
  It only reads.
- **Hunt.io** connects to Hunt.io's own MCP server, which offers Hunt.io's
  wider set of tools, such as HuntSQL and CVE intelligence.

Hunt.io has nothing in your environment to act on, so there is no Hunt.io
Containment.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Hunt.io limits what Pion can do

Hunt.io's [API](https://a.hunt.io/) takes **an API key only**: it has no
sign-in. Each key belongs to one organisation and its plan, starts `ak_`, and
can be limited to the IP addresses it is used from. Pion keeps it in this Mac's
Keychain and sends it as `Authorization: Bearer <key>`, only to `a.hunt.io`.
To revoke it, delete the key in the Hunt.io portal.

A key reaches whatever the organisation's plan includes: Hunt.io documents no
way to narrow an API key to some lookups. Hunt.io Detection asks only for
lookups. Hunt.io's
API can also queue IP addresses for scanning, submit URLs for indexing and
serve the files AttackCapture captured, which are malware samples. Hunt.io
Detection has no operation for any of them.

**There is no free plan.** The API and MCP server come with a paid plan, from
**Researcher** up, or Hunt.io's 2-week trial; see
[hunt.io/pricing](https://hunt.io/pricing). Hunt.io may ask you to talk to its
sales team before it turns MCP access on.

**Every lookup spends the quota.** Hunt.io counts each successful request
against the organisation's monthly quota, and limits how fast requests come.
Most operations send one request; `ip-lookup` sends two. When a tenth or less
of the quota is left, every result says how much. When it runs out, every
lookup is refused until the next billing period, and the result says so.

## Setting it up

### Hunt.io Detection

1. **Make the key.** Sign in to the [Hunt.io portal](https://portal.hunt.io)
   and create an API key for Pion Detection alone. Limit it to your own IP
   addresses if you can.
2. **Add the tool** in **Settings → Tools** and give the key.

Then ask an agent to run **check-access**.

### Hunt.io's MCP server

1. **Make a dedicated MCP key.** In the Hunt.io portal, create an MCP key for
   Pion. Hunt.io gives MCP keys fixed scopes. Don't reuse Hunt.io Detection's
   API key: keeping them apart lets you revoke either without the other.
2. **Add the tool** in **Settings → Tools** and give the key. Pion sends it as
   `Authorization: Bearer <key>` to `https://mcp.hunt.io/mcp`.

Hunt.io's MCP server also offers an OAuth sign-in, but only for a client
Hunt.io registers, with a client secret. Pion ships no such client, so it uses
the key.

The MCP server offers tools that download or preview the files AttackCapture
captured, which are malware samples. If Hunt.io lets you choose an MCP key's
scopes, leave those tools out. If it doesn't, the preset cannot block them:
Noodle has no per-tool filter for MCP servers, and only the tool's
instructions keep agents off them.

## What agents can do

- `ip-lookup` reads Hunt.io's risk profile of an IPv4 address and leads with
  what matters: the malware or C2 Hunt.io saw on it, the threat actor it is
  linked to, the threat reports that name it, malicious open directories on it
  and whether it is a TOR exit node or VPN. Then it gives the address's network
  and the services Hunt.io saw on it in the last 45 days, or as many days as
  asked, with any malware each service ran.
- `domain-lookup` gives a domain's apex and the addresses it resolves to,
  Hunt.io's tags, its latest WHOIS registrar and dates, and its subdomains.
  For threat reports that name it, agents use `ioc-hunter-search`.
- `certificate-lookup` takes a certificate's SHA-256 fingerprint and gives its
  subject and DNS names, issuer, validity, and when Hunt.io first and last
  saw it.
- `ioc-hunter-search` finds the threat reports in Hunt.io's IOC Hunter that
  name an IP address, an IPv4 network or a host, each with its threat actor,
  malware family, source and date, narrowed by actor, malware family and age.
  For file hashes, Hunt.io's API takes an actor or malware family, not a hash
  itself, so agents list the hashes reported for those.
- `attackcapture-host` summarises an open directory Hunt.io indexed: when it
  was first seen, and how many files and folders it held and their size. It
  never lists or downloads the files.
- `threat-actors` finds actors by name, alias or keyword and the country
  they're attributed to, with their aliases, victims and how many IP addresses,
  hosts and file hashes Hunt.io links to them.
- `check-access` reads the organisation's usage this month and says which
  organisation and plan the key belongs to and how much of the quota is left.

Each result says when it was cut short, such as `the first 10` of a search's
total. A lookup Hunt.io has no record of, such as an address it has never
seen or an unknown certificate, is a finding, not a failure: the result says
Hunt.io has no record of it.

## When something does not work

Ask an agent to run **check-access**. It sends one read, and says:

- whether the key works, and for which organisation and plan;
- how much of this month's quota is used and left.

Whether the plan includes a lookup shows only when it is first tried. Hunt.io
refuses one it doesn't include with `operation_not_allowed`, which the result
says may be the plan.

- **"rejected this connection's credentials"**: the key is wrong or was
  deleted, or it's limited to other IP addresses.
- **"quota for this month is used up"**: wait for the next billing period, or
  ask Hunt.io to raise it.
- **"rate limiting requests"**: wait before trying again, and make fewer
  lookups at once.

## What to check on a live account

These follow Hunt.io's OpenAPI spec, but were tested only against stand-ins:

- the names of the portal's pages for API keys and MCP keys, and whether an
  MCP key's fixed scopes include the AttackCapture download and preview tools;
- that the MCP server takes an MCP key as `Authorization: Bearer <key>`, and
  doesn't first ask a client that sends one to sign in;
- that answers carry `meta.authz.plan` and `meta.authz.quota`, which the
  spec's overview describes but its response schemas don't list;
- whether `GET /usage/monthly` counts against the quota;
- what Hunt.io answers for an address, domain or actor it has no record of:
  the spec gives `row: null` or `ok: false` with `not_found` inside a
  successful answer, and keeps HTTP 404 for an address the API doesn't have,
  which Pion also reads as no record;
- whether `domain-lookup`'s `tags` section is a list of names, the only shape
  Pion reads.
