# Cloudflare

Pion has two Cloudflare tools, each added per Cloudflare account with a sign-in
of its own:

- **Cloudflare Detection** reads the account from Cloudflare's side. At the edge:
  zones and DNS records, each zone's security settings, the records that point
  outside a zone, firewall events, the account audit log and its members. In
  Zero Trust: Access logins, applications and
  policies, users and their sessions, Gateway activity, rules and lists, WARP
  devices and Cloudflare Tunnels. It wakes the agents it is assigned to for
  high-risk changes in the audit log and bursts of blocked Access logins. It
  only reads.
- **Cloudflare Containment** acts: it blocks an IP address, network or country
  at the edge and removes what it blocked, revokes a person's Access sessions,
  blocks a domain or IP address in Gateway and removes it, and revokes a WARP
  device. Every one of these waits for your approval. Giving a revoked device
  back is done in the Zero Trust dashboard.

**Cloudflare Radar** is a separate tool, on Cloudflare's own MCP server, for
Internet-wide trends; it knows nothing of your account and is unchanged.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the Cloudflare dashboard:

- **Manage Account › OAuth clients**, for each tool's OAuth client and its
  scopes;
- **Manage Account › Members**, for each tool's member and their roles;
- **Manage Account › Audit Log**, **Security › WAF › Tools** (IP Access rules),
  and **Zero Trust** (Access, Gateway, devices, tunnels), to see and undo what
  Containment did.

## How Cloudflare limits what Pion can do

Both tools sign in as a member of your Cloudflare account through OAuth, at
Cloudflare's dashboard (`https://dash.cloudflare.com/oauth2/auth` and
`/oauth2/token`). Each signs in through a private OAuth client your account
makes for that tool alone, with an authorization code and PKCE, so Pion keeps no
client secret. Pion ships no OAuth client of its own. Every sign-in asks for the
member's password again, so a browser already signed in to the dashboard as
someone else never answers for them. When you sign in, Cloudflare asks which
accounts the client may reach: choose only the one you are adding.

Cloudflare allows a request only when **both** of these allow it:

- **the client's scopes**, which you add when you make it. Cloudflare's scopes
  carry the same names as its API token permissions. Pion asks for exactly the
  scopes below, and refuses a sign-in that lacks any.
- **the signed-in member's role.** Each tool gets a member of its own.

| Tool | Scopes | Member's role |
| --- | --- | --- |
| Cloudflare Detection | `account-settings.read`, `teams.read`, `account-analytics.read`, `argotunnel.read`, `zone.read`, `dns.read`, `analytics.read`, `zone-settings.read`, `zone-waf.read` | Administrator Read Only |
| Cloudflare Containment | `account-firewall-access-rules.write`, `teams.write`, `firewall-services.write`, `zone.read` | only roles that allow its actions, such as Firewall and Cloudflare Zero Trust (to be confirmed on a live account); never Super Administrator or Administrator |

Both also ask for `offline_access`, so the sign-in renews itself without asking
again. Cloudflare Detection's scopes only read, so it cannot change anything,
whatever its member's role allows. Cloudflare Containment's `teams.write` can
change all of Zero Trust, as Cloudflare has nothing narrower for Gateway lists
and WARP devices, so its member's role is what limits it.

Why each is needed:

- **`account-settings.read`** reads the account audit log, which the watch
  reads, and its members.
- **`teams.read`** reads Access logins, applications, policies, users and
  sessions, Gateway rules and lists, and WARP device registrations. Cloudflare
  accepts it for all of these.
- **`account-analytics.read`** reads Gateway activity from the GraphQL
  Analytics API.
- **`argotunnel.read`** reads tunnels and their connections.
- **`zone.read`, `dns.read` and `analytics.read`** find a zone, read its DNS
  records, its DNSSEC status and its firewall events.
- **`zone-settings.read`** reads a zone's SSL/TLS, HTTPS, HSTS and security
  settings for `zone-settings`; `zone.read` does not.
