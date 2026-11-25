# CrowdStrike Falcon

Pion has two CrowdStrike Falcon tools, each added per Falcon customer (CID)
with an API client of its own:

- **CrowdStrike Falcon Detection** reads what Falcon's sensors see: hosts, with
  their containment status and whether they are online, alerts with their
  process trees, who used Real Time Response on which host and every command
  they ran, host groups, assessed container images, who can use the
  console, prevention policies with the protections they turn on, and
  exclusions. It wakes the agents it is assigned to for new high and critical
  alerts, Real Time Response sessions and hosts newly contained. It only reads.
- **CrowdStrike Falcon Containment** acts: it contains a host or lifts
  containment, blocks a hash (or alerts on a domain or address) as a custom
  indicator and removes one it made, kills one process through Real Time
  Response, and closes alerts. Every one of these waits for your approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the Falcon console:

- **Support and resources › API clients and keys**, for each tool's API client
  and its scopes;
- **Host setup and management › Response policies**, for Real Time Response on
  the hosts Containment may act on;
- the **Host management**, **Real Time Response** audit and **IOC management**
  pages, to see and undo what Containment did.

## How Falcon limits what Pion can do

Falcon has no sign-in for an admin. Each tool uses an **API client** you make
for it alone: Pion gets a token with its client ID and secret, through OAuth2
client credentials, from the Falcon cloud you choose
(`https://<cloud>/oauth2/token`). What the client may do is exactly the **API
scopes** you give it, whoever made it; no user's roles are involved.

| Tool | Scopes it needs | Scopes it must not have |
| --- | --- | --- |
| CrowdStrike Falcon Detection | **Hosts: Read**, **Alerts: Read**; and, for the parts that use them, **Real time response audit: Read**, **Host groups: Read**, **Falcon Container Image: Read**, **User management: Read**, **Prevention policies: Read**, **Machine Learning Exclusions: Read**, **IOA Exclusions: Read**, **Sensor Visibility Exclusions: Read** | any **Write** scope |
| CrowdStrike Falcon Containment | **Hosts: Read**, **Hosts: Write**, **Alerts: Read**, **Alerts: Write**, **IOC Management: Read**, **IOC Management: Write**, **Real time response: Read**, **Real time response: Write** | **Real time response (admin): Write**, **Host groups: Write**, and any other Write scope |

Why each is needed:

- **Hosts: Read** finds hosts, describes them and says whether their sensor is
  online; Containment reads the host before and after acting.
- **Alerts: Read** reads alerts; the watch reads high and critical ones.
- **Real time response audit: Read** reads who opened a Real Time Response
  session on which host and the commands they ran; the watch reads new
  sessions.
- **Host groups: Read** lists host groups and their members.
- **Falcon Container Image: Read** reads container image assessments.
- **User management: Read** lists console users and their roles.
- **Prevention policies: Read** lists prevention policies, their settings and
  how many hosts each reaches.
- **Machine Learning Exclusions: Read**, **IOA Exclusions: Read** and
  **Sensor Visibility Exclusions: Read** each list one kind of exclusion;
  `exclusions` reads the kinds it may and says which it may not.
- **Hosts: Write** contains a host and lifts containment.
- **Alerts: Write** closes alerts, sets them in progress or reopens them.
- **IOC Management: Read and Write** reads, makes and removes custom
  indicators.
- **Real time response: Read** opens a session and runs the read-only `ps`;
  **Real time response: Write** runs `kill`.

Containment never holds **Real time response (admin): Write**, which runs
scripts, puts files on hosts and runs programs. Pion never runs a command an
agent wrote: it runs only `ps` and `kill`, with values it has checked, in a
session it opens and closes itself. It deletes no file: Real Time Response has
no quarantine command, and deleting is not offered.

**Falcon tells no API client which scopes it holds**, neither in its token nor
through its API, and says whether a client holds a write scope only to a
request that tries a change. **check-access never sends one.** It tries every
read it needs, and reads the status of a Real Time Response command that does
not exist, which needs **Real time response: Write**, and of an admin command,
which needs **Real time response (admin): Write**: Falcon refuses each with a
403 when the client lacks the scope, so those two are shown. For every other
write scope it says "write access not verified". The table above is guidance:
confirm on each client's page that it holds only what the table lists, and that
Detection's client holds no Write scope at all.

