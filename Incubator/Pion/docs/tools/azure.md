# Microsoft Azure

Pion has two Azure tools, each added per subscription with an app registration of
its own:

- **Microsoft Azure Audit** reads a subscription the way a defender does: who
  did what in the [activity log](https://learn.microsoft.com/azure/azure-monitor/essentials/activity-log),
  what [Microsoft Defender for Cloud](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction)
  alerted on, what resources exist through
  [Azure Resource Graph](https://learn.microsoft.com/azure/governance/resource-graph/overview),
  and who holds which role. It wakes the agents it is assigned to when Defender
  for Cloud raises a high-severity alert or the activity log shows the way in
  being opened, or what follows being hidden. It only reads.
- **Microsoft Azure Containment** acts on the same subscription to contain an
  incident: it removes a role assignment, deallocates or isolates a VM, rotates
  a storage key, closes a storage account to public and shared key access,
  locks a resource, snapshots a disk, and reopens, resolves or dismisses a
  Defender for Cloud alert. What cuts off access, stops something or closes an
  alert waits for your approval.

Both sign in as an app with a client secret, never as a person. The quick steps
are under **Setup Steps** in **Settings → Tools**. This guide explains them.

The pages they use:

- [App registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
  in the Microsoft Entra admin center, for each tool's app and its secret.
- The subscription's **Access control (IAM)** in the
  [Azure portal](https://portal.azure.com), for the roles.
- Defender for Cloud's **Environment settings**, to see and turn on its plans.

## How Azure limits what Pion can do

Each tool signs in as its own app, and Azure checks the app's roles on every
request. Pion asks only for Azure Resource Manager's token, which on its own
allows nothing: the roles you give the app are all it can do.

- **Microsoft Azure Audit's app** needs only reading roles, so it cannot change
  anything, whatever Pion asks for. Keep it that way: **check-access** warns
  when the app holds anything that writes or deletes.
- **Microsoft Azure Containment's app** gets a custom role with only the
  actions its operations take. Leave out any you do not want agents to have,
  and never give it Owner or Contributor.

Both reach only `login.microsoftonline.com`, to sign in, and
`management.azure.com`. Every resource they read or act on must be inside the
subscription the account names; Pion refuses an ID from any other before
sending anything. When Azure answers a listing with a link to its next page,
Pion takes only the page's token from it and asks its own host again, so a
listing never leads anywhere else.

## Setting it up with least access

1. **Register an app** for Microsoft Azure Audit, such as Pion Audit, single
   tenant, with no redirect URI. It needs no API permissions. Add a client
   secret and copy its **Value**: it is shown only once. Pion keeps it in the
   keychain and never shows it to agents.
2. **Give it Reader and Security Reader** on the subscription, in **Access
   control (IAM) › Add role assignment**. Reader covers the activity log,
   resources and role assignments; Security Reader covers Defender for Cloud's
   alerts and plans. Neither can change anything.
3. **Optionally, let it read the directory activity log.** When a Global
   Administrator elevates their access to manage every subscription, Azure
   records it only in the directory's own activity log, not the
   subscription's. Reading it needs Monitoring Reader at the root scope (`/`),
   which only a Global Administrator who has
   [elevated access](https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin)
   can give. Without it, the watch says it cannot see access being elevated.
4. **Copy the Subscription ID**, and the app's **Directory (tenant) ID** and
   **Application (client) ID**. Add one account per subscription.

Then choose **Add & Connect** and ask an agent to run **check-access**.

## Coverage you should know

- **The activity log records changes, not reads.** It holds every write,
  delete and action on the subscription's resources for 90 days
  ([Microsoft's guide](https://learn.microsoft.com/azure/azure-monitor/essentials/activity-log)),
  but not blobs downloaded, secrets read or a VM's own logs. Those need
  diagnostic settings sending resource logs to a Log Analytics workspace, which
  Microsoft Sentinel can read.
- **Defender for Cloud raises threat alerts only for the plans turned on.**
  Without a paid plan, such as Defender for Servers, Storage or Key Vault, its
  alerts stay silent whatever happens. Defender CSPM finds misconfigurations,
  not threats. **check-access** lists which plans are on, and the watch wakes
  the agents once when none that raises alerts is.
- **Azure lists every alert at once.** Its alert listing takes no filter, so
  Pion reads up to 20 pages and filters them itself, saying when more pages
  remained.
- **The activity log filters only a few ways.** Azure takes a time range with
  one of a resource group, a resource, a resource provider or a correlation ID,
  and optionally a caller and an outcome. Pion refuses other combinations
  rather than send a request Azure would reject, and matches an operation's
  name itself, saying how many events it read to do so.
- **Requests and responses are not shown.** The log keeps some changes'
  request bodies, which can hold scripts or settings. Pion reads them only to
  judge what the watch wakes for, such as whether a network rule opens to the
  internet, and never passes them on.
- **Role assignments show the group, not its members.** Who is in a group
  given access is in Microsoft Entra ID. Classic subscription administrators
  and Microsoft Entra roles are not listed. Roles eligible through
  [Privileged Identity Management](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure)
  are listed apart, as not active until someone activates them; without PIM,
  Pion says it could not read them.

## What agents can do

- `activity-log`: the activity log, newest first, by time, caller, resource
  group, resource, resource provider, correlation ID, operation and outcome.
  Each event shows the caller's IP address, a few of their sign-in's claims
  (app ID, IP address, name, user principal name, object ID), the permission
  used, its status and sub-status, category, level and correlation ID, which
  ties together every event of one request.
- `security-events`: what the alert watch wakes for, for a window; the last
  24 hours when none is given. It says what it searched, what it could not read
  and why, and what it does not watch.
- `defender-alerts`: Defender for Cloud alerts by severity, status and time,
  with their entities, MITRE ATT&CK techniques and portal link.
- `resource-graph`: a KQL query over the subscription's resources, reading on
  until it has the rows a result keeps, and saying when Azure matched more.
- `role-assignments`: who holds which role where, including roles eligible
  through PIM, by principal or at the subscription's scope, naming each role
  used.
- `deny-assignments`: what is denied to whom, and who is exempt.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads, six hours back from the newest it has seen,
as Defender for Cloud may list an alert hours after its time:

- **Open high-severity Defender for Cloud alerts.** An alert is dated when it
  reached Defender for Cloud, so one listed late is not missed; resolved and
  dismissed ones are left out.
- **The activity log's successful operations** of Microsoft.Authorization,
  Microsoft.Insights, Microsoft.KeyVault, Microsoft.Storage, Microsoft.Network
  and Microsoft.Compute, in up to 12 requests a check, for:
  - Owner, Contributor, User Access Administrator or Role Based Access Control
    Administrator granted on the subscription, and Owner, User Access
    Administrator or Role Based Access Control Administrator anywhere in it;
  - a role granted on the subscription whose role the log does not show;
  - access to a Key Vault granted, its access policies or settings changed;
  - a diagnostic setting or activity log profile deleted;
  - a command run on a VM;
  - a resource lock or policy assignment deleted, or a policy exemption made;
  - a network security rule letting in the internet, or a rule changed whose
    content the log does not show;
  - a storage account allowing anonymous public blob access or shared key
    access, or a blob container made public.
- **The directory activity log**, for a Global Administrator elevating access,
  when the app may read it.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when: nothing Azure wrote, such as an alert's description or ID,
reaches it. An alert and an event are each told once. When one check finds more
than it can hand over, 500, each kind takes its turn, the watch says once that
more follow, and the checks after read again from the oldest left over until
all of it is handed over, even across a check that could not read that feed
whole. A check that fails keeps nothing of what it read, so
the next one reads the same window again.

**What it does not watch:** reads of data, sign-ins and Microsoft Entra changes,
medium and low alerts, failed operations, and storage accounts or Key Vaults
changed when the log does not show the change.

**When it cannot read a feed**, it says so rather than going quiet: alerts or
activity refused, a sign-in failing, more than one check reads, or no Defender
plan that raises alerts turned on each wake the agents once, and once more
after Pion relaunches if still so. A failure that passes, such as Azure being
briefly unavailable, holds the watch back for up to half an hour, reading the
same window again. The directory activity log needs a role few apps have, so
not reading it is said in `security-events` rather than woken for.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- the activity log, Defender for Cloud's alerts, Resource Graph, role
  assignments and deny assignments;
- which Defender for Cloud plans are on, warning when none raises alerts;
- the directory activity log;
- whether the app can change anything, warning when it holds a write, delete
  or wildcard action.

For what does not work it says what to change, and any refused call says the
same: the role to give the app on the subscription, a client secret or tenant
ID to check, a subscription ID Azure does not know, or a resource provider the
subscription is not registered for.

## Reading results

- **Results say what they covered.** A listing that stopped before the end
  says so, with why; a result that matched more than it kept says how many.
- **"No events" is not "none happened".** A search says nothing matched only
  in what it read. For Defender for Cloud, no alerts means unknown unless a
  plan that raises them is on.
- **A caller is the credential used, not the person.** An event's caller,
  app ID and IP address name what made the request; a stolen secret or token
  acts as its owner.

## Containing an incident

**Microsoft Azure Containment** is a separate tool, with its own app, so the
audit app stays read-only.

1. **Register another app**, such as Pion Containment, and add a client secret.
2. **Make a custom role** in the subscription's **Access control (IAM) › Add ›
   Add custom role**, with only these actions, leaving out any you do not want:

   ```json
   {
     "Name": "Pion Containment",
     "Actions": [
       "Microsoft.Authorization/*/read",
       "Microsoft.Authorization/roleAssignments/delete",
       "Microsoft.Authorization/locks/write",
       "Microsoft.Compute/virtualMachines/read",
       "Microsoft.Compute/virtualMachines/deallocate/action",
       "Microsoft.Compute/disks/read",
       "Microsoft.Compute/snapshots/read",
       "Microsoft.Compute/snapshots/write",
       "Microsoft.Compute/locations/*/read",
       "Microsoft.Network/networkInterfaces/read",
       "Microsoft.Network/networkSecurityGroups/read",
       "Microsoft.Network/networkSecurityGroups/securityRules/read",
       "Microsoft.Network/networkSecurityGroups/securityRules/write",
       "Microsoft.Network/networkSecurityGroups/securityRules/delete",
       "Microsoft.Network/locations/*/read",
       "Microsoft.Storage/storageAccounts/read",
       "Microsoft.Storage/storageAccounts/write",
       "Microsoft.Storage/storageAccounts/regeneratekey/action",
       "Microsoft.Security/locations/alerts/*"
     ],
     "AssignableScopes": ["/subscriptions/SUBSCRIPTION-ID"]
   }
   ```

3. **Assign it to the app** on the subscription. Never Owner or Contributor.
4. Add the account with the same subscription, and ask an agent to run its
   **check-access**, which reads the app's permissions and says which actions
   its role allows and what to add for the rest, warning when it allows far more.

What agents can do, each by the resource's full ID:

| Action | Held for your approval | What it does |
| --- | --- | --- |
| `remove-role-assignment` | Yes | Removes one assignment, saying what it granted to whom. Access through a group or inherited from a management group stays. |
| `deallocate-vm` | Yes | Stops a VM and releases its compute; what is only in its memory is lost, its disks stay. |
| `isolate-vm` | Yes | Adds deny-all inbound and outbound rules at priority 100 to the network security group of each of the VM's network interfaces. The rules are named after the VM, `pion-isolate-` and a digest of its ID, and their description names the isolation and the VM; the result lists the isolation's ID and every rule added. It changes nothing when a group also serves other interfaces or subnets, unless told to, when another rule already holds priority 100 in either direction, when a rule of the same name exists, or when an interface has no ID or no group. Each rule is only made, never replacing one of that name that appeared meanwhile (sent as `If-None-Match: *`; that Azure enforces it is not yet confirmed against a live subscription). If a later rule cannot be added, it says which were. Connections already open may continue until they close. |
| `unisolate-vm` | Yes | Removes the rules `isolate-vm` added for that VM, from the groups it reported when given them, otherwise from the groups of the VM's interfaces now. It checks each is Pion's for that VM by its description before removing any, and removes each only as it was read, so a rule changed meanwhile stays and the result says so (sent as `If-Match` with the rule's etag; that Azure enforces it is not yet confirmed against a live subscription). It refuses a shared group unless told to. |
| `rotate-storage-key` | Yes | Replaces one access key, ending what uses it and the SAS tokens it signed. The new key is never shown. |
| `restrict-storage` | Yes | Turns off anonymous public blob access, shared key access, or both. |
| `add-lock` | No | Adds a CanNotDelete lock, `pion-containment`, to a resource, resource group or the subscription. A lock of that name Pion did not add, or a stricter ReadOnly one, is left as it is. Azure's locks take no write condition, so a lock of that name someone sets at the same moment would be replaced. |
| `snapshot-disk` | No | Copies a managed disk to a full snapshot in its resource group, as evidence. |
| `set-alert-status` | No | Marks a Defender for Cloud alert active or in progress. |
| `close-alert` | Yes | Resolves or dismisses a Defender for Cloud alert, which takes it out of the alert watch. |
| `operation-status` | No | Reads how a long operation is going, by the status path an action returned. It reads only Azure's own places for an operation's progress, and says unknown when Azure's answer does not say. |

An action Azure runs in the background returns a status path on
`management.azure.com`, never a link elsewhere, for `operation-status` to read.
Neither tool follows a redirect, so its sign-in never goes to another host.
Even an allowed action can still be refused by a lock, a deny assignment or
Azure Policy.