- **`zone-waf.read`** reads which WAF managed rulesets a zone runs.
- **`account-firewall-access-rules.write`** for `block-ip`, `block-asn`,
  `block-country` and `unblock` across the account.
- **`teams.write`** for `gateway-block`, `gateway-unblock`, `revoke-device` and
  `revoke-access-sessions`, and the reads they make first. Leave the Zero Trust
  role off Containment's member if agents should not act in Zero Trust.
- **`firewall-services.write`** and **`zone.read`**, to block in one zone
  rather than the whole account.

An account that uses only the edge, or only Zero Trust, still adds every scope:
check-access says which parts the sign-in reaches.

There is no scope that only reads API tokens, so Cloudflare Detection does not
list them. The account audit log, which it reads, still shows tokens made,
rolled and deleted, and the watch wakes the agents for them.

**check-access sends no change.** Cloudflare documents no way for an OAuth
sign-in to verify itself, as an API token can, so check-access reports the
scopes Pion asked for, which Pion refuses a sign-in to lack, and tries one read
for each part. Containment's edits are **not verified**: the reads Containment
tries can work even where its member's role does not allow the change, and an
action refused for want of a scope or role says which.

- **Sign Out** in **Settings → Tools** revokes the sign-in at Cloudflare. Each
  member can also revoke it under **My Profile › Manage OAuth authorizations**.
- When the sign-in expires or is revoked, the client is deleted or loses its
  Refresh Token grant, or the member leaves the account, the tool says to
  connect it again.

**One host.** Pion sends every request, and every next page, which Cloudflare
gives as a page number or a cursor rather than an address, to
`https://api.cloudflare.com/client/v4` and nowhere else. A connection that
names any other address, scheme or port is refused before anything is sent,
and so is an Account ID that is not 32 hexadecimal characters.

**One exception: `dns-exposure` looks names up.** Cloudflare's API resolves no
name, so to tell whether the target of a CNAME still resolves, `dns-exposure`
asks Cloudflare's own public DNS-over-HTTPS resolver,
`https://cloudflare-dns.com/dns-query`, which already holds the zone's records.
The lookups carry no sign-in and nothing of the connection, follow no redirect,
and go nowhere else: not to this Mac's resolver, your network, VPN or ISP. It
looks up at most 40 targets in a run unless asked for more (up to 100), and
none when asked for 0.

## Setting it up with least access

1. **Make the client.** In **Manage Account › OAuth clients**, choose **Create
   client** and name it **Pion Detection**. Making one takes the Super
   Administrator, Administrator or OAuth Client Write role. Keep it private, the
   default, so only members of this account can sign in through it; a private
   client needs no domain verification.
2. **Set its sign-in.** Choose the response type **code**, the grant types
   **Authorization Code** and **Refresh Token**, and the token authentication
   method **None**: Pion signs in with PKCE. Give exactly
   `com.pdparchitect.pion:/oauth2callback` as the **Redirect URL**
   (`com.pdparchitect.pion.local:/oauth2callback` for Pion Dev).
3. **Add its scopes.** Choose **Continue** and add exactly Cloudflare
   Detection's scopes from the table above, each left **Required**, then choose
   **Create client**.
4. **Choose its member.** Keep a member of this account for Cloudflare Detection
   alone, such as `pion-detection@example.com`, with the **Administrator Read
   Only** role under **Manage Account › Members**.
5. **Add the account** with its **Account ID**, from the account's Overview
   page, and the client's **Client ID**. Choose **Add & Connect**, sign in as
   that member and choose only this account.

Then ask an agent to run **check-access**.

## Coverage you should know

- **Searches are bounded and say what they left out.** Listings follow
  Cloudflare's page numbers, or its cursor, to the end, and say when they
  stopped before it, and why: a page that failed (the pages before are kept),
  or paging that contradicted itself. A result that matched more than it kept
  says so.