**One cloud each.** Pion offers Falcon's US-1 (`api.crowdstrike.com`), US-2
(`api.us-2.crowdstrike.com`), EU-1 (`api.eu-1.crowdstrike.com`) and US-GOV-1
(`api.laggar.gcw.crowdstrike.com`) clouds, chosen from a list; nothing else
can be entered. Each tool reaches only the cloud chosen, for its token and its
requests, and refuses to run against any other address. Falcon's next pages are
an offset or a token, never an address, so a listing never leads elsewhere.

- **Removing a tool** in **Settings → Tools** forgets its ID and secret. To end
  the client at Falcon, delete it or reset its secret on its page.
- When the secret is reset or the client deleted, the tool says Falcon did not
  accept its ID and secret, and to give a new secret.

## Setting it up with least access

1. **Make the client.** In **Support and resources › API clients and keys**,
   choose **Create API client**. Name it **Pion Falcon Detection**.
2. **Give it only Read scopes**: **Hosts** and **Alerts**, and those of
   Real time response audit, Host groups, Falcon Container Image, User
   management, Prevention policies, Machine Learning Exclusions, IOA
   Exclusions and Sensor Visibility Exclusions you want agents to read. Leave
   every **Write** box empty.
3. **Copy the Client ID and Secret** into the form; Falcon shows the secret
   only once.
4. **Choose the Falcon cloud** your console's address names:
   `falcon.crowdstrike.com` is US-1, `falcon.us-2.crowdstrike.com` US-2,
   `falcon.eu-1.crowdstrike.com` EU-1 and `falcon.laggar.gcw.crowdstrike.com`
   US-GOV-1.

Then ask an agent to run **check-access**.

## Coverage you should know

- **Searches are bounded and say what they left out.** `alerts` searches by
  when each was raised, up to 90 days back, newest first, reading Falcon's
  combined listing page after page by the token each page gives. `hosts`,
  `rtr-sessions`, `host-groups`, `container-images`, `users`,
  `prevention-policies` and `exclusions` page by offset.
  Every result says when it stopped before the end, and why, and when more
  matched than it kept, with Falcon's own count when it gives one.
- **Falcon pages by offset only through the first 10,000** of a search. A
  search that reaches that says so: narrow it.
- **Incidents.** Falcon retired its incidents API in 2026, so Pion reads
  incidents as the alerts they gathered.
- **Rate limits.** Falcon allows each customer so many requests a minute,
  shared by every API client. When it refuses one, Pion tries again after a
  short wait, and then waits once more for as long as Falcon's
  `X-RateLimit-RetryAfter` asks, when that is under 20 seconds; otherwise the
  answer says how long Falcon asked to wait.
- **Prevention policies.** Falcon puts every host no other policy reaches on
  its platform's default policy, so "hosts on the default policy" is where a
  host in no policy shows up. The hosts each policy reaches are Falcon's count
  of its members, read for the defaults and enabled policies, up to 60; a
  disabled policy reaches none. When Falcon does not sort policies by
  precedence, the result says their order is not Falcon's. A protection is
  said to be off when its toggle is off or its machine learning slider is
  DISABLED; Falcon's own setting names are shown, and protections Pion does not
  know are listed with the rest when off.
- **Exclusions.** Pion reads the three kinds through Falcon's v1 exclusion
  APIs; certificate-based exclusions and exclusions made in other modules are
  not read. "Broad" is Pion's reading of the pattern, not Falcon's: confirm
  each with whoever made it. Sensor visibility exclusions stop Falcon recording
  what matching processes do, so even a narrow one deserves a reason.
- **Kubernetes and containers.** `host` says when Falcon's record of a host
  holds a hint that it runs Kubernetes workloads (a cluster ID, a DaemonSet
  sensor, pod fields or tags) or containers (tags). A hint suggests what runs
  there; it does not verify that the host is a Kubernetes node. With no hint,
  Pion cannot tell, which is not proof it runs none.

