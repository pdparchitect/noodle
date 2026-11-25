---
guides: [setup]
---

# SentinelOne

Pion has two SentinelOne tools, each added per management console with a
service user and API token of its own:

- **SentinelOne Detection** reads what SentinelOne's agents see: agents, with
  whether they are disconnected from the network, infected and in touch with
  the console; threats with their indicators, storyline, mitigation actions,
  notes and timeline; the activity log of who did what; sites, groups and
  exclusions. It wakes the agents it is assigned to for new threats, agents
  newly disconnected from the network, and network disconnects and threat
  mitigations a person issued. It only reads.
- **SentinelOne Containment** acts: it disconnects an endpoint from the network
  or reconnects it, kills, quarantines, releases, remediates or rolls back a
  threat, resolves threats or sets their verdict, blocks a hash and removes
  what it blocked, and starts a scan. Every one of these but reopening a threat
  waits for your approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the SentinelOne console:

- **Settings › Users › Service Users**, for each tool's service user and token;
- **Settings › Users › Roles**, for Containment's custom role;
- the **Sentinels**, **Incidents** (threats), **Activity** and **Blocklist**
  pages, to see and undo what Containment did.

## How SentinelOne limits what Pion can do

SentinelOne has no sign-in for an admin. Each tool uses a **service user** you
make for it alone, and sends that user's **API token** with every request, as
`Authorization: ApiToken <token>`. What the token may do is exactly what its
user's **role** allows, in its user's **scope** (the account, or some sites);
nothing else is involved.

| Tool | Role | Must not have |
| --- | --- | --- |
| SentinelOne Detection | **Viewer**, at the account or the sites to investigate | any other role |
| SentinelOne Containment | a custom role, **Pion Containment**, with only: Endpoints: View, Disconnect From Network, Reconnect To Network, Initiate Scan; Threats: View, Kill, Quarantine, Un-Quarantine, Remediate, Rollback, Change Incident Status, Change Analyst Verdict; Blocklist: View, Create, Delete; Activity: View; Sites: View | Admin, IT, SOC, IR Team or any built-in role; users, policies, exclusions, uninstalling agents, Remote Shell |

The permission names follow the console's role editor, which groups them by
page; your console's version may word them a little differently. Why each is
needed:

- **Endpoints: View** reads agents; Containment reads each agent before and
  after acting on it.
- **Threats: View** reads threats, their notes and timeline.
- **Activity: View** reads the activity log; the watch reads it for network
  disconnects and mitigations.
- **Sites: View** lists sites; `block-hash` reads the site it blocks in.
- **Endpoints: Disconnect From Network** and **Reconnect To Network** for
  `disconnect-agent` and `reconnect-agent`; **Initiate Scan** for
  `initiate-scan`.
- **Threats: Kill, Quarantine, Un-Quarantine, Remediate, Rollback** for the
  matching mitigation actions; **Change Incident Status** and **Change Analyst
  Verdict** for `resolve-threat` and `update-threat-status`.
- **Blocklist: View, Create, Delete** for `block-hash` and `unblock-hash`.

**check-access reads the token's own user** (`GET /web/api/v2.1/user`): its
name, email, ID, scope, roles and where it holds them, and when its token
expires. Detection's check-access warns of any role but Viewer. Containment's warns
of a built-in role broader than it needs, and says a Viewer-only user can take
none of its actions. **check-access never sends a change**, and SentinelOne
lists no role's actions without trying one, so Containment's action permissions
are not verified: an action refused for want of one says which.

**One console each.** Every SentinelOne console is its own host, such as
`usea1-acme.sentinelone.net`. Pion takes only a host under `sentinelone.net`,
over https and without a port, and sends every request, and every next page,
which SentinelOne gives as a cursor rather than an address, to that host under
`/web/api/v2.1`. Any other address, such as an on-premises console or one under
another domain, is refused before anything is sent: Pion does not support
those, as SentinelOne's documentation names no other domain for its cloud
consoles that Pion could check.

- **Removing a tool** in **Settings → Tools** forgets its token. To end it at
  SentinelOne, revoke the token or delete the service user.
- Tokens expire on the date set for the service user. When one expires, or is
  revoked or regenerated, the tool says SentinelOne did not accept the token,
  and to generate a new one.

## Setting it up with least access

1. **Make the service user.** In **Settings › Users › Service Users**, choose
   **Actions › Create New Service User**. Name it **Pion Detection**, and give it an
   expiration date.
2. **Give it the Viewer role** at the scope agents should see: the account, or
   only the sites to investigate.
3. **Copy the API token** into the form; SentinelOne shows it only once.
4. **Give the console address**: its host as your browser shows it, such as
   `usea1-acme.sentinelone.net`.