- **Access logins** come without paging details, so Pion reads them by time:
  each next request asks up to a second after the oldest login the last gave,
  and logins read twice count once. The read is whole only once a request
  brings nothing new. It says when more logins share one second than
  Cloudflare gives at once.
- **Firewall events and Gateway activity** come from the GraphQL Analytics API,
  which has no paging: Pion asks for one more than it keeps, so a result says
  when more matched. Gateway activity is only given as sampled counts by group
  (DNS queries by domain and decision, HTTP requests by host and action,
  network sessions in total); per-person and per-device Gateway logs come only
  from Logpush or the dashboard.
- **Posture.** Cloudflare gives no posture results per device. `access-user`
  gives the posture results of the device a person was last seen on.
- **Rate limits.** Cloudflare allows 1,200 requests per five minutes per user,
  and a sign-in acts as its member.
  When it refuses one, Pion tries again after a short wait, and once more when
  Cloudflare's `Retry-After` is under 20 seconds; otherwise the answer says how
  long it asked.
- **Reach.** A sign-in sees only the accounts chosen when signing in, and what
  the member's role reaches there. A zone it does not reach is said not to be
  one the sign-in can see, never not to exist.
- **Zone settings.** They reach only the hostnames Cloudflare proxies; a
  DNS-only record reaches its origin directly, whatever they say. Pion asks for
  all of a zone's settings at once, which Cloudflare marks as deprecated, and
  asks for each it needs on its own when that answer is gone or leaves one out;
  one a zone's plan lacks is shown as not given. Security Level is shown but not
  judged, as Cloudflare now uses it mainly for I'm Under Attack mode. Managed
  rulesets deployed for the whole account, on Enterprise plans, are not read,
  so "none deployed at the zone" may not mean none run there. A zone in a
  partial (CNAME) setup has its DNSSEC set where its DNS is hosted.
- **DNS exposure is a list of leads, not findings.** Pion never visits a
  target. Many providers, such as S3, Heroku and GitHub Pages, keep answering
  for a name after the resource behind it is deleted, so a target that
  resolves may still be unclaimed: confirm each in the provider's console.
  A target that doesn't resolve is worth removing if unused, and a possible
  takeover only at the providers marked so; whether one is open to takeover is
  never said. Which providers are marked follows the community's list of
  takeover reports (can-i-take-over-xyz) and, for Azure, Microsoft's guidance
  on dangling DNS. A target is said not to resolve only when the resolver
  answers that it does not exist (NXDOMAIN) or that it has no address, IPv4
  or IPv6 (NOERROR with no answer), with the CNAMEs it led through. A server
  failure (SERVFAIL), any other answer, or none within 5 seconds is said as
  couldn't tell, never as not resolving; targets past the limit are said as
  not looked up. The answer is public DNS's: a name that resolves only inside
  your network is not seen.

## What agents can do

- `zones`, `zone-dns`: the account's zones, and a zone's DNS records read whole,
  its apex, MX and NS records first.
- `zone-settings`: for one zone or every zone the sign-in sees (25 unless asked
  for more, up to 100), the SSL/TLS mode and whether Automatic SSL/TLS chose
  it, minimum TLS version, Always Use HTTPS, Automatic HTTPS Rewrites, HSTS,
  TLS 1.3, DNSSEC, Opportunistic Encryption, Security Level, Browser Integrity
  Check and the WAF managed rulesets deployed at the zone. It leads with weak
  settings: SSL/TLS Off or Flexible, a minimum TLS below 1.2, HTTPS not
  enforced, DNSSEC off or not yet in force, and paused zones; then what is
  worth a look, such as Full rather than Full (strict), HSTS off and no managed
  rules.
- `dns-exposure`: a zone's records that point outside it, grouped by the
  provider the target shows (Heroku, GitHub Pages, S3, Azure, Netlify, Vercel,
  Shopify, Zendesk, Kit and others), so you can confirm each is still in use.
  It leads with CNAMEs whose target doesn't resolve, marked "possible
  takeover" where the provider is one where names left pointing at deleted
  resources have been claimed by others; then CNAMEs to a name in the zone no
  record answers, private addresses published in public DNS, subdomains
  delegated to other name servers, and addresses Pion does not recognise.
