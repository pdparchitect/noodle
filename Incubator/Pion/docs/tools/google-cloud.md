# Google Cloud Audit

**Google Cloud Audit** reads a Google Cloud organisation, folder or project the
way a defender does: who did what in the
[Cloud Audit Logs](https://docs.cloud.google.com/logging/docs/audit), what
[Security Command Center](https://docs.cloud.google.com/security-command-center/docs/security-command-center-overview)
found, and from [Cloud Asset Inventory](https://docs.cloud.google.com/asset-inventory/docs/overview)
who has access to what, which keys exist, what is public and what changed. It
wakes the agents it is assigned to when the audit logs or Security Command
Center show the way into Google Cloud being opened, or what follows being
hidden. It only reads: it cannot change a resource, a policy or a finding, and
agents recommend what to change to you.

It signs in with OAuth as a person, through a client your organisation makes for
Pion, and acts with that person's own access. It never signs in as a service
account.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use:

- The [Cloud Logging API](https://console.cloud.google.com/apis/library/logging.googleapis.com),
  [Security Command Center API](https://console.cloud.google.com/apis/library/securitycenter.googleapis.com)
  and [Cloud Asset API](https://console.cloud.google.com/apis/library/cloudasset.googleapis.com),
  to enable in a Google Cloud project of your organisation. Enable them first:
  Data Access offers an API's scopes only once it is enabled.
- [Google Auth Platform](https://console.cloud.google.com/auth/overview), its
  [Data Access](https://console.cloud.google.com/auth/scopes) scopes and its
  [Clients](https://console.cloud.google.com/auth/clients).
- [IAM](https://console.cloud.google.com/iam-admin/iam) for the roles, and the
  Admin console's [Admin roles](https://admin.google.com/ac/roles) for Groups
  Reader.
- [Audit Logs](https://console.cloud.google.com/iam-admin/audit), to turn on
  Data Access logging, and
  [Security Command Center](https://console.cloud.google.com/security/command-center).

## How Google limits what Pion can do

Two things decide what a Google sign-in can do, and Google checks both on every
request:

- **The access Pion asks for when you sign in.** This is the most Pion can ever
  do with that sign-in.
- **The IAM roles of the account that signs in.** Anything outside them is
  refused, whatever Pion asked for.

Pion asks for three scopes, the narrowest each service offers, and never for
all of Google Cloud:

- `logging.read`, to read the audit logs. It only reads.
- `cloudasset`, Cloud Asset Inventory's own, to list resources, keys, policies
  and their history, and to analyse who has access. Pion only reads with it,
  though Google describes it as seeing, editing and deleting your Cloud Asset
  data.
- `securitycenter`, Security Command Center's own, to read findings. Security
  Command Center has no read-only scope, so this one could also mute or change
  findings if the account's role allows it.

What Pion can do is only what both allow. Pion only ever reads, but the roles
are what really limit a sign-in, should anything go wrong. So sign in with an
account kept for Pion that holds only viewer roles, and never with one that can
change findings, such as an Owner, Security Center Admin, Findings Editor or
Findings Mute Setter. A lost sign-in of such an account could hide findings an
attacker set off. **check-access** says when the account signed in could.

The consent screen describes the Cloud Asset and Security Command Center scopes
as seeing, editing and deleting data. That is how Google describes the scopes;
the viewer roles are what keep the sign-in to reading.

## Setting it up with least access

1. **Enable the three APIs** in a project of your organisation. Pion's requests
   count against this project's quotas, whichever organisation, folder or
   project it reads.
2. **Set up Google Auth Platform** with the audience **Internal**, so only
   your organisation's accounts can sign in, and add the three scopes under
   Data Access. The same client can serve both Google Workspace tools; see
   [Google Workspace](google-workspace.md).
3. **Make an iOS client** with the bundle ID `com.pdparchitect.pion`, and paste
   its Client ID into the tool.
4. **Give the account kept for Pion its roles**, in IAM on the organisation,
   folder or project to investigate:

   | Role | What it is for |
   | --- | --- |
   | **Logs Viewer** | Admin Activity, System Event and Policy Denied audit logs. |
   | **Private Logs Viewer** | Data Access audit logs, which Logs Viewer leaves out ([Google's guide](https://docs.cloud.google.com/logging/docs/access-control)). |
   | **Security Center Findings Viewer** | Security Command Center's findings and sources. |
   | **Cloud Asset Viewer** | Who has access, resources, service account keys, organisation policies, audit configuration and their history. |
   | **Role Viewer** | Access granted through custom roles, which the analysis otherwise cannot expand. |
   | **Groups Reader** (Admin console) | Access granted through Google groups ([Google's guide](https://docs.cloud.google.com/policy-intelligence/docs/analyze-iam-policies)). |
   | **Logs View Accessor** | Only if your organisation routes audit logs to a log bucket of its own: on that bucket's project, or on the view alone with an IAM condition. |

   Groups Reader is an admin role in the Admin console, not an IAM role. Without
   it, access through groups is not analysed, and the answer says so.
5. **Turn on Data Access audit logs**, at least Data Read, for the services
   that hold sensitive data, such as Cloud Storage and Secret Manager. See
   [Coverage](#coverage-you-should-know).
6. **Set Scope and its ID** to where the account has its roles: the
   organisation's or a folder's number, or a project's ID. An organisation or
   folder covers every folder and project under it, and the roles granted there
   are inherited by them. Set it to a folder or project to keep Pion to part of
   the organisation.

Then choose **Add & Connect**, sign in, and ask an agent to run
**check-access**.

## Coverage you should know

What Google records, and for how long, decides what any tool can find.

- **Admin Activity audit logs are always on.** Google writes them for every
  change to a resource's configuration or IAM policy, cannot be turned off and
  does not charge for them. The alert watch reads them.
- **Data Access audit logs are off by default** for every service but BigQuery
  ([Google's guide](https://docs.cloud.google.com/logging/docs/audit/configure-data-access)).
  Until you turn them on for a service, nobody's reads of its data are
  recorded: no objects downloaded, secrets read or tokens minted for a service
  account. Turn them on in [Audit Logs](https://console.cloud.google.com/iam-admin/audit)
  on the organisation, so every project inherits them. They can be costly for
  busy services, so start with the ones that hold sensitive data.
  `logging-coverage` says where they are on.
- **Logs are kept 400 days in `_Required`**, which holds Admin Activity and
  System Event logs, **and 30 days by default in `_Default`**, which holds Data
  Access logs ([Google's quotas and limits](https://docs.cloud.google.com/logging/quotas)).
  A project's `_Default` retention can be raised; an organisation can also
  route copies to a log bucket of its own and keep them longer.
- **Log views of a central bucket are searched only when named.** If your
  organisation routes audit logs to a central logging project, give the
  account Logs View Accessor and ask agents to search the view by its name,
  such as `projects/PROJECT/locations/LOCATION/buckets/BUCKET/views/VIEW`. A
  view is searched only when its project is the account's own or under its
  organisation or folder: set the account to the organisation that holds the
  logging project. One search takes up to 10 views, and an entry both a project
  and a view return is shown once.
- **Cloud Asset's IAM data can lag.** Google says IAM data, such as service
  account keys, can be up to 7 days stale
  ([Google's asset types](https://docs.cloud.google.com/asset-inventory/docs/asset-types)),
  so agents check recent changes in the audit logs too. Cloud Asset keeps 35
  days of history, the most `asset-history` can compare with.
- **Findings come only from what Security Command Center's tier detects.** The
  Standard tier finds misconfigurations and vulnerabilities; threat findings,
  such as an anomalous grant or a leaked key being used, come from Event Threat
  Detection, which only Premium and Enterprise include. Standard and Enterprise
  are activated for a whole organisation, Premium for an organisation or a
  project ([Google's tiers](https://docs.cloud.google.com/security-command-center/docs/service-tiers)).
  **check-access** names the services that report findings, and says when
  Event Threat Detection is not among them.
- **An organisation gets 20 IAM analyses a day** without Security Command
  Center Premium or Enterprise activated for the whole organisation, shared by
  every Policy Analyzer tool
  ([Google's quotas](https://docs.cloud.google.com/asset-inventory/docs/quota)).
  `iam-policies`, `who-can-impersonate` and **check-access** each use one, so
  agents ask them narrowly.
- **Logging answers 60 searches a minute** for the project Pion's requests
  count against, and Google does not raise it. One audit log search sends at
  most 20 requests, each covering up to 100 folders and projects, so it
  reaches up to 2,000; past that it says what it did not search. The alert
  watch sends at most 10 a check, leaving the rest for investigations, and in
  a large organisation reads its projects in turn across checks, the scope's
  own logs every time.

## What agents can do

**Search and timelines**

- `audit-logs`: audit log entries across the scope, its folders and projects,
  and any log views named, newest first, by who acted, including what they did
  while impersonating a service account, by method, resource, caller IP,
  outcome (failed, denied or succeeded), service, log and time. Each entry
  shows the service account key and delegation behind it, what an IAM change
  granted or revoked, and the request's key fields, such as a firewall's
  ranges. Leave the window out and it reads the last 30 days.
- `security-events`: what the alert watch wakes for, for a window; the last 24
  hours when none is given. It reads first what the watch found, and where,
  while Pion runs, so in a large organisation it finds what woke the agents;
  `project` or `resourceNames` narrow its audit log search to those alone, each
  of which must be inside the account's scope, while Security Command Center
  findings are still read for the whole scope and listed apart, saying so.

**Access and impersonation**

- `iam-policies`: every role a user, group or service account holds, including
  through groups, or who has access to one resource, with each binding's
  condition. Allow policies only; deny policies are not evaluated.
- `who-can-impersonate`: who can act as a service account, minting its
  tokens, signing as it, attaching it to what they run or making it a key, or
  which service accounts a member can act as, optionally through chains of
  other accounts.

**Resources, keys and history**

- `find-resources`: resources of given types, by name, creation time and
  location, such as VMs made lately in an unusual region.
- `sa-keys`: service account keys, newest first, flagging user-managed keys,
  which work from anywhere until deleted, uploaded keys and keys made lately.
- `public-resources`: what anyone on the internet (`allUsers`) or any Google
  account (`allAuthenticatedUsers`) can reach, by resource type and role.
- `asset-history`: how the IAM policies or settings of one resource type
  differ now from up to 35 days ago, role by role.
- `org-policies`: organisation policies across the scope, flagging security
  constraints loosened, such as service account key creation or public
  buckets allowed, or members of any domain allowed.
- `logging-coverage`: for a service, whether each project logs data reads,
  data writes and admin reads, each on, off or unknown, and whom it exempts.

**Security Command Center**

- `scc-findings`: active findings, critical and high unless asked otherwise,
  by category and time, with who acted and from where for a threat, and a
  console link. Muted findings only when asked.
- `scc-finding`: one finding in full, with its MITRE ATT&CK tactics and
  techniques, who acted with which key, and its source's own details.
- `scc-summary`: how many findings there are by category, severity, project or
  resource type, to see where to look.

**Setup**

- **check-access**: tries each thing the tool reads once and says what works
  and what to change. See [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads two feeds with the sign-in the tool already
has, six hours back each time, as Google lists some entries and findings late:
Security Command Center's active, unmuted, critical and high findings, and the
Admin Activity audit logs of the scope and every folder and project under it.
It needs no Security Command Center Premium. It wakes the agents with a note
naming `security-events`, which reads the same for the note's window.

When a check finds more than it keeps, 500, each kind takes its turn, the first
group first, so a burst of service accounts made or misconfiguration findings
cannot push out a threat or a key made.

**First:**

- Security Command Center threat findings and toxic combinations.
- A service account key made or uploaded.
- Owner, Editor, Service Account Token Creator, Service Account Key Admin,
  Organization Administrator or Security Admin granted.
- Anything granted to `allUsers` or `allAuthenticatedUsers`, other than on
  data.
- Data Access logging turned off for a service, or someone exempted from it.
- A log sink deleted or changed, a log exclusion made or changed, or a log
  bucket deleted.
- A workload identity pool or provider made or changed, which lets identities
  outside Google act in the organisation.

**Then:**

- Other critical findings.
- A bucket or dataset made public.
- A service account made in the window and then granted a role.
- A log bucket's retention changed.
- A security organisation policy loosened or handed back to its default, such
  as key creation, public access prevention, OS Login or the allowed member
  domains.
- A firewall rule letting in `0.0.0.0/0` or `::/0`.
- Project-wide SSH keys or OS Login changed, or a VM's.
- A project deleted.

**Then:**

- Other high findings.
- A VM made with GPUs, or twenty made by one account in the window, not
  counting VMs Google's own service agents make for managed instance groups
  and GKE.
- A service account made.
- An encryption key version destroyed or disabled.

**What it does not watch:** Data Access logs, so never tokens minted for a
service account, secrets read or data read or copied; agents search those with
`audit-logs`. Nor a key used once it is made, custom roles, a VM's startup
scripts, new log sinks, deny policies, medium and low findings, or muted
findings.

**When it cannot read a feed**, it says so rather than going quiet: Security
Command Center not activated, refused or its API turned off, a sign-in that
expired, or audit logs it could not read or read to the end each wake the
agents once, saying what to change, and once more after Pion relaunches if it
still cannot. A list of folders and projects that came back only in part
counts too: the watch says once that it could not see them all, keeps saying so
in `security-events`, and stops only when a later list is whole. A failure that passes, such as Google being briefly unavailable,
holds the watch back for up to half an hour, reading the same window again, so
nothing is skipped. Agents treat that feed's silence as unknown until it is
read again.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- the Admin Activity audit logs;
- the Data Access audit logs, which only an entry coming back proves readable:
  when none comes back, it says whether they can be read is not established,
  as logging may be off or the account may lack Private Logs Viewer;
- Cloud Asset's listing, and one IAM analysis, which counts as one of the
  day's 20;
- Security Command Center's findings, and which services report them, saying
  when Event Threat Detection is not among them;
- whether the account could mute or change findings, asking up to 20 of the
  organisation's sources. It warns when it can. A role given on one project
  alone does not show there.

For what does not work, it says exactly what to change, and any refused call
says the same, so an agent can tell you without running the check:

- **A scope missing from the sign-in:** add it under
  [Data Access](https://console.cloud.google.com/auth/scopes) and sign the tool
  in again in **Settings → Tools**.
- **An API turned off** in the tool's project, with the link to turn it on.
- **A role the account lacks**, named, to grant in IAM on the scope, or the
  account's Scope and ID to check.
- **Security Command Center not activated** where the account looks: activate
  it, or set the Scope to where it is.
- **A sign-in that expired or was revoked:** sign the tool in again.
- **An IAM analysis Google ran out of time on:** narrow it by role or
  resource, or set the account to a folder or project.

## Reading results

- **Results say what they covered.** An audit log search ends with lines such
  as **Searched:** the folders and projects it read and the window; **Not
  searched**, with why, such as more projects than one search reaches;
  **Could not read**, with Google's reason; **Read only in part**; and **More
  entries match than** it kept, with the time to search again up to.
  Projects pending deletion are said apart. Findings, resources, keys and
  policies say the same when there was more than was read.
- **"No entries" is not "none happened".** A search says no entries match only
  for what it searched in full; otherwise it says what it could not search.
  For Data Access logs, finding no reads means unknown, not none, unless
  `logging-coverage` or you confirm logging is on for that service.
- **A principal is the credential used, not the person.** An audit entry's
  principal, service account key and delegation chain name what made the
  request. A stolen token or key acts as its owner, so agents say what the log
  shows and what it does not prove.
- **Access answers are allow policies only.** Deny policies are not evaluated,
  and access through groups or custom roles is analysed only with Groups
  Reader and Role Viewer; the answer says when either is missing.
- **Muted findings are left out** unless agents ask for them.

## Containing an incident

This tool only reads. Agents recommend what to change, with the evidence, and
you or someone with the access makes the change in Google Cloud. Google's
[guide to compromised credentials](https://docs.cloud.google.com/security/compromised-credentials)
covers the steps, among them:

- **A service account key:** disable it, then delete it.
- **A service account's tokens:** they cannot be revoked. Disable the account
  and wait at least an hour for tokens already minted to expire, and remove
  Service Account Token Creator from anyone who should not hold it.
- **Access granted:** remove the binding, and check `asset-history` and
  `audit-logs` for what else the same principal changed.
- **A person's stolen gcloud sign-in:** Google says to remove Google Cloud CLI,
  and Google Auth Library for application default credentials, from the
  person's connected apps. An agent with
  [Google Workspace Containment](google-workspace.md#google-workspace-containment)
  can list the apps a user granted and revoke one by its client ID, once you
  approve it; otherwise do it in the Admin console. Signing the person out
  alone does not end an app's access.