Then ask an agent to run **check-access**.

## Coverage you should know

- **Searches are bounded and say what they left out.** `threats` and
  `activities` search by time, up to a year back, newest first. Every listing
  follows SentinelOne's `nextCursor` page after page with the same query, and
  says when it stopped before the end, and why: a page that failed (the pages
  before are kept), a cursor Pion will not follow or given twice, or
  SentinelOne's `totalItems` saying more match than it gave without a next
  page. A result that matched more than it kept says so, with SentinelOne's own
  count.
- **Exclusions** are read whole, then shown newest first, as SentinelOne does
  not sort them by when they were added; when not all could be read, the result
  says the newest may be among those not read.
- **Rate limits.** SentinelOne limits each token's requests. When it refuses
  one, Pion tries again after a short wait, and once more when SentinelOne says
  how long to wait and that is under 20 seconds; otherwise the answer says how
  long it asked.
- **Scope.** A token sees only its service user's sites. An agent or threat
  outside them is said not to be in the token's scope, never not to exist.

## What agents can do

- `agents`: agents by part of their computer name, network status, infection,
  OS, site, group or when last active, with each one's numeric ID.
- `agent`: one agent in full, with its network status, whether it is in touch
  with the console, its scan status and its unresolved threats.
- `threats`, `threat`: threats by computer, agent, incident status, confidence
  and time; one threat with its file, hashes, process, storyline, MITRE
  indicators, every mitigation action and where it stands, notes and newest
  timeline entries.
- `activities`, `activity-types`: the activity log by agent, threat, user, type
  and time, and the types it records.
- `sites`, `groups`, `exclusions`: exclusions say who added each and when; an
  exclusion an attacker added hides what they do.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads three feeds:

- **threats** that are unresolved, of malicious or suspicious confidence,
  including those whose confidence or status SentinelOne does not give;
- **network disconnects and threat mitigations a person issued**, from the
  activity log: entries of the activity types whose own names say a network
  disconnect, or a kill, quarantine, release, remediation or rollback of a
  threat, that name the user who issued them. Pion picks those types from the
  console's own list (`activity-types`), as SentinelOne publishes no fixed
  numbers for them; a console whose list names none is said, once, to be off;
- **agents disconnected from the network**, or with a disconnect pending,
  compared with the last whole read. The first whole read after Pion starts
  only learns them; after that, each agent newly disconnected, by anyone or by
  a policy, is told once.

Threats and the activity log each read from six hours before the newest seen,
as SentinelOne lists some after they happened, up to four pages each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing SentinelOne wrote reaches the note: no ID, name,
computer, user or description. Each threat, entry and newly disconnected agent
is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind takes its turn: malicious threats, network disconnects and newly
  disconnected agents first, then suspicious threats and mitigations;
- the watch says once that more follow;
- the checks after read on from the oldest not yet handed over, until all of it
  is handed over, even across a check that could not read the feed.

A check that reaches its four pages keeps SentinelOne's cursor for the next page
and the exact query it belongs to. The next check goes on from there, never
from a time, so even thousands of threats detected at the same moment are read
through once. When that search ends, the feed reads on from six hours before
its end, however far the watch has moved on meanwhile. If SentinelOne turns
down a kept cursor, the watch says so once and reads that window again from its
start.

A check that fails for a passing reason, such as the rate limit, keeps nothing
but how many checks in a row failed, so the next check reads the same window
again.

**What it does not watch:**

- threats resolved, or of confidence n/a, before a check read them;
- a threat set back to unresolved after the watch passed the time it was
  detected;
- STAR custom-rule alerts and Singularity's unified alerts, which this tool
  does not read;
- what the agents or a policy did on their own, such as automatic mitigation,
  though an agent a policy disconnected shows among those disconnected;
- an agent disconnected and reconnected between two checks, or while Pion was
  not running;
- network disconnects and mitigations of an activity type Pion does not
  recognise from the console's own names;
- anything outside the service user's scope.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused for want of a permission, or a token SentinelOne no longer
  accepts, wakes the agents once, and once more after Pion relaunches if it is
  still so. It wakes them again only after the feed has been read once since.
- A feed the console lacks, by licence or by its activity types, is said once
  to be off, and again after a relaunch.
- A failure that passes, such as the rate limit, holds the watch back for up to
  half an hour, reading the same window again, before it is told the same way.

## When something does not work

Ask an agent to run **check-access**. It sends only reads, so it changes
nothing, and says:

- which console it reaches;
- the token's service user, its scope, its roles and when the token expires;
- for Detection, whether the user holds only Viewer, with a warning otherwise;
- for each read, whether it works, and if not, which permission to add or that
  the console lacks the licence.

Any refused call says the same: the permission to add, or a token SentinelOne
no longer accepts.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why.
- **An answer Pion cannot read is an error, never "nothing found".** A page
  without its list, an agent, threat or entry without its ID, or any answer
  carrying an error, with a message or without, is an error.
- **Absent only when SentinelOne says so plainly.** One agent, threat or
  blocklist entry asked for by ID is absent only when SentinelOne answers with
  an empty list, no errors, no next page and a count of none or no count, or
  with a 404 whose every error has code 404 and gives that very ID in its own
  `id` field; its wording is never read, as a 404 for a wrong address
  echoes the IDs asked for. It is present only in a whole answer that gives it
  alone, with any count it gives equal to what it gave. Anything else, such as
  another ID, the same one twice, a next page, a count that differs from what
  was given, or a count or cursor of the wrong type, is inconclusive.
- **Unknown is not none.** A network status, confidence or status SentinelOne
  does not give is shown as unknown; the watch treats a threat of unknown
  confidence as watched.

## Containing an incident

**SentinelOne Containment** is a separate tool, with its own service user, so
the detection user stays read-only.

1. **Make the role.** In **Settings › Users › Roles**, choose **New Role**,
   name it **Pion Containment**, and give it only the permissions in the table
   above.
2. **Make another service user**, named **Pion Containment**, with an
   expiration date and the Pion Containment role, at the scope agents may act
   on.
3. **Add the account** with its token and the same console, and ask an agent to
   run its **check-access**. It reads the token's user and role, and the reads
   the actions make first; it tries no action, so their permissions are not
   verified.

What agents can do. Each action but `update-threat-status` is held for your
approval. Each one's description and result say what recovering from it
involves:

| Action | What it does | Recovery |
| --- | --- | --- |
| `agent`, `threat` (not held) | Read an agent's network and scan status, or a threat's OS, status, verdict and mitigation history, before acting. | Nothing changes. |
| `action-status` (not held) | Reads where an agent's or threat's action stands, with the newest activity log entries about it, or every blocklist entry for a hash in a site and whether Pion's record says it made each. | Nothing changes. |
| `disconnect-agent` | Cuts the endpoint off the network, keeping it in touch with the console. | `reconnect-agent` restores network access, and must be asked for explicitly. Every workload on it is cut off meanwhile. |
| `reconnect-agent` | Restores the endpoint's network access. Held, as it gives access back. | `disconnect-agent` again. An attacker still on it regains access too. |
| `initiate-scan` | Starts a full disk scan. Held, as it is a change that uses the endpoint's resources. | None needed; abort it in the console if it gets in the way. What it finds is handled as the agent's policy says. |
| `kill-threat` | Ends the threat's processes. | None: their memory and unsaved work are gone for good. |
| `quarantine-threat` | Moves the threat's file into the agent's encrypted quarantine. | `unquarantine-threat` restores it. |
| `unquarantine-threat` | Releases the file from quarantine, back where it was. SentinelOne offers this through the same mitigation API as quarantine. | `quarantine-threat` again. The file can run again meanwhile. |
| `remediate-threat` | Removes the threat's files and the changes the agent tied to it, such as registry keys and scheduled tasks. | None through SentinelOne. |
| `rollback-threat` | Windows only: remediates and restores the files the threat touched from Volume Shadow Copy snapshots. | None through SentinelOne. It can undo the user's own legitimate changes to those files since the snapshot. |
| `resolve-threat` | Resolves threats, optionally with a verdict, false positive included, which hides them from the unresolved queue and the watch. | `update-threat-status` unresolved or in_progress reopens each. |
| `update-threat-status` (not held) | Sets threats in progress or unresolved, or a verdict of true positive, suspicious or undefined. It hides nothing. | `update-threat-status` again, or `resolve-threat`. |
| `block-hash` | Adds a SHA1 or SHA256 to one site's blocklist for one OS, gives its ID, and records that Pion made it. | `unblock-hash` with its ID removes it; files mitigated meanwhile are not restored by that. |
| `unblock-hash` | Removes one entry, by its ID, that Pion's record says it made through this connection and that SentinelOne still holds as made. | `block-hash` again. The file can run on the site's endpoints at once. |
| **check-access** (not held) | See step 3. | Nothing changes. |

**Every action names exact IDs, and nothing else.** SentinelOne acts on
whatever an action's filter matches, and an empty or broad filter could match
every endpoint. Pion sends each action with a filter of the exact agent or
threat IDs approved and no site, group or query, after reading them through
that same filter and finding exactly them: one agent or threat with that ID, no
other, no error, and no count saying more match. A blocklist entry is made in
the one site given, after reading that site, and removed by its ID alone.