- `firewall-events`: what the WAF and firewall did at a zone's edge, by client
  IP address, action and time, with country, network, path, rule and Ray ID.
- `audit-log`: who changed what in the account, from where, through the
  dashboard or the API, by time, person, action and zone.
- `members`: who holds which role, with 2FA, administrators first.
- `access-logs`: who signed in to which Access application, allowed or
  blocked, from which address and country.
- `access-apps`, `access-app`: Access applications, and one with every policy
  in the order Access evaluates them, bypass and service auth first.
- `access-users`, `access-user`: users with their last login, and one with
  every active Access session and what Cloudflare last saw of them.
- `gateway-activity`, `gateway-rules`, `gateway-lists`: Gateway's decisions,
  its policies in order of precedence (a rule turned off, or an allow ahead of
  a block, can open a path), and its lists and their items.
- `devices`: WARP device registrations, revoked or not, with user and client.
- `tunnels`: Cloudflare Tunnels, and one tunnel's connectors and connections.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads two feeds:

- **high-risk changes in the account audit log**: API tokens made or rolled
  (Access service tokens included), members added or their roles changed, DNS
  changes on a zone's apex, MX or NS records (and DNS changes whose record the
  log does not name), firewall, WAF and IP Access rules turned off or deleted,
  Access policies and applications changed, Gateway rules turned off or
  deleted, WARP devices enrolled, revoked or unrevoked, and tunnels made. Pion
  recognises them from the words of each entry's action and resource, as
  Cloudflare publishes no list of them, word by word, so undoing (unpause,
  enable, unblock, unrevoke, restore) is never read as doing; when an entry
  states what the change left, such as `enabled` or `paused`, that is read
  rather than its verb. A failed change is not told;
- **bursts of blocked Access logins**: ten or more blocked from one address, or
  for one person, within one hour. A burst from one address by one person is
  told once, by its address.

Each reads from six hours before the newest seen, as Cloudflare lists some
after they happened; the audit log up to four pages of 500 each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing Cloudflare wrote reaches the note: no ID, name,
email, address or description. Each change and burst is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind takes its turn, tokens, members, Access, firewall and Gateway
  changes and bursts first, then DNS, devices and tunnels;
- the watch says once that more follow;
- the checks after read on from the oldest not yet handed over, until all of it
  is handed over, even across a check that could not read the feed.

A check that reaches its four pages keeps the next page number and the exact
query it belongs to, whose window is fixed, so its pages hold the same entries
however many arrive after it. The next check goes on from there, never from a
time, so even thousands of changes at the same moment are read through once.
When that search ends, the feed reads on from six hours before its end, however
far the watch has moved on meanwhile. If Cloudflare turns down a later page,
the watch says so once and reads that window again from its start.

A check that fails for a passing reason, such as the rate limit, keeps nothing
but how many checks in a row failed, so the next check reads the same window
again.

**What it does not watch:**

- changes of kinds Pion does not recognise from Cloudflare's own names for
  their action and resource;
- whether a change to an Access policy loosened it: every change to Access
  policies and applications is told alike;
- DNS changes on records other than a zone's apex, MX and NS;
- firewall and Gateway rules made or loosened without being turned off or
  deleted;
- fewer than ten blocked Access logins from one address or for one person in an
  hour, and allowed logins;
- Gateway's own decisions, firewall events at the edge, and Security Center
  insights;
- anything in zones or accounts the sign-in does not reach.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused for want of a scope or role, or a sign-in Cloudflare no
  longer accepts, wakes the agents once, and once more after Pion relaunches if it is
  still so. It wakes them again only after the feed has been read once since.
- An account without Cloudflare Access is said once to have its logins off, and
  again after a relaunch; the audit log is still watched.