## What agents can do

- `hosts`: hosts by the start of their name, an IP address, platform,
  containment status, host group or when last seen, with each one's 32-character
  device ID.
- `host`: one host in full, with whether its sensor is online, its containment
  status, tags and groups, Kubernetes and container signs, and the newest
  alerts that named it.
- `alerts`, `alert`: alerts by host, least severity, status and time; one alert
  with its process, parent and grandparent, command lines, hashes, user, MITRE
  tactic and technique, and what Falcon did about it.
- `rtr-sessions`: Real Time Response sessions by host, user and time, with every
  command run in each.
- `host-groups`: host groups with their type and rule, or the hosts in one.
- `container-images`: assessed container images by repository and least
  vulnerability severity.
- `users`: everyone who can use the console, with their roles, administrators
  first.
- `prevention-policies`: each platform's prevention policies in the order
  Falcon applies them, its default last, with whether each is enabled, its host
  groups, how many hosts it reaches, who changed it last, and its protections:
  sensor tampering protection, quarantine, the machine learning levels, and
  the exploit, ransomware and other behaviour protections, with every other
  setting that is off. It leads with disabled policies, how many hosts are on
  each platform's default policy and how many have not yet applied theirs, and
  the protections turned off in enabled policies.
- `exclusions`: machine learning, IOA and sensor visibility exclusions, each
  with its pattern, whether it applies to every host or which host groups,
  what it is excluded from, and who made and last changed it. It leads with
  those for every host and broad ones: a pattern for every file, a whole drive,
  any folder, a folder people may write to such as Users, Temp or Downloads,
  or an IOA exclusion for any program or command line. Agents can ask for one
  kind.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads three feeds:

- **alerts** of High or Critical severity that are not closed, including those
  of a status Falcon does not give;
- **Real Time Response sessions** opened by anyone, Pion included, with the
  commands run;
- **contained hosts**: hosts contained or with containment pending, compared
  with the last whole read. The first whole read after Pion starts only learns
  them; after that, each host newly contained is told once.

Alerts and sessions each read from six hours before the newest seen, as Falcon
lists some alerts after they were raised, up to four pages each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing Falcon wrote reaches the note: no ID, name, host,
user or command. Each alert, session and newly contained host is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind takes its turn: critical alerts and newly contained hosts first,
  then high alerts, then sessions;
- the watch says once that more follow;
- the checks after read on from the oldest not yet handed over, until all of it
  is handed over, even across a check that could not read the feed.

A check that reaches its four pages keeps the token of Falcon's next page and the
exact search it belongs to. The next check goes on from there, never from a
time, so even thousands of alerts raised at the same moment are read through
once. When that search ends, the feed reads on from six hours before its end,
however far the watch has moved on meanwhile. If Falcon turns down a kept token,
the watch says so once and reads that window again from its start.

A check that fails for a passing reason, such as Falcon's rate limit, keeps
nothing but how many checks in a row failed, so the next check reads the same
window again.

**What it does not watch:**

- alerts below High severity;
- alerts closed before a check read them;
- an alert raised to High after it was made, once the watch has passed its
  creation time;
- incidents, whose API Falcon retired; their alerts are watched;
- a host contained and released between two checks, or while Pion was not
  running, and who contained a host, which Falcon's API does not say;
- what the sensors saw that raised no alert.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused for want of a scope, or an ID and secret Falcon no longer
  accepts, wakes the agents once, and once more after Pion relaunches if it is
  still so. It wakes them again only after the feed has been read once since.
- A customer without the subscription a feed needs is said once to be off, and
  again after a relaunch.
- A failure that passes, such as Falcon's rate limit, holds the watch back for
  up to half an hour, reading the same window again, before it is told the same
  way.

## When something does not work

Ask an agent to run **check-access**. It sends only reads, so it changes
nothing, and says:

- which Falcon cloud it reaches;
- for each read, whether it works, and if not, which scope to add or that the
  customer lacks the subscription, prevention policies and each kind of
  exclusion included;