Pion reads what it acts on, whole, just before acting, and refuses, sending
nothing:

- an ID or hash that is malformed;
- an agent or threat it cannot read whole through the action's filter, or one
  SentinelOne does not return;
- disconnecting an agent already disconnected, or with a disconnect or
  reconnect pending; reconnecting one that is connected, or with either
  pending;
- a scan on an agent already scanning;
- a mitigation its history shows pending; quarantining, remediating or rolling
  back a threat its history shows already so; releasing a threat its history
  shows not quarantined;
- rollback on a threat whose OS is not Windows, or not given;
- resolving or setting threats already as asked, or when not every threat could
  be read;
- blocking a hash any entry already holds, in the site or above it, whoever
  made it, or when not every entry for it could be read;
- removing an entry Pion has no record of making through this connection, one
  recorded as changed since it was made, or one not exactly as made: any of type, value, OS,
  site ID, description, scope name, who made it or its `updatedAt` differing,
  or one given without a field it must give;
- removing an entry when SentinelOne's answer for it shows neither that it is
  there nor that it is gone.

A network status or mitigation history SentinelOne does not give blocks
nothing; the result says it could not confirm the state before.

**A request taken is not a request done.** SentinelOne's answer to an action
says only how many it affected. Pion says done only when that count is exactly
the IDs approved and reading them again shows the result: an agent's network
status disconnected (or connected, for a reconnect), a new record of that
mitigation in the threat's history saying it succeeded, each threat with the
status and verdict asked for, a blocklist entry read back in its site as made,
or an entry plainly gone. When a threat's mitigation history was not given
before acting, only a record of that action dated at or after the request
counts as this request's. When an agent's network status was not given before,
the result confirms the state it reached but not that this request brought it
about. **disconnecting**, **connecting**, a mitigation
record saying pending, and a scan not yet started are said to be pending, not
done, with `action-status` to poll. A count of none, of fewer, or of more than
approved (which Pion flags to check the console at once), a state that does not
follow, or an answer Pion cannot read is reported unverified, with the
request's path and the IDs it named.

**Which blocklist entries are Pion's.** Pion's entries carry a description
starting "Pion, after the champion's approval", for people reading the console,
but anyone can write that, so it proves nothing. What `block-hash` made, Pion
records itself, and only from a plain answer to the request that made it: no
error at all, and exactly one black_hash entry of the hash and OS asked for,
whose site ID is the site asked for. The site is bound by its ID alone, never
its name, which two sites can share. That answer is the record:
the entry's ID, its site, when, and everything SentinelOne gave of it (type,
value, OS, site ID, description, scope name, who made it and `updatedAt`), kept for the
connection and its console in Pion's own data, so it outlasts a relaunch. An
answer with errors, more or fewer entries, another hash, type or OS, or no
site leaves no record, and the result says to remove the entry in the console.
Pion then reads the entry back in its site: one that differs from the answer,
or gives another site ID or none, is recorded as changed since it was made, and `unblock-hash` leaves it to the
console. `unblock-hash` takes one ID, and removes it only if that record holds
it unchanged and SentinelOne, read just before, still gives every one of
those fields as recorded, the approved site ID included.
It says removed, and drops the record, only when SentinelOne's answer counts
exactly one entry with no error and a read then plainly finds none; any other
answer, of none, no count, more, errors or something unreadable, leaves the
removal unverified and the record kept. An entry Pion made but has no record
of, as when the record could not be saved, which the result says, is removed in
the console.

SentinelOne takes no condition on a change, so someone else can act on the
agent, threat or entry between Pion reading it and acting. Each result says
when Pion read it.

## What to check on a live console

These follow SentinelOne's published Management API, but were tested only
against stand-ins:

- that `GET /web/api/v2.1/user` gives the service user's roles in `scopeRoles`
  or `siteRoles`, and its token's `apiToken.expiresAt`;
- that the activity types your console lists include network disconnects and
  threat mitigations under names Pion recognises (`activity-types` lists
  them), and that a person's entries name their `userId`;
- the blocklist's filters (`siteIds`, `includeParents`, `value__contains`,
  `ids`), that SHA256 entries are accepted (older consoles take SHA1 only), and
  that blocklist entries give their `siteId`, without which Pion keeps no
  record of one and removes none;
- that a 404 for something not found has code 404 and gives its ID in the
  error's `id` field;
  otherwise such answers are inconclusive, never absent;
- the exact wording of the role editor's permissions.