- A failure that passes, such as the rate limit, holds the watch back for up to
  half an hour, reading the same window again, before it is told the same way.

## When something does not work

Ask an agent to run **check-access**. It sends only reads, so it changes
nothing, and says:

- that it reaches only `api.cloudflare.com`, for which account;
- for each read, at the edge and in Zero Trust, whether it works, and if not,
  which scope it takes, or that the account does not use it, including zone
  settings, DNSSEC and WAF managed rules on the first zone the sign-in sees;
- which parts, edge and Zero Trust, the sign-in reaches;
- the scopes the sign-in holds, and the client they are granted to.

Any refused call says the same. Cloudflare does not say why it refused, so a
refusal names the scope the call takes and says the cause may instead be the
member's role or an account not chosen at sign-in. A sign-in Cloudflare no
longer accepts needs connecting again.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why.
- **An answer Pion cannot read is an error, never "nothing found".** An answer
  that does not say it succeeded, `success: false`, any entry in `errors`, with
  a message or without, a result left out, a resource without its ID, or a
  paging field of the wrong type is an error.
- **Paging that contradicts itself is never whole.** A count other than the
  page holds, a total of none with items or with a next cursor, another page
  than the one asked for, items beyond the total, a total the pages never
  reach, an empty page that says more follow, or the same cursor twice stops
  the listing, saying so. So does any sign of more that the listing's own
  paging does not follow, even from a list Cloudflare normally gives in one
  answer: a cursor, more than one page, or a total above what it gave.
- **Absent only when a whole listing says so.** Cloudflare documents no error
  code that means a resource is not there, so a 404 or any error is never taken
  for absence. One application, user, rule, list or registration asked for by
  ID is absent only when a listing read whole, without error and with paging
  that agrees with itself, does not name it; a listing asked for that ID alone
  that names any other, or counts other than it gave, shows nothing. A user
  asked for by email is present only when exactly one user has that email.
- **Unknown is not none.** A field Cloudflare does not give is shown as not
  given; a device whose revocation is not given is not taken as active.

## Containing an incident

**Cloudflare Containment** is a separate tool, with its own client and member,
so the detection sign-in stays read-only.

1. **Make another client**, named **Pion Containment**, as in steps 1 to 3
   above, with only Cloudflare Containment's scopes from the table.
2. **Choose its member**, such as `pion-containment@example.com`, apart from
   Cloudflare Detection's, with only roles that allow its actions, such as
   **Firewall** and **Cloudflare Zero Trust**, still to be confirmed on a live
   account. Never make it a Super
   Administrator or Administrator.
3. **Add the account** with the same Account ID and that client's Client ID,
   sign in as that member, and ask an agent to run its **check-access**. It
   tries the reads the actions make first and lists the sign-in's scopes; it
   tries no action.

What agents can do. Every action is held for your approval. Each one's
description and result say what recovering from it involves:

| Action | What it does | Recovery |
| --- | --- | --- |
| `access-user`, `device` (not held) | Read a user's ID and active sessions, or a WARP registration's state, before acting. | Nothing changes. |
| `action-status` (not held) | Reads every IP Access rule for an address, range, network or country, or one rule Pion made, and whether Pion's record says it made each; whether Pion's Gateway list holds a value and its rule blocks it; a user's sessions; or a registration's state. | Nothing changes. |
| `block-ip` | Adds an IP Access rule blocking an address, or an IPv4 /16 or /24 or IPv6 /32, /48 or /64 range, for the account or one zone. | `unblock` with the rule's ID lets the traffic in again at once; requests blocked meanwhile are not replayed. |
| `block-asn` | The same for a whole network by AS number, which carries everyone it serves. | `unblock`. |
| `block-country` | The same for a country, or Tor (T1). Cloudflare allows this only on Enterprise plans. | `unblock`. |
| `unblock` | Removes one IP Access rule, by its ID, that Pion's record says it made through this connection and that Cloudflare still holds as made. | `block-ip`, `block-asn` or `block-country` again. |
| `revoke-access-sessions` | Ends every Access session a person has, by their email, so each Access application asks them to sign in again. | None needed: they sign in again with their identity provider. It cannot be reversed and does not stop a new sign-in, so suspend a taken-over account at the identity provider too. |
| `gateway-block` | Adds a domain (and its subdomains) or IP address or range to Pion's own Gateway list, which Pion makes the first time with a Gateway rule that blocks it: a domain in DNS, an address in network traffic through WARP. | `gateway-unblock` lets devices resolve or reach it again at once. |
| `gateway-unblock` | Removes a value Pion's record says it added to its list. | `gateway-block` again. |
| `revoke-device` | Revokes one WARP device registration, so the device reaches nothing Zero Trust protects through it, and Gateway no longer filters it. It reports the registration's state read afterwards, which confirms the state, not who changed it. | Unrevoke the registration, or have its user enrol the device again, in the Zero Trust dashboard (Team & Resources › Devices). Pion offers no unrevoke, as it cannot verify who revoked a registration. |
| **check-access** (not held) | See step 3. | Nothing changes. |

