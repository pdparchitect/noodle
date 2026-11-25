---
guides: [setup]
---

# Threat intelligence lookups

Nine tools look indicators up in outside services: what the internet knows of
an IP address, domain, URL, file hash or email address. They have nothing in
your environment to act on, and only read.

| Tool | What agents look up |
| --- | --- |
| **AbuseIPDB** | how often an IP address was reported for abuse |
| **Censys** | what an IP address exposes to the internet |
| **CrowdSec CTI** | what CrowdSec's network saw an IP address do |
| **GreyNoise** | whether an IP address is mass-scanning the internet, or a known benign service |
| **Have I Been Pwned** | the breaches and pastes an email address is in |
| **AlienVault OTX** | the community threat reports that mention an indicator |
| **Shodan** | an IP address's open ports and services, and DNS both ways |
| **urlscan.io** | earlier scans of web pages |
| **VirusTotal** | how security engines judge a file, domain, IP address or URL |

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## What all of them share

**One key each.** Each tool takes an API key from its service, kept in this
Mac's Keychain and sent only to that service. None of these services lets a key
be narrowed to some lookups: a key reaches whatever its account's plan does,
and the tools ask only for lookups. Make each key on an account kept for your
team, such as one on a shared mailbox, rather than a person's own, so it
outlives anyone leaving.

**What you look up leaves your organisation.** Every value an agent looks up,
an address, a hash or an email address, goes to that service, which may keep
it. None of these tools submits anything for scanning, reports anything, or
makes a lookup public; urlscan.io's searches, for one, read only scans others
already made. Agents keep lookups to what the investigation needs.

**Plans and quotas.** Most free plans allow few lookups a day, week or month,
and some are not for commercial use. When a quota runs out, every lookup is
refused until it renews, and the tool says so. Each section below gives the
limits as each service documents them; check your own plan.

**check-access.** Each tool's check-access tries its key once and says, on one
line, whether it works, with the plan and quota where the service reports
them, or exactly what to change. Most read the key's own account and spend no
lookup; the sections below say which spend one.

## AbuseIPDB

- **What agents can do**: `check-ip` gives an IPv4 or IPv6 address's abuse
  confidence score, how many reports and reporters over the last 90 days, or
  as many as asked, up to 365, when it was last reported, and its ISP, usage
  type and whether it is a Tor exit.
