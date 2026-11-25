---
guides: [setup]
---

# Google Cloud Detection

**Google Cloud Detection** reads a Google Cloud organisation, folder or project the
way a defender does: who did what in the
[Cloud Audit Logs](https://docs.cloud.google.com/logging/docs/audit), what
[Security Command Center](https://docs.cloud.google.com/security-command-center/docs/security-command-center-overview)
found, and from [Cloud Asset Inventory](https://docs.cloud.google.com/asset-inventory/docs/overview)
who has access to what, which keys exist, what is public and what changed. It
wakes the agents it is assigned to when the audit logs or Security Command
Center show the way into Google Cloud being opened, or what follows being
hidden. It only reads: it cannot change a resource, a policy or a finding, and
agents recommend what to change to you. To let agents act, add
**Google Cloud Containment**, a separate tool with a sign-in of its own; see
[Containing an incident](#containing-an-incident).

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

**Google Cloud Containment** acts on the same organisation, folder or project
to contain an incident: it disables a service account or one of its keys,
removes one member from an IAM role, enforces public access prevention on a
bucket, and snapshots, stops or isolates a VM. It is a separate tool with a
sign-in of its own, so Google Cloud Detection's sign-in never holds more than its
read scopes. Like Detection, it signs in with OAuth as a person, never as a service
account.

### How Google limits what it can do

It asks for `cloud-platform`, which is all of Google Cloud: IAM's key and
account actions and Resource Manager's policy changes take no narrower one.
Only this tool asks for it, at its own sign-in. It also asks for
`userinfo.email`, to ask Google which account signed in. So the role of
the account that signs in is the only real limit: sign in with an account kept
for containment that holds the Pion Containment custom role below and nothing
else, never an Owner, Editor or Security Admin.

You name the account that signs in in **Account that signs in**, and
`remove-iam-member` refuses to remove it, or its whole domain, unless an agent
is told to. Before it changes a policy, it asks Google which account the
sign-in belongs to, and refuses when that is not the account named, or when
Google does not say, so an address left over from an earlier sign-in never
protects the wrong account. **check-access** says which account signed in.
Access the account holds through a group is not checked, so do not remove a
group it belongs to.

### Setting it up with least access

1. **Enable four more APIs** in the project that holds your Google Cloud Detection
   client: the
   [IAM API](https://console.cloud.google.com/apis/library/iam.googleapis.com),
   [Cloud Resource Manager API](https://console.cloud.google.com/apis/library/cloudresourcemanager.googleapis.com),
   [Compute Engine API](https://console.cloud.google.com/apis/library/compute.googleapis.com)
   and [Cloud Storage API](https://console.cloud.google.com/apis/library/storage-api.googleapis.com).
2. **Add the scopes** `https://www.googleapis.com/auth/cloud-platform` and
   `https://www.googleapis.com/auth/userinfo.email` under
   [Data Access](https://console.cloud.google.com/auth/scopes). The same iOS
   client serves both tools.
3. **Make a custom role**, Pion Containment, with only these permissions. Save
   them as `pion-containment.yaml`:

   ```yaml
   title: Pion Containment
   description: Only what Pion's containment actions take.
   stage: GA
   includedPermissions:
   - resourcemanager.projects.get
   - resourcemanager.folders.get
   - resourcemanager.projects.getIamPolicy
   - resourcemanager.projects.setIamPolicy
   - resourcemanager.folders.getIamPolicy
   - resourcemanager.folders.setIamPolicy
   - resourcemanager.organizations.getIamPolicy
   - resourcemanager.organizations.setIamPolicy
   - iam.serviceAccounts.get
   - iam.serviceAccounts.disable
   - iam.serviceAccounts.enable
   - iam.serviceAccountKeys.get
   - iam.serviceAccountKeys.disable
   - iam.serviceAccountKeys.enable
   - storage.buckets.get
   - storage.buckets.update
   - compute.instances.get
   - compute.instances.stop
   - compute.instances.setTags
   - compute.disks.createSnapshot
   - compute.snapshots.create
   - compute.snapshots.setLabels
   - compute.firewalls.get
   - compute.firewalls.create
   - compute.firewalls.delete
   - compute.networks.updatePolicy
   - compute.zoneOperations.get
   - compute.regionOperations.get
   - compute.globalOperations.get
   ```

   Then make it on the organisation with
   `gcloud iam roles create pionContainment --organization=ORGANIZATION-ID --file=pion-containment.yaml`,
   or for a project's account on the project with `--project=PROJECT-ID`,
   leaving out the folder and organisation permissions, which a project's role
   cannot hold. Leave out any whose action you do not want agents to have:

   | Permissions | Needed for |
   | --- | --- |
   | `resourcemanager.projects.get`, `resourcemanager.folders.get` | Every action: checking that what it acts on lies inside the scope. |
   | `iam.serviceAccountKeys.*` and `iam.serviceAccounts.get` | `disable-sa-key`, `enable-sa-key`. |
   | `iam.serviceAccounts.*` | `disable-service-account`, `enable-service-account`. |
   | `resourcemanager.*.getIamPolicy`, `resourcemanager.*.setIamPolicy` | `remove-iam-member`. **setIamPolicy lets whoever holds it change any binding, granting as well as removing.** Pion only removes, but leave these out if agents should not remove access. |
   | `storage.buckets.get`, `storage.buckets.update` | `enforce-public-access-prevention`, `revert-public-access-prevention`. |
   | `compute.instances.get`, `compute.disks.createSnapshot`, `compute.snapshots.*` | `snapshot-disks`, and `stop-instance` with `snapshotFirst`. |
   | `compute.instances.stop` | `stop-instance`. |
   | `compute.instances.setTags`, `compute.firewalls.*`, `compute.networks.updatePolicy` | `isolate-instance`, `unisolate-instance`. Google requires `compute.networks.updatePolicy` to add or delete a firewall rule. |
   | `compute.*Operations.get` | `operation-status`. |

4. **Grant the role** to the account kept for containment, on the
   organisation, folder or project to act on. If a VM's network is a Shared
   VPC, the isolation's firewall rules go in the network's host project, which
   must be inside the scope and where the role is granted too.
5. **Set Scope and its ID** as for Google Cloud Detection, and **Account that signs
   in** to that account's email. Choose **Add & Connect**, sign in as that
   account, and ask an agent to run **check-access**, giving it a project to
   check the Compute Engine and Cloud Storage APIs there.

**check-access** changes nothing. It asks Google which of the role's
permissions the account holds on the scope, and on a project when given one,
and says for each action exactly what to add. It warns when the account can do
far more than containment, such as delete projects, make keys or read
objects, and reminds you what `setIamPolicy` allows. It says whether the IAM,
Compute Engine and Cloud Storage APIs are enabled. What it reports is what
Google says the account holds, not a trial: an action can still be refused by
a deny policy, an organisation policy or VPC Service Controls.

### What agents can do

Each takes the resource's full name, such as
`projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/KEY-ID`,
`projects/kestrel-prod/zones/europe-west1-b/instances/web-1` or a bucket's
name, as Google Cloud Detection lists them.

| Action | Held for your approval | What it does, and how to undo it |
| --- | --- | --- |
| `disable-sa-key` | Yes | Turns off one user-managed key, saying when it was made; whatever authenticates with it fails. Tokens already minted with it are not revoked and last until they expire, usually within an hour. Google-managed keys cannot be turned off. Undo: `enable-sa-key`. |
| `enable-sa-key` | Yes | Turns a disabled key back on, so whoever holds it, an attacker included if it leaked, can authenticate again. Undo: `disable-sa-key`. |
| `disable-service-account` | Yes | Stops the account authenticating at all: every key of it, and every VM, function or job running as it, loses its access, which can break those workloads. Its keys, roles and resources are kept. Undo: `enable-service-account`. |
| `enable-service-account` | Yes | Lets a disabled account authenticate again, with its enabled keys. Undo: `disable-service-account`. |
| `remove-iam-member` | Yes | Reads the IAM policy of a project, folder or organisation and removes one member from one role binding, sending back every other member, binding and condition exactly as read; a binding left empty is dropped, and audit configuration is not touched. When the member holds the role in several bindings, the agent must name one by its condition, or `none` for the one without. It refuses the account that signs in, its domain, and the last owner of a project, or the last owner or Organization Administrator of an organisation, unless told to. Access the member holds through a group, another role or a folder or organisation above stays. Undo: grant the member the role again with the `gcloud` command the result gives, and the same condition, which the result keeps; Pion does not grant access. |
| `enforce-public-access-prevention` | Yes | Enforces a bucket's public access prevention, only over the bucket as read, and returns the setting before and the bucket's metageneration after Pion's change. Grants to `allUsers` and `allAuthenticatedUsers` stay in its policy and ACLs but stop working, which breaks a site served from it. A bucket that already enforced it is left alone, with nothing to undo. Undo: `revert-public-access-prevention` with that setting and metageneration. |
| `revert-public-access-prevention` | Yes | Sets the setting back to `inherited`, conditional on the bucket, prior setting and metageneration given, which must be copied from `enforce-public-access-prevention`'s result. Google makes the change only while the bucket is still at that metageneration, so a change made since, such as someone enforcing prevention on purpose, is not undone; then it reverts nothing and says so. That guards against later changes, not against values that did not come from Pion's change: nothing on the bucket records who enforced it, so check the values match the enforcement's result before you approve. It refuses a prior setting of `enforced` or one not recorded. Those grants then work again unless an organisation policy enforces prevention. Undo: `enforce-public-access-prevention`. |
| `snapshot-disks` | No | Snapshots each persistent disk of a VM, as evidence, each labelled `pion-evidence` with the VM's ID and named `pion-` with a digest and the time. Local SSDs cannot be snapshotted. The snapshots stay until you delete them. |
| `stop-instance` | Yes | Stops a VM, snapshotting its disks first when asked, and never stops it if a snapshot cannot be started. What is only in its memory is lost and an ephemeral external IP is released; its disks stay. A VM with a local SSD is refused, as stopping may discard its data. A VM in a managed instance group may be started again by its group. Undo: start it again; it boots afresh. |
| `isolate-instance` | Yes | Adds deny-all inbound and outbound VPC firewall rules at priority 0, the highest, for IPv4 and, where the VM has it, IPv6, on each of its networks, logged, then adds a network tag to the VM. It waits for Compute Engine to confirm each rule done before adding the tag, and the tag after, and says isolated only then; while any change is still running after about twenty seconds it says pending, with the operations to read, and a change Google fails later is said with what was added before it. The tag is `pion-isolate-` and a digest of the VM's unique ID, so no other VM carries it, and the rules target only it; each rule is named after the tag and its network, and its description names the VM. It changes nothing when a rule of that name exists that Pion did not make for this VM on that network, or one of Pion's that someone turned off. Undo: `unisolate-instance`. |
| `unisolate-instance` | Yes | Removes Pion's tag from the VM, which ends the isolation, then deletes Pion's rules for it, from the rules `isolate-instance` reported when given them, otherwise those of the VM's networks now. It checks each rule is exactly one Pion made for this VM, by its name, description, network, tag, priority, range and deny-all, before changing anything; one of Pion's someone turned off is still removed. Undo: `isolate-instance`. |
| `operation-status` | No | Reads how a Compute Engine operation is going, pending, running, done, or done with errors, by the path an action returned. |

### How each change is kept safe

- **Inside the scope, of the right kind.** Every name is checked for its form
  before anything is sent, and every project, folder, bucket and network is
  placed inside the scope through Resource Manager, parent by parent, before
  anything changes; a service account is acted on only when Google places it
  in the project its name gives. Anything that cannot be placed is refused.
- **Conditional where Google allows it.** An IAM policy is written with the
  etag it was read with, so if anyone changed it meanwhile Google refuses and
  the result says the policy changed since it was read and nothing was
  changed. A bucket is changed only at the metageneration read, or for an undo the
  metageneration given, and a VM's
  tags only at the fingerprint read; a rule is made only if no rule has its
  name. Compute Engine takes no condition on deleting a firewall rule, so
  `unisolate-instance` reads each rule just before deleting it and deletes it
  only while it is still exactly Pion's; a change in that moment would not
  stop the deletion.
- **Partial changes said.** When a later step fails, the result lists exactly
  what was done before it and how to undo it, such as rules added when the
  VM's tag could not be. A change Google gave no clear answer to is said as
  possibly done, to read again, never as not done.
- **Only Google's own hosts.** It reaches only `iam.googleapis.com`,
  `cloudresourcemanager.googleapis.com`, `compute.googleapis.com`,
  `storage.googleapis.com` and, to ask which account signed in,
  `openidconnect.googleapis.com`. `operation-status` reads only Compute Engine's own
  places for operations, on its own host, whatever link it is given, and says
  unknown when Google's answer does not say. Text Google gives that anyone may
  have written, such as an error or a policy's condition, is marked
  `[from Google: "…"]`.

### Limits you should know

- **Isolation is VPC firewall rules.** Connections already open may continue
  until they close. The VM can still reach its metadata server, which no
  firewall rule blocks. An allow rule in a
  [hierarchical firewall policy](https://docs.cloud.google.com/firewall/docs/firewall-policies-overview)
  on the organisation or a folder, or in a network firewall policy evaluated
  before VPC rules, still lets traffic through, so check those. It cuts off
  the VM's own calls to Google APIs too. A VM with more network tags than
  Google allows is refused.
- **Tokens outlive their key.** Disabling a key or an account does not revoke
  access tokens already minted. Google's guidance is to disable the account
  and wait for them to expire, at least an hour.
- **Long operations.** Compute Engine works in the background: each action
  returns its operations, which agents read with `operation-status` until each
  is done.
- **Not covered:** IAM deny policies, which are left out on purpose: making one
  needs Deny Admin granted on the organisation, and one mistaken rule can deny
  everyone, the people who would remove it included, which no approval makes
  safe enough. Also not covered: granting access, deleting keys, accounts or
  resources, organisation policies, VPC Service Controls, capturing a VM's
  memory and GKE workloads.

### A person's stolen gcloud sign-in

Google says to remove Google Cloud CLI, and Google Auth Library for
application default credentials, from the person's connected apps. An agent
with [Google Workspace Containment](google-workspace.md#google-workspace-containment)
can list the apps a user granted and revoke one by its client ID, once you
approve it; otherwise do it in the Admin console. Signing the person out alone
does not end an app's access. Google's
[guide to compromised credentials](https://docs.cloud.google.com/security/compromised-credentials)
covers the rest, among them disabling a service account key and then deleting
it in the console, and checking `asset-history` and `audit-logs` for what else
a principal changed.