**Tightening an Access policy is left out.** Cloudflare evaluates an
application's policies in an order in which each must hold a precedence of its
own, so putting a block first means renumbering the application's other
policies: a change to what Pion does not own and cannot restore exactly.
`revoke-access-sessions`, with suspending the person at their identity provider
(Okta or Entra ID Containment), reaches the same end reversibly.

Pion reads what it acts on, whole, just before acting, and refuses, sending
nothing:

- a value or ID that is malformed, or a reason that is empty or too long;
- a range an IP Access rule does not take;
- a value any IP Access rule already holds, in the account or zone, whoever
  made it, or when not every rule for it could be read;
- a user, list or registration it cannot read whole, or that Cloudflare does
  not list;
- revoking the sessions of a person who has none, per a whole read;
- adding a value Pion's list already holds;
- revoking a registration already revoked, or unrevoking one that is not;
- removing a rule or list item Pion has no record of making through this
  connection, one recorded as changed since it was made, or one not exactly as
  made: a rule's mode, target, value, notes or `modified_on` differing, or a
  list's name, type or description, or one given without a field it must give.
  A rule is found by its ID among every rule in its account or zone, read
  whole, never among the rules for its old value, so a rule whose value
  someone changed is never taken as gone;
- removing a list entry that is not the one Pion added: Cloudflare gives list
  entries no ID, so Pion records the entry's value, Pion's description and the
  time Cloudflare says it was added, and removes it only while the list holds
  exactly that entry. One someone put in its place, or one whose time
  Cloudflare never gave, is left to the dashboard, with the steps to remove it.

Unknown never blocks: a session list or revocation state Cloudflare does not
give is said, and the action goes ahead.

**Why there is no unrevoke.** A registration's `revoked_at` shows its state,
not who revoked it, and the account audit log cannot show that every
revocation has arrived: Pion's own request, taken as a no-op, may be logged
before an administrator's revocation that took effect. So Pion cannot verify
that a revocation in force is its own, and giving a device back is left to the
Zero Trust dashboard.

**A request taken is not a request done.** Pion says done only when
Cloudflare's answer plainly succeeded, names the same rule or list where it
names one, and a read afterwards shows the result: a rule read back as made, a
rule no longer listed after its removal, a value in, or no longer in, Pion's
list read whole, no active sessions left, or the registration revoked.
`revoke_user` and the registration revoke answer without naming anyone, so
only the read afterwards confirms them. A Gateway block is done only when the
list holds the value and Pion's rule is there, on and as made; the result also
names any allow rule evaluated before it that may let the value through. Any
other answer, an error, a different ID, or a state that does not follow, is
reported unverified, with the request's path and values.

