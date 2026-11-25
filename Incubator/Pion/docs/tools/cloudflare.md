# Cloudflare

Pion has two Cloudflare tools, each added per Cloudflare account with an API
token of its own:

- **Cloudflare Detection** reads the account from Cloudflare's side. At the edge:
  zones and DNS records, firewall events, the account audit log, members and
  the account's own API tokens. In Zero Trust: Access logins, applications and
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

- **Manage Account › Account API Tokens** (or **My Profile › API Tokens**), for
  each tool's token;
- **Manage Account › Audit Log**, **Security › WAF › Tools** (IP Access rules),
  and **Zero Trust** (Access, Gateway, devices, tunnels), to see and undo what
  Containment did.

## How Cloudflare limits what Pion can do

Cloudflare has no sign-in for an admin here. Each tool uses a **custom API
token** you make for it alone, and sends it with every request as
`Authorization: Bearer <token>`. What the token may do is exactly its
**permissions**, on the **account and zones** it names; nothing else is
involved. An account's own token (Manage Account › Account API Tokens) is best:
it outlasts the person who made it.

| Tool | Permissions | Must not have |
| --- | --- | --- |
| Cloudflare Detection | Account › Account Settings › Read, Account › Account API Tokens › Read, Account › Zero Trust › Read, Account › Account Analytics › Read, Account › Cloudflare Tunnel › Read; Zone › Zone › Read, Zone › DNS › Read, Zone › Analytics › Read | any Edit permission |
| Cloudflare Containment | Account › Account Firewall Access Rules › Edit, Account › Zero Trust › Edit; to act in one zone, also Zone › Firewall Services › Edit and Zone › Zone › Read | anything else, above all Account Settings, API Tokens, DNS and Access: Apps and Policies Edit |

Why each is needed:

- **Account Settings › Read** reads the account audit log, which the watch
  reads, and its members.
- **Account API Tokens › Read** lists the account's own tokens, and lets
  check-access read the token's own permissions.
- **Zero Trust › Read** reads Access logins, applications, policies, users and
  sessions, Gateway rules and lists, and WARP device registrations. Cloudflare
  accepts it for all of these.
- **Account Analytics › Read** reads Gateway activity from the GraphQL
  Analytics API.
- **Cloudflare Tunnel › Read** reads tunnels and their connections.
- **Zone › Zone, DNS and Analytics › Read** find a zone, read its DNS records
  and its firewall events.
- **Account Firewall Access Rules › Edit** for `block-ip`, `block-asn`,
  `block-country` and `unblock` across the account.
- **Zero Trust › Edit** for `gateway-block`, `gateway-unblock`,
  `revoke-device` and `revoke-access-sessions`, and the reads
  they make first. Cloudflare accepts nothing narrower for Gateway lists and
  WARP devices, and Zero Trust › Edit can change all of Zero Trust: leave it
  out if agents should not act in Zero Trust.
- **Firewall Services › Edit** and **Zone › Read**, only to block in one zone
  rather than the whole account.

An account that uses only the edge, or only Zero Trust, may leave out the
other's permissions: check-access says which parts the token covers.