- whether the client appears to hold **Real time response: Write** or
  **Real time response (admin): Write**, which Detection must not, with a warning to
  remove either;
- that every other write scope is not verified, as Falcon offers no way to list
  a client's scopes without attempting a change.

Any refused call says the same: the scope to add, or an ID and secret Falcon no
longer accepts.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why. A result that matched more than it kept says so. When a later
  page fails, the pages already read are kept and the result says which page it
  stopped at and why.
- **An answer Pion cannot read is an error, never "nothing found".** A page
  without its list, a host without its device ID, or an alert without its ID is
  an error.
- **Unknown is not none.** A containment status, severity or status Falcon does
  not give is shown as unknown; the watch treats an alert of unknown status as
  open, and a console user whose roles could not be read is said to be unknown,
  never to have none.
- **"No alerts" is not "none happened".** A search says nothing matched only in
  what it read.

## Containing an incident

**CrowdStrike Falcon Containment** is a separate tool, with its own API client,
so the detection client stays read-only.

1. **Make another client**, named **Pion Falcon Containment**, with only
   Containment's scopes from the table above. Never give it **Real time
   response (admin): Write**.
2. **Turn on Real Time Response** for the hosts agents may act on, in
   **Host setup and management › Response policies**, for `rtr-kill-process`.
   Pion runs only `ps` and `kill`, so leave **Custom scripts**, **put** and
   **run** off for it. Containing hosts, indicators and alerts need no policy
   change.
3. **Add the account** with this client's ID and secret and the same cloud, and
   ask an agent to run its **check-access**. It sends only reads: those the
   actions make first, and the command-status reads that show whether the
   client holds **Real time response: Write**, which `kill` needs, and not
   **Real time response (admin): Write**. Hosts, Alerts, IOC Management and
   Host groups Write are not verified; an action refused for want of one says
   which.

What agents can do. Each action is held for your approval. Each one's
description and result say what recovering from it involves:

| Action | What it does | Recovery |
| --- | --- | --- |
| `host` (not held) | Reads the host's containment status, whether its sensor is online, and whether Falcon's record holds a hint that it runs Kubernetes workloads or containers (a hint, not verified), or Pion cannot tell. | Nothing changes. |
| `action-status` (not held) | Reads where a host's containment stands, or every custom indicator for a value and whether Pion's record says it made each. | Nothing changes. |
| `contain-host` | Cuts the host, and every workload on it, off the network, keeping it connected to Falcon. Takes the host's workloads, exactly as `host` gave them (`kubernetes-suggested`, `containers-suggested` or `cannot-tell`), so the approval shows what the record hints runs there. | `lift-containment` restores network access, and must be asked for explicitly. Every pod and container the host runs is cut off too. |
| `lift-containment` | Restores the host's network access. Held, as it gives access back. | `contain-host` again. An attacker still on the host regains access too. |
| `block-ioc` | Adds a custom indicator on every host, gives its ID, and records that Pion made it: a SHA256 or MD5 to block (prevent) or alert on (detect), or a domain or IP address to alert on. | `unblock-ioc` with its ID removes it, ending the block at once. A file Falcon quarantined, or a process it stopped, meanwhile is not restored by that; release a quarantined file in the console. |
| `unblock-ioc` | Removes one indicator, by its ID, that Pion's record says it made through this connection and that Falcon still holds as made; any other is left in place. | `block-ioc` again. Removing it lets the hash run on every host at once. |
| `rtr-kill-process` | Ends one process by its PID and name, only when `ps` lists that PID as that process; then lists the processes again and says whether the process with that PID and name is still listed. | None: the process's memory and unsaved work are gone for good. It can only be started again, and a service may restart itself. |
| `close-alert` | Closes alerts, with Pion's comment, which hides them from the open queue and the watch. | `update-alert-status` reopened puts each back in the open queue. |
| `update-alert-status` (not held) | Sets alerts in progress or reopens them, with an optional comment. It hides nothing. | `update-alert-status` again, or `close-alert`. |
| **check-access** (not held) | See step 3. | Nothing changes. |