**Which rules and items are Pion's.** Pion's IP Access rules carry notes
starting "Pion, after the champion's approval", for people reading the
dashboard, but anyone can write that, so it proves nothing. Pion records what
it made itself, and only from a plain answer to the request that made it:
success, no error, and a rule with an ID, mode block, and the target and value
asked for, in the account asked for. That answer is the record: the rule's ID,
the account or zone it was made in, when, and its mode, target, value, notes
and `modified_on`, kept for the connection and its account in Pion's own data,
so it outlasts a relaunch. Pion then reads the rule back: one that differs is
recorded as changed since it was made, and `unblock` leaves it to the
dashboard. `unblock` removes a rule only by its ID, in the account or zone it
was made in (a zone's rule with `cascade: none`, so no other zone's), only if
the record holds it unchanged and Cloudflare, read just before, still gives
every field as recorded; it says removed only when Cloudflare's answer names
that ID and a read then lists it no more. The same holds for Pion's Gateway
list and rule, and each value Pion adds to the list. A rule or item Pion made
but has no record of, as when the record could not be saved, which the result
says, is removed in the dashboard.

Cloudflare takes no condition on a change, so someone else can act on the same
rule, list or registration between Pion reading it and acting. Each result says
when Pion read it.

## What to check on a live account

These follow Cloudflare's published API reference, but were tested only against
stand-ins:

- that the account audit log (`/accounts/{account}/audit_logs`) pages as asked
  within a fixed window, and the action and resource names its entries give
  for tokens, members, DNS records, IP Access and WAF rules, Access policies,
  Gateway rules, devices and tunnels, which the watch recognises by their words;
- that Access logins honour `since`, `until`, `direction` and `limit` (Pion
  asks for 500), as they come without paging details;
- that a private OAuth client takes the custom-scheme redirect URL
  `com.pdparchitect.pion:/oauth2callback`; if Cloudflare refuses it, Noodle
  needs a loopback listener on 127.0.0.1 first;
- the scope IDs, from `GET /client/v4/oauth/scopes`: those above come from a
  copy of Cloudflare's list, not its documentation;
- that the token answer lists the scopes granted, and in what form
  (`offline_access` is asked for but not required among them), and that
  `prompt=login` asks for the member's password again;
- that Gateway activity, through the GraphQL Analytics API, accepts an OAuth
  token;
- how long access and refresh tokens last;
- that the scopes carry the names above and an OAuth sign-in reads and acts
  with them as an API token with the same permissions would, within the
  member's role, and which member roles allow Containment's actions;
- the GraphQL dataset and field names Gateway activity uses
  (`gatewayResolverQueriesAdaptiveGroups` with `queryNameReversed` and
  `resolverDecision`, `gatewayL7RequestsAdaptiveGroups` with `httpHost` and
  `action`, `gatewayL4SessionsAdaptiveGroups`);
- that a zone's IP Access rules list includes the account's rules, and that
  account rules give their scope's ID;
- the WARP registration endpoints (`/devices/registrations` and its `revoke`,
  which Cloudflare marks as deprecated but still documents), and that
  `revoked_at` is null for an active registration;
- that `revoke_user` takes `teams.write` (Zero Trust › Edit), as the API
  reference says;
- that an account without Zero Trust is refused in words Pion recognises as
  such (such as "not enabled"), rather than as a missing permission;
- that `GET /zones/{zone}/settings`, which Cloudflare marks as deprecated, still
  lists `security_header` and `ssl_automatic_mode`, and the values of
  `always_use_https`, `automatic_https_rewrites`, `opportunistic_encryption`
  and `browser_check` (`on` or `off`), which the reference does not list;
- that `zone-waf.read` reads a zone's managed-rules entry point
  (`/rulesets/phases/http_request_firewall_managed/entrypoint`), which the
  reference lists only account permissions for, and that a zone without one
  answers 404 for a sign-in allowed to ask;
- the addresses Pion takes for GitHub Pages, Netlify, Vercel, Shopify and
  Squarespace, as each provider publishes them;
- that `cloudflare-dns.com` answers `dns-exposure`'s JSON questions, with
  `Accept: application/dns-json`, as its reference describes;