**check-access verifies the token** with Cloudflare
(`GET /accounts/{account}/tokens/verify`, then `GET /user/tokens/verify` for a
token made under a person's profile): its ID, whether it is active and when it
expires. Neither needs a permission or changes anything. When the token may
read its own record (Account API Tokens › Read), check-access lists its
permissions: Detection's warns of any that is not Read; Containment's says which of
its edit permissions the record shows. **check-access never sends a change**,
so without that record Containment's edit permissions are **not verified**:
every read Containment tries works with Read as well as Edit, and an action
refused for want of one says which.

**One host.** Pion sends every request, and every next page, which Cloudflare
gives as a page number or a cursor rather than an address, to
`https://api.cloudflare.com/client/v4` and nowhere else. A connection that
names any other address, scheme or port is refused before anything is sent,
and so is an Account ID that is not 32 hexadecimal characters.

- **Removing a tool** in **Settings → Tools** forgets its token. To end it at
  Cloudflare, delete or roll the token.
- A token with a TTL ends on that date. When one has ended, or was rolled or
  deleted, the tool says Cloudflare did not accept it, and to make a new one.

## Setting it up with least access

1. **Make the token.** In **Manage Account › Account API Tokens**, choose
   **Create Token › Create Custom Token** and name it **Pion Detection**.
2. **Give it the Read permissions** in the table above, nothing that edits.
3. **Limit it** to this account under **Account Resources** and its zones under
   **Zone Resources**; optionally limit client IP addresses and set a TTL.
4. **Copy the token** into the form; Cloudflare shows it only once.
5. **Give the Account ID**, from the account's Overview page.

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
- **Rate limits.** Cloudflare allows 1,200 requests per five minutes per user.
  When it refuses one, Pion tries again after a short wait, and once more when
  Cloudflare's `Retry-After` is under 20 seconds; otherwise the answer says how
  long it asked.
- **Scope.** A token sees only the account and zones it names. A zone it does
  not cover is said not to be one the token can see, never not to exist.

## What agents can do

- `zones`, `zone-dns`: the account's zones, and a zone's DNS records read whole,
  its apex, MX and NS records first.
- `firewall-events`: what the WAF and firewall did at a zone's edge, by client
  IP address, action and time, with country, network, path, rule and Ray ID.
- `audit-log`: who changed what in the account, from where, through the
  dashboard or the API, by time, person, action and zone.
- `members`, `api-tokens`: who holds which role, with 2FA, administrators
  first; the account's own tokens with what each may do and from where.
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
- anything in zones or accounts the token does not cover.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused for want of a permission, or a token Cloudflare no longer
  accepts, wakes the agents once, and once more after Pion relaunches if it is
  still so. It wakes them again only after the feed has been read once since.
- An account without Cloudflare Access is said once to have its logins off, and
  again after a relaunch; the audit log is still watched.
- A failure that passes, such as the rate limit, holds the watch back for up to
  half an hour, reading the same window again, before it is told the same way.

## When something does not work

Ask an agent to run **check-access**. It sends only reads, so it changes
nothing, and says:

- that it reaches only `api.cloudflare.com`, for which account;
- whether Cloudflare verifies the token, whose it is, whether it is active and
  when it expires;
- the token's own permissions, when it may read them, with a warning for any
  that changes things;
- for each read, at the edge and in Zero Trust, whether it works, and if not,
  which permission to add, or that the account does not use it;
- which parts, edge and Zero Trust, the token covers.

Any refused call says the same: the permission to add, a zone or account the
token does not cover, or a token Cloudflare no longer accepts.

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

**Cloudflare Containment** is a separate tool, with its own token, so the detection
token stays read-only.

1. **Make another token**, named **Pion Containment**, with only
   **Account Firewall Access Rules › Edit** and **Zero Trust › Edit**, and to
   act in one zone **Firewall Services › Edit** and **Zone › Read** for it.
2. **Add the account** with that token and the same Account ID, and ask an
   agent to run its **check-access**. It verifies the token and tries the reads
   the actions make first; it tries no action.

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
| **check-access** (not held) | See step 2. | Nothing changes. |

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
- whether `GET /accounts/{account}/tokens/{id}` lets a token read its own
  record, and the permission names it gives;
- the GraphQL dataset and field names Gateway activity uses
  (`gatewayResolverQueriesAdaptiveGroups` with `queryNameReversed` and
  `resolverDecision`, `gatewayL7RequestsAdaptiveGroups` with `httpHost` and
  `action`, `gatewayL4SessionsAdaptiveGroups`);
- that a zone's IP Access rules list includes the account's rules, and that
  account rules give their scope's ID;
- the WARP registration endpoints (`/devices/registrations` and its `revoke`,
  which Cloudflare marks as deprecated but still documents), and that
  `revoked_at` is null for an active registration;
- that `revoke_user` takes **Zero Trust › Edit**, as the API reference says;
- that an account without Zero Trust is refused in words Pion recognises as
  such (such as "not enabled"), rather than as a missing permission;
- the exact wording of the dashboard's permissions.