Hosts are given by their 32-character device ID, which Detection's `hosts`, `host`
and `alert` give, and alerts by their composite ID.

Pion reads what it acts on, whole, just before acting, and refuses, sending
nothing:

- an ID, hash, domain, address, PID or process name that is malformed, or a PID
  of 4 or below;
- a host Falcon does not return;
- containing a host already contained, or with containment or its lift
  pending; lifting a host that is not contained, or with either pending;
- containing a host whose workloads, as given, are not what Falcon's record
  hints;
- blocking a domain or address with prevent, which Falcon does not do;
- blocking a value Falcon already holds an indicator for, whoever made it, or
  when not every indicator for the value could be read;
- removing an indicator Pion has no record of making through this connection,
  or one that is not exactly as Falcon said it made it: any field differing
  (type, value, action, severity, platforms, where it applies, expiration,
  tags, mobile action, version or its modified time), or one Falcon gives
  without a modified time or another field it must give;
- removing an indicator when Falcon's answer for it shows neither that it is
  there nor that it is gone: errors, another indicator, two of it, a 404 that
  does not say it found none, or an answer Pion cannot read;
- Real Time Response on a host whose sensor is not online now: Pion never queues
  a session for an offline host;
- killing a PID that `ps` does not list, or lists as another process;
- closing or changing an alert Falcon does not return, or one already in the
  status asked for.

A containment status Falcon does not give blocks nothing; the result says it
could not confirm the state before.

**A request taken is not a request done.** Falcon contains a host, or lifts
containment, when its sensor next connects: Pion reads the host again a few
times over about ten seconds, and says done only when Falcon's answer named the
host and its status is then contained (or normal, for a lift).
**containment_pending** and **lift_containment_pending** are said to be pending,
not done, with `action-status` to poll. An indicator is done only when Falcon's
answer names it with the type, value, action, severity and platforms approved,
applied on every host and with the expiration approved, or none; one made
otherwise is reported as Falcon made it, not done, and recorded so
`unblock-ioc` can remove it. An indicator is removed only when Falcon then says
plainly it holds none, with an empty answer or a 404 saying so; any other
answer leaves the removal unverified and Pion's record in place;
an alert's status only when Falcon then gives it. Anything else is reported
unverified, with Falcon's ID for the request. After a kill, Pion says what `ps`
then shows, that the process with that PID and name is no longer listed, as an
observation, not proof the kill ended it; a list it cannot read leaves the
outcome unverified.

**Which indicators are Pion's.** Pion's indicators carry the source `Pion` and
the approval's reason as their description, for people reading the console,
but anyone can give an indicator those, so they prove nothing. What `block-ioc`
made, Pion records itself: each indicator's ID, when, and everything Falcon's
answer said it made (type, value, action, severity, platforms, where it
applies, expiration, tags, mobile action, version and modified time), kept for
the connection and its Falcon cloud in Pion's own data, so it outlasts a
relaunch. `unblock-ioc` takes one ID, and removes it only if that record holds
it and Falcon still gives every one of those fields as recorded, by ID, never by
a search, which Falcon would apply over the IDs given; it drops the record once
Falcon plainly holds it no longer.
An indicator Pion made but has no record of, as when the record could not be
saved, which the result says, is removed in the console.

Falcon takes no condition on a change, so someone else can act on the host,
indicator or alert between Pion reading it and acting. Each result says when
Pion read the host.

## What to check on a live account

`prevention-policies` and `exclusions` follow CrowdStrike's published API
specification, but were tested only against stand-ins:

- the scope names as the API client page shows them: **Prevention policies**,
  **Machine Learning Exclusions**, **IOA Exclusions** and **Sensor Visibility
  Exclusions**;
- that prevention policies sort by `precedence.asc` in the order Falcon
  applies them, and that `prevention-members` counts the hosts a policy
  reaches rather than every host in its groups;
- that hosts filter on `device_policies.prevention.applied:false`;
- the IDs of prevention settings on Mac and Linux, which Pion knows from
  Windows's and shows by name otherwise;
- that exclusions give their host groups as objects with a name, and the group
  `all` for those on every host.