- **The key**: make one at [Account › API](https://www.abuseipdb.com/account/api),
  on a free account or a paid one. Pion sends it in the `Key` header to
  `api.abuseipdb.com`.
- **Quota**: checks a day, renewed at midnight UTC: 1,000 on the free
  Standard plan, more on paid plans.
- **check-access** looks up `127.0.0.1`, as AbuseIPDB has no read of a key's
  own account. **It spends one check**, and says how many of today's are left.

## Censys

- **What agents can do**: `host` gives what an IP address exposes as Censys
  last scanned it: its services and ports, network owner, location and DNS
  names.
- **The key**: a **personal access token**, made in your account settings on
  [platform.censys.io](https://platform.censys.io). Pion sends it as
  `Authorization: Bearer <token>` to `api.platform.censys.io`.
- **Quota**: each host lookup spends one credit. A free account has 100 a
  month, which do not roll over. Pion names no organisation in its requests,
  so lookups spend the token's own user's credits, not an organisation's.
- **check-access** reads the user's credits, **which spends none**, and says
  how many are left and when they renew.

## CrowdSec CTI

- **What agents can do**: `ip` gives what the machines in CrowdSec's network
  saw an IP address do: its reputation, the behaviours and attacks that caught
  it, MITRE ATT&CK techniques and CVEs, whether it is background noise, when it
  was first and last seen, and its scores. `ips` looks up to 20 at once. An
  address CrowdSec has not seen is a finding too.
- **The key**: make one under **Settings › CTI API Keys** in the
  [CrowdSec Console](https://app.crowdsec.net); it is shown only once. Pion
  sends it in the `x-api-key` header to `cti.api.crowdsec.net`.
- **Quota**: a free Community key allows a small monthly quota, shown in the
  Console; each address a lookup returns counts.
- **check-access** looks up `192.0.2.1`, an address reserved for
  documentation that CrowdSec has not seen. CrowdSec answers a wrong key with
  HTTP 403, which check-access says is the key.

## GreyNoise

- **What agents can do**: `ip-context` says whether an IPv4 address has been
  scanning the whole internet, whether it belongs to a known benign service
  such as a search engine or DNS resolver, how GreyNoise classifies it and
  when it was last seen. An address GreyNoise has not seen scanning deserves
  more attention, not less.
- **The key**: copy it from **Account › API Key** on
  [viz.greynoise.io](https://viz.greynoise.io), on a free Community account or
  a paid one. Pion sends it in the `key` header to `api.greynoise.io`.
- **Quota**: a free Community key allows about 50 lookups a week, shared with
  GreyNoise's website, and needs a business email address.
- **check-access** pings GreyNoise with the key, **which spends no lookup**,
  and says its plan and when it expires. Only if the ping refuses the key does
  it try one lookup of `8.8.8.8`, which spends one, to tell a wrong key from
  one the ping does not take.

## Have I Been Pwned

- **What agents can do**: `breaches` lists the data breaches an email address
  is in, when each happened and what it exposed, such as passwords; `pastes`
  lists the pastes it is in. A breach shows how credentials may have leaked,
  not that they were used.
- **The key**: searching by email address needs a paid key, bought at
  [haveibeenpwned.com/API/Key](https://haveibeenpwned.com/API/Key). Pion sends
  it in the `hibp-api-key` header to `haveibeenpwned.com`.
- **Quota**: requests a minute, set by the subscription.
- **Caveat**: each lookup sends the email address to Have I Been Pwned.
- **check-access** reads the key's subscription, **which searches nothing**,
  and says its name, until when it runs and how many requests a minute it
  allows.

## AlienVault OTX

- **What agents can do**: `indicator` lists the community threat reports,
  called pulses, that mention an IP address, domain, hostname or file hash,
  with their tags, adversaries and malware families. Anyone may share a pulse,
  so they are leads, not proof.
- **The key**: free. Copy **Your OTX Key** from the
  [API page](https://otx.alienvault.com/api). Pion sends it in the
  `X-OTX-API-KEY` header to `otx.alienvault.com`.
- **check-access** reads the user the key belongs to, **which looks nothing
  up**. OTX answers a wrong key with HTTP 403, which check-access says is the
  key.

## Shodan

- **What agents can do**: `host-report` gives an IP address's open ports, the
  software on them, known vulnerabilities, hostnames, owner and location, as
  Shodan's scanners last saw them, which may be days old. `dns-resolve` and
  `dns-reverse` resolve up to 20 hostnames or addresses either way. Nothing is
  scanned.
- **The key**: copy the **API Key** from
  [account.shodan.io](https://account.shodan.io). Shodan takes the key only
  in the request's address, as `?key=`, so it can show in a proxy's logs
  between this Mac and `api.shodan.io`.
- **Quota**: set by the plan, in query credits a month. A free account
  reaches little of the API; a membership or paid plan reaches more.
- **check-access** reads the key's plan and credits, **which spends none**, and
  says the plan and the query credits left this month. Whether the plan
  includes host reports and DNS lookups shows when they are first tried.

## urlscan.io

- **What agents can do**: `search` searches scans other people already made of
  web pages, by domain, IP address, URL or hash, such as
  `domain:example.com`: what each page showed, where it was hosted, and
  urlscan.io's verdict. Searches never submit a page for scanning, so they
  never reveal what you are looking at.
- **The key**: make one under **Settings & API › API Keys** on
  [urlscan.io](https://urlscan.io), on a free account or a paid one. Pion
  sends it in the `API-Key` header to `urlscan.io`.
- **Quota**: searches a minute, hour and day, set by the plan.
- **check-access** reads the key's quotas, **which searches nothing**, and
  says how many searches are left this minute, hour and day.

## VirusTotal

- **What agents can do**: `file-report`, `domain-report`, `ip-report` and
  `url-report` say how many security engines flag a file hash, domain, IP
  address or URL, with VirusTotal's community score and tags. Nothing is
  submitted for scanning.
- **The key**: copy it from **API key** in your profile menu on
  [virustotal.com](https://www.virustotal.com). Pion sends it in the
  `x-apikey` header to `www.virustotal.com`.
- **Quota**: a free public key allows 4 lookups a minute and 500 a day,
  renewed at midnight UTC, and is **not for commercial use**. A premium key
  allows more and may be used commercially.
- **check-access** looks up `8.8.8.8`, as VirusTotal reads a key's quota only
  by naming its user or the key itself, which the tool does not know. **It
  spends one lookup.** Your profile's API key page shows the quota and what is
  used of it.

## Sources that need no setup

Four more tools need no account or key, so they have nothing to set up and no
check-access:

- **cve.now** gives what is known about a vulnerability and whether it is
  being exploited, and watches for new critical ones.
- **crt.sh** searches the public Certificate Transparency logs for
  certificates issued for a domain, which shows its subdomains and lookalike
  domains. It is often slow and sometimes times out on large domains.
- **DNS** looks names up through Google's public resolver, so agents can see
  what a domain points to without touching your own resolvers.
- **NVD**, the US National Vulnerability Database, gives a CVE's description,
  severity and affected products. Without a key it allows only a few requests
  a minute, so a burst of lookups slows down.

## When something does not work

Ask an agent to run **check-access** on the tool. Its line says what to
change:

- **"did not accept the key"**: the key is wrong, was reset or deleted, or
  its subscription ended. Copy it again, or make a new one, and enter it in
  **Settings → Tools**.
- **"refused the key for this"**: the account's plan does not include it.
- **"used up"** or **"rate limiting"**: the quota ran out, or too many
  lookups came at once. Wait for it to renew, or raise the plan.

## What to check on a live account

These follow each service's documentation, but were tested only against
stand-ins:

- what AbuseIPDB answers for `127.0.0.1`: check-access takes an answer or a
  refusal of the address alike as a working key;
- whether CrowdSec counts a lookup of an address it has not seen against the
  quota;
- whether GreyNoise's ping takes a free Community key, and which plan it
  names for one;
- the fields OTX gives for the key's own user, which only its SDKs document;
- whether Shodan's host reports spend query credits on your plan;
- which actions and windows urlscan.io's quotas list besides searches.
