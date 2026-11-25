# Microsoft Defender XDR

Pion has two Microsoft Defender XDR tools, each added per tenant with a sign-in
of its own:

- **Microsoft Defender XDR Detection** reads what Microsoft's detections found:
  alerts and incidents across Defender for Endpoint, Office 365, Identity,
  Cloud Apps and the rest, advanced hunting across their tables, and the
  devices Defender for Endpoint reports. It wakes the agents it is assigned to
  for new high-severity alerts and incidents. It only reads.
- **Microsoft Defender XDR Containment** acts on devices through Defender for
  Endpoint: it isolates a device or releases it, restricts which apps run on it
  or lifts that, stops and quarantines a file, runs an antivirus scan and
  collects an investigation package. Every one of these waits for your
  approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use:

- in the [Microsoft Entra admin center](https://entra.microsoft.com):
  **App registrations**, for each tool's app, its redirect URI and its API
  permissions; **Enterprise applications**, to let only each tool's admin use
  its app; and **Roles and administrators**, for Detection's admin;
- in the [Microsoft Defender portal](https://security.microsoft.com):
  **System › Permissions**, for each admin's Defender role and the device
  groups it covers, and **Action center**, to see and undo what Containment did.

## How Microsoft limits what Pion can do

Both tools sign in as an admin through OAuth, at your tenant's own address on
Microsoft's sign-in service
(`https://login.microsoftonline.com/<your tenant>/oauth2/v2.0/authorize` and
`/token`), the same way as the Microsoft Entra ID tools. Each signs in through
an app registration your organisation makes for that tool alone, as a public
client with an authorization code and PKCE, so Pion keeps no client secret or
certificate. Every sign-in asks for the admin's password again, so a browser
already signed in to Microsoft as someone else never answers for them. Your
Conditional Access policies apply to the sign-in as to any other.

Microsoft allows a request only when **both** of these allow it:

- **the app's delegated permissions**, which you add under **API permissions**
  and grant admin consent for. Pion asks for exactly the permissions below,
  and refuses a sign-in that lacks any.
- **the signed-in admin's roles**, and in Defender for Endpoint, the device
  groups those roles cover. Each tool gets an admin of its own.

| Tool | API | Delegated permissions | Admin's roles |
| --- | --- | --- | --- |
| Microsoft Defender XDR Detection | Microsoft Graph | `SecurityAlert.Read.All`, `SecurityIncident.Read.All`, `ThreatHunting.Read.All`, `User.Read` | Security Reader |
| Microsoft Defender XDR Containment | Defender for Endpoint (**WindowsDefenderATP**) | `Machine.ReadWrite`, `Machine.Isolate`, `Machine.RestrictExecution`, `Machine.StopAndQuarantine`, `Machine.Scan`, `Machine.CollectForensics` | only the Defender permissions its actions take, below |

Both also ask for `offline_access`, so the sign-in renews itself; Microsoft
never lists it among the permissions it granted, so Pion does not require it
back.

**Check on first sign-in: how Microsoft lists Containment's permissions.** Pion
asks for them with the resource in front, as Microsoft's docs say, and checks
the token response lists each one the same way. Should Microsoft list them
without the resource in front, every Containment sign-in is refused as lacking
permissions, and needs a change in how Pion compares them; Detection's Graph
permissions are not affected.

**One sign-in reaches one API.** Microsoft gives a token for one API at a time,
so Detection reads Microsoft Graph alone, and Containment the Defender for Endpoint
API alone, asking for its permissions as
`https://api.securitycenter.microsoft.com/<permission>`, the resource that API's
tokens must name, and sending requests to `api.security.microsoft.com`.

Why Detection asks for each:

- `SecurityAlert.Read.All` reads alerts, with their evidence.
- `SecurityIncident.Read.All` reads incidents and the alerts they gather.
- `ThreatHunting.Read.All` runs advanced hunting queries, which is also how
  `devices` and `device` read Defender for Endpoint's DeviceInfo table.
- `User.Read` reads the signed-in admin and the tenant, which check-access
  names.

Detection does not read Defender for Endpoint's machine actions, such as who
isolated a device. That API reads a single device or its machine actions only
with `Machine.ReadWrite`, which could also change a device's tags, so it belongs
to Containment, whose `machine-actions` reads them. Containment never changes a
device's tags.

- **Sign Out** in **Settings → Tools** forgets the sign-in. Microsoft offers no
  way for an app to revoke its own sign-in; to end it at Microsoft, revoke the
  admin's sessions in the Entra admin center.
- When the sign-in expires or is revoked, the admin is disabled or their
  password changes, or a Conditional Access policy blocks it, the tool says to
  connect it again.

Detection reaches only `login.microsoftonline.com`, at your tenant's own address,
and `graph.microsoft.com`; Containment only `login.microsoftonline.com` and
`api.security.microsoft.com`. Pion checks the tenant is a Directory (tenant) ID
or a domain alone, and refuses `common`, `organizations` and `consumers`, which
stand for any tenant, when you add the account and before every sign-in, call
and renewal. A listing's next page is followed only on the same host at the same
path, taking only its `$skiptoken` or `$skip` and asking again with Pion's own
query, so a listing never leads anywhere else.

## Setting it up with least access

1. **Register the app.** In **App registrations**, choose **New registration**.
   Name it **Pion Defender Detection** and keep **Single tenant**. Under **Redirect
   URI**, choose **Public client/native (mobile & desktop)** and give
   `com.pdparchitect.pion:/oauth2callback`
   (`com.pdparchitect.pion.local:/oauth2callback` for Pion Dev). Add no client
   secret or certificate.
2. **Add its permissions.** Under **API permissions**, choose **Add a
   permission › Microsoft Graph › Delegated permissions** and add exactly
   Detection's permissions from the table above; a new app has `User.Read`
   already. Choose **Grant admin consent**.
3. **Let only its admin use it.** Under **Enterprise applications**, open the
   app. In **Properties**, set **Assignment required?** to **Yes**, and under
   **Users and groups** assign only the admin who will sign in.
4. **Choose its admin.** Keep an admin for Detection alone, such as
   `pion-defender-detection@contoso.com`, with only the **Security Reader** role.
   If your tenant uses Microsoft Defender XDR's unified role-based access, give
   them a custom role with only **Security data basics (read)** instead, over
   every device group they should see. Devices outside the groups their role
   covers are not listed, and their data is not hunted.
5. **Add the account** with the **Directory (tenant) ID** and the app's
   **Application (client) ID**, from its **Overview**. Choose **Add & Connect**
   and sign in as that admin.

Then ask an agent to run **check-access**.

## Licences

- **Alerts, incidents and advanced hunting need Microsoft Defender XDR**, such
  as Microsoft 365 E5, or a Defender plan. Without it, the tool says so, and the
  watch says once that its feeds are off.
- **Each Defender plan fills only its own hunting tables**: Defender for
  Endpoint the Device tables, Defender for Office 365 the Email ones, Defender
  for Identity the Identity ones, Defender for Cloud Apps CloudAppEvents.
  check-access says which have data in the last seven days. Hunting a table no
  plan fills finds nothing, which is not proof nothing happened.
- **Containment's actions need Defender for Endpoint Plan 2**, or Microsoft
  365 E5.

## Coverage you should know

- **Searches are bounded.** `alerts` and `incidents` search by when each was
  made, up to 180 days back, and say when more matched than they kept. Graph
  does not list them newest first, so what is kept is what Graph listed first:
  narrow the window when it says more matched.
- **Advanced hunting returns at most 100,000 rows** per query, and Pion keeps
  the first 100 in its result. A query whose rows reach that limit says more
  may match. A query's KQL error is shown in Microsoft's words.
- **`devices` and `device` read DeviceInfo for the last 30 days**, the latest
  record of each device. A device silent for longer, not onboarded, or outside
  the admin's device groups is not listed, and the result says so.
- **`alert` gives each device's Defender for Endpoint ID and each file's SHA1**,
  which Containment's actions take.
- **Throttling.** When Microsoft throttles a request, Pion waits as long as its
  `Retry-After` asks and tries again. If it still refuses, the answer says how
  long it asked to wait.

## What agents can do

- `alerts`: alerts by severity, status, source, incident and time, with the
  entities each involves.
- `alert`: one alert in full, with its description, recommended actions,
  classification and every entity in its evidence.
- `incidents`, `incident`: incidents by severity, status and time, and one
  incident with its alerts.
- `hunt`: a KQL query over the advanced hunting tables.
- `devices`, `device`: the devices Defender for Endpoint reported, by the start
  of their name, platform and onboarding; one device with its addresses and the
  alerts that named it.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads two feeds through Microsoft Graph:

- **alerts** of high severity, the highest Defender gives, that are not
  resolved: new, in progress, or of a status Graph does not give;
- **incidents** of high severity that are not resolved or redirected: active,
  in progress or awaiting action.

Each feed reads from six hours before the newest it has seen, as Defender lists
some alerts well after they were made, up to four pages each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing Microsoft wrote reaches the note: no ID, name,
device or text. Each alert and incident is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind takes its turn: alerts from each source, then incidents;
- the watch says once that more follow;
- the checks after read on from the oldest not yet handed over, until all of it
  is handed over, even across a check that could not read the feed.

A check that reaches its four pages keeps the paging value of Graph's next page
and the exact search it belongs to. The next check goes on from there, never
from a time, so even thousands of alerts made at the same moment are read
through once. When that search ends, the feed reads on from six hours before
its end, however far the watch has moved on meanwhile. If Graph turns down a
kept paging value, the watch says so once and reads that window again from its
start.

A check that fails for a passing reason, such as Graph throttling, keeps nothing
but how many checks in a row failed, so the next check reads the same window
again.

**What it does not watch:**

- alerts and incidents below high severity;
- alerts resolved, and incidents resolved or redirected, before a check read
  them;
- an alert or incident raised to high after it was made, once the watch has
  passed its creation time;
- what only the advanced hunting tables hold;
- Defender for Endpoint's machine actions, such as isolations, live response
  and offboarding, which only Containment's `machine-actions` reads.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused, or a sign-in Microsoft no longer accepts, wakes the agents
  once, and once more after Pion relaunches if it is still so. It wakes them
  again only after the feed has been read once since.
- A tenant without Defender is said once to be off, and again after a relaunch.
- A failure that passes, such as Graph throttling, holds the watch back for up
  to half an hour, reading the same window again, before it is told the same
  way.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- which tenant the sign-in reads, and whether it is the one the account names;
- alerts, incidents and advanced hunting;
- which Defender plans' hunting tables have data in the last seven days;
- who is signed in.

For anything that does not work, it says what to change. Any refused call says
the same: the tenant's licence, the app's permission or the admin's role, or a
sign-in that Microsoft no longer accepts, which needs connecting again.
Microsoft's refusal does not say whether the app's permission or the admin's
role is missing, so Pion names both. Detection does not read which permissions the
app is consented, as that takes a directory permission it does not ask for; it
refuses a sign-in that lacks any it asks for.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why. A result that matched more than it kept says so. When a later
  page fails, the pages already read are kept and the result says which page it
  stopped at and why.
- **An answer Pion cannot read is an error, never "nothing found".** A page
  without its list, an alert without its ID or a hunt without its results is
  an error.
- **Unknown is not none.** A severity or status Microsoft does not give is
  shown as unknown, and the watch treats an alert or incident of unknown status
  as open.
- **"No alerts" is not "none happened".** A search says nothing matched only in
  what it read, and the admin sees only the devices their roles cover.

## Containing an incident

**Microsoft Defender XDR Containment** is a separate tool, with its own app,
admin and sign-in, so the detection sign-in stays read-only.

1. **Register another app** as in steps 1 and 3 above, named **Pion Defender
   Containment**.
2. **Add its permissions.** Under **API permissions**, choose **Add a
   permission › APIs my organization uses**, search for **WindowsDefenderATP**,
   choose **Delegated permissions** and add exactly Containment's permissions
   from the table above. Remove Microsoft Graph's `User.Read`. Choose **Grant
   admin consent**.
3. **Choose another admin**, such as `pion-defender-containment@contoso.com`.
4. **Give that admin only the Defender permissions its actions take**, in the
   Microsoft Defender portal under **System › Permissions**, assigned only to
   the device groups agents may act on. Never make the admin a Global or
   Security Administrator.

   | Unified roles (Microsoft Defender XDR) | Defender for Endpoint roles | For |
   | --- | --- | --- |
   | Security data basics (read) | View data | reading devices and machine actions |
   | Response (manage) | Active remediation actions | isolating, releasing, restricting apps, lifting the restriction, stopping and quarantining a file, scanning |
   | Alerts (manage) | Alerts investigation | collecting an investigation package |

5. **Add the account** with the tenant and this app's **Client ID**, sign in as
   that admin, and ask an agent to run its **check-access**. It tries the reads
   the actions make first. It cannot try an action without taking it, so it
   says what each needs instead; a refused action says which permission or role
   it lacked.

What agents can do. Each action is held for your approval. Each one's
description and result say what recovering from it involves:

| Action | What it does | Recovery |
| --- | --- | --- |
| `device` (not held) | Reads whether the device is onboarded and active, its risk, exposure and device group, its pending machine actions, saying when not all could be read, and the last observed isolation and app-restriction actions, or that they could not be confirmed. | Nothing changes. |
| `machine-actions` (not held) | Lists machine actions taken on devices, by anyone, with who asked, why and where each stands. | Nothing changes. |
| `action-status` (not held) | Reads one machine action by its ID. | Nothing changes. |
| `isolate-device` | Cuts the device off the network, Full or Selective (which keeps Outlook, Teams and Skype for Business), keeping it connected to Defender. Can take minutes to apply. | `release-isolation` restores network access. Isolation never ends by itself: release must be asked for explicitly. |
| `release-isolation` | Restores the device's network access. Held, as it gives access back. | `isolate-device` again. An attacker still on the device regains access too. |
| `restrict-app-execution` | Lets only apps signed by Microsoft run. | `remove-app-restriction`. Meanwhile most of the user's work stops. |
| `remove-app-restriction` | Lets any app run again. Held, as it gives back what the restriction held off. | `restrict-app-execution` again. |
| `stop-and-quarantine-file` | Stops every process of a file, by its SHA1, on one device, and quarantines the file there. | The processes' in-memory state is lost and cannot be recovered; the file can be restored from quarantine, in the portal or with `MpCmdRun -Restore`. |
| `run-av-scan` | Runs a Microsoft Defender Antivirus scan, Quick or Full. | Nothing to undo: it changes nothing itself, but uses the device's processor and disk, and the antivirus remediates what it finds as its policy says, which may quarantine files. |
| `collect-investigation-package` | Gathers a forensic package from the device, to download in the portal. | Nothing to undo: it changes nothing on the device, but uses its resources, and anyone whose role covers the device can download the package. |
| **check-access** (not held) | See step 5. | Nothing changes. |

Every action takes the device by its 40-character Defender for Endpoint ID,
which Detection's `devices`, `device` and `alert` give, and a comment: Defender for
Endpoint requires one and records it with the action. Pion records it as
"Requested through Pion after the champion's approval:" and the reason given,
which should be the approval request's.

Pion reads the device just before acting and refuses, sending nothing:

- an ID that is not 40 hexadecimal characters;
- a device it cannot find, which may also be outside the admin's device groups,
  or one Defender answers for under another ID;
- a device not onboarded, or not active, as it would not carry the action out
  until it checks in and the action may time out;
- an action of the same kind already pending or in progress on that device, or
  its opposite, such as a release while an isolation is pending, as the two
  would race;
- any action while not every pending machine action of the device could be
  read, at all or to the end, such as more than Pion reads at once or a next
  page on another address, as one could conflict;
- isolating a device whose last observed isolation action isolated it,
  releasing one whose last observed action released it, and the same for the
  app restriction.

**Last observed is not verified.** Defender for Endpoint's device record does
not say whether a device is isolated or its apps restricted, so Pion reads the
device's succeeded machine actions, every one, and orders them itself, as the
API promises no order. The latest is what was last observed, and `device` says
so. When none is on record (Defender keeps only so much history), not every one
could be read, or two were asked for at the same moment, the state is unknown,
never "not isolated": the action goes ahead, and its result says the state
before could not be confirmed, which the approval reason should say too.

**A request taken is not a request done.** Defender for Endpoint takes each
request as a machine action, which the device carries out when it next checks
in. Pion gives the machine action's ID and reads it a few times over about ten
seconds, then says where it stands: **Pending** and **InProgress** are not
done, and the result says so and to poll with `action-status`. **Succeeded** is
done. **Failed**, **TimeOut** and **Cancelled** are errors. Nothing is said
done until Defender's answer names the same machine action, the device asked
for, the action's type, when it gives one the scope asked for, such as
Selective or Full, and for `stop-and-quarantine-file` the very SHA1 approved,
named as a SHA1. An answer that names no device or no file is read again until
the wait ends; one Pion cannot read, or one for another action, device, type,
scope or file, is never taken for success: the result keeps the machine
action's ID and says the outcome could not be verified.

Defender for Endpoint takes no condition on an action, so another admin can act
on the device between Pion reading it and acting. Each result says when Pion
read the device.
