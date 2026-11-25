# Google Workspace

Pion has two Google Workspace tools, each with its own sign-in:

- **Google Workspace Detection** reads your audit reports: sign-ins, admin actions,
  apps granted access, Drive activity and more, and who holds which admin role.
  It wakes the agents it is assigned to when an audit event means an attack. It
  cannot change anything.
- **Google Workspace Containment** shows an account's state and contains it:
  signing a user out everywhere, resetting a stolen password, removing
  recovery details an attacker set, revoking an app's access, deleting an app
  password, blocking a phone from syncing, and suspending or restoring a
  user. Agents can look at an account
  freely, but every action waits under **Approvals** for the champion, showing
  exactly what it will do and the agent's reason, and runs only once approved.
  The Investigation's Audit Log records each request and how it was decided.

They are separate so that the access to change accounts is given on purpose, to
the agents you choose. An agent with only the detection tool has no way to ask for
an action, and the detection sign-in never carries access that could change an
account.

The quick steps for each are under **Setup Steps** in **Settings → Tools**. This
guide explains them.

The pages they use:

- [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com),
  to enable in the Google Cloud project, and for Google Workspace Detection the
  [Cloud Identity API](https://console.cloud.google.com/apis/library/cloudidentity.googleapis.com)
  too. Enable them first: Data Access takes a scope only once its API is
  enabled.
- [Google Auth Platform](https://console.cloud.google.com/auth/overview), its
  [Data Access](https://console.cloud.google.com/auth/scopes) scopes and its
  [Clients](https://console.cloud.google.com/auth/clients).
- The Admin console's [Admin roles](https://admin.google.com/ac/roles) for the
  roles, and [API controls](https://admin.google.com/ac/owl) to mark Pion's client
  Trusted.

## How Google limits what Pion can do

Two things decide what a Google sign-in can do, and Google checks both on every
request:

- **The access Pion asks for when you sign in.** This is the most Pion can ever
  do with that sign-in.
- **The admin role of the account that signs in.** Anything outside it is
  refused, whatever Pion asked for.

What Pion can do is only what both allow. Google's access for managing users is
broad: the access that lets Pion suspend a user would also let it reset
passwords, change recovery details or make someone an admin, and Google offers
nothing narrower. Pion only ever asks Google for the actions listed in this
guide, but the admin role is what really limits a sign-in, should anything go
wrong. So the setup steps have you sign in with an admin account kept for Pion,
whose role allows only what the tool needs, and never a super admin.

Anyone in your organisation can complete the sign-in, admin or not. Without the
right admin role every request is refused, and the agents are told what the
role is missing.

## Google Workspace Detection

Pion asks only for read-only access: to audit reports, and to users, admin
roles, groups, mobile devices and domains; and through Cloud Identity, to the
organisation's current settings. With it agents can investigate an account
and audit how the organisation is set up:

- **Its activity**, and what admins did to it, in one timeline across every
  report it appears in: sign-ins, password, recovery and 2-step verification
  changes, app grants, Drive, Gmail, Calendar, Chat, Meet, Keep, Chrome, the
  data protection rules it set off, Looker Studio, Google Cloud, Gemini,
  Takeout and Vault exports, groups and admin actions. The timeline says which reports it
  searched, which it could not read and which held more than it read. A
  deleted account's history is read by its profile ID, which listing deleted
  accounts gives.
- **An address:** everything one IP address did, across every report and
  account, Gmail included for the window's last 30 days.
- **Who it is:** admin roles, 2-step verification and whether it is enforced,
  recovery email and phone (flagged when they lead outside the domain), aliases.
- **What it reaches:** its groups and who else reads them, flagging outside
  members; the phones and tablets that sync its mail and files.
- **Every phone and tablet in the domain:** who owns each, its model, OS and
  status, when it first and last synced, and whether Google finds it
  compromised, with counts of those approved but not synced for 90 days or
  more, blocked, pending and compromised. Approved ones come first, longest
  unsynced first: a
  phone sold, lost or replaced stops syncing but stays approved until an admin
  removes it. Agents can ask for one person's, one status, or only those not
  synced for a number of days. Google does not say whether a device is
  personal or company-owned; its type says how it syncs, and for Android
  whether the account is in a work profile.
- **The organisation's current settings:** whether 2-step verification is
  enforced and with which methods, less secure apps, how long web sessions
  last, the password policy, account recovery, who Drive files can be shared
  with outside the organisation and how new files are shared by default,
  automatic mail forwarding, Chat and Meet with people outside, and which apps
  may reach the organisation's data, each for the organisational unit or group
  it applies to, said plainly; every other setting Google gives is listed as
  it gives it. Google lists only settings with a value set, so agents say
  which of these it did not list. Google lets only a super admin read them,
  so with the least-access role below they are refused and agents ask you for
  those Admin console pages instead.
- **OAuth apps:** every app people granted access in the last six months, by
  client ID and scopes, with who granted and revoked it, and what each app
  pulled through its API calls and how much data. Apps an admin gave
  domain-wide delegation, which act as anyone without their consent, are
  listed too, since no one's own app list shows them; the Admin console's
  [Domain-wide delegation](https://admin.google.com/ac/owl/domainwidedelegation)
  page lists every app that holds it now. Everything one app's client ID did
  across Drive, Gmail, Calendar, admin actions and its tokens is listed by the
  account it acted as, and whether it impersonated them. Google cannot ask
  most of these reports for one app, so they are read whole and the result
  says when one held more than was read.
- **Who clicked:** in a phishing case, who clicked a link in mail, in the
  message or in an attachment preview, found by the link's address or domain,
  or by the message's subject. A link copied into a browser is not counted.
- **Where a message went:** for up to 30 days, by its Message-ID, sender,
  recipient or subject: who received it, opened it, replied, forwarded it,
  downloaded its attachments, had it reclassified as spam or deleted it, and
  who likely still holds it. Google does not document which details of a
  Gmail event hold the sender, recipient and subject, so Pion looks for them
  itself; if a message cannot be found one way, try another. A Message-ID
  matches only the message's own ID, whole, and which mailboxes still hold a
  message is said only when each event carries that ID.
- **What left:** files opened, shared, downloaded or made public, and exports
  through Takeout or Vault. For one person or everyone, Drive's downloads,
  copies and prints are counted by person and file; files shared with people
  outside the organisation are grouped by their domain; files made public or
  open to anyone with the link, and files handed to a new owner, are listed,
  each with the file's ID and title so it can be fixed. When the
  organisation's domains cannot be read, every share and new owner is listed,
  said not known to be inside or outside.
- **The domains:** every domain and alias the organisation has, which is
  primary and which are not verified. Whether others can send mail as them
  (SPF, DKIM, DMARC) is public, and Pion's DNS tool checks it with no setup.

It also wakes the agents for the signs of an account being taken over: a
suspicious sign-in, whether Google blocked it or it succeeded; 2-step
verification turned off, recovery details changed, mail forwarded outside the
domain, an email monitor or mail route added, backup codes generated by an admin,
or a mailbox dump requested; and for an app given domain-wide delegation, or
trusted, unblocked or exempted from the domain's app controls; and for an admin
role given to someone, or a privilege added to a role, which widens it for
everyone who holds it. It wakes them too for:

- **An admin taking over someone's account:** a recovery phone set, a security
  key added or taken away, Advanced Protection or security-key-only sign-in
  turned off, a session Google blocked let through, or a password reset and
  its temporary password viewed. Some organisations reset passwords every day,
  so these resets take their turn after sign-ins and takeovers, and agents
  check who reset it and why.
- **A suspicious session let through a sensitive action**, and a passkey
  removed.
- **Domain mail rules:** a Gmail routing, compliance or other mail setting
  added or changed, which can send or copy mail out without any user's
  settings showing it.
- **Defences loosened:** 2-step verification's enforcement or allowed methods
  (not when narrowed to security keys only), less secure apps, API access,
  apps trusted by scope, in bulk or because the domain owns them,
  context-aware access, session length and reauthentication, password
  recovery for users or super admins, a new domain or domain alias, and an
  admin role made or changed.
- **What left:** a Takeout started or scheduled, a Vault export made, a Vault
  retention rule or the default retention changed or deleted, and an admin
  moving an account's data to someone else.
- **An app granted access that reads, sends or forwards mail, reads files,
  runs Apps Script or administers the domain**, as consent phishing asks for. Apps with
  less access, such as a calendar app or signing in with Google, do not wake
  anyone; `oauth-apps` lists them all.
- **A harmful app found on a phone.**
- **A file made public on the web or open to anyone with the link** by a
  user. A file shared with one person outside the organisation does not wake
  anyone, as it is common and telling it apart takes more reading; agents find
  those with Drive's exposure search.

A check that cannot read one of these for the moment
fails and is tried again from the same point, and each check reads six hours
back, as Google lists a few events late, so nothing is skipped.

The access apps hold *now*, rather than what the audit log recorded, can only be
read with the access that also signs people out, so it is in Google Workspace
Containment.

**Least access:** an admin account kept for Pion, with a custom role holding only
**Reports**, **Users › Read**, **Groups › Read**, and read access to admin roles,
mobile devices and domains. Its Google Cloud project needs the
[Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com)
and the [Cloud Identity API](https://console.cloud.google.com/apis/library/cloudidentity.googleapis.com)
enabled. A super admin works too, and is the only admin Google lets read the
organisation's current settings, but gives a lost sign-in far more reach than
reading needs.

Google does not say which Admin console privileges let a role read admin roles,
mobile devices and domains. If agents are told something cannot be read, add the
privilege for it to the role and try again; audit reports keep working
meanwhile. Laptops, desktops and company-owned devices are not listed: the
access Google's device list takes is not among those Google lists for a
sign-in like Pion's. The mobile audit report's events still cover laptops and desktops
enrolled through endpoint verification, as device types `DESKTOP_CHROME`,
`MAC`, `WINDOWS` and `LINUX`. A connection made before this
access was asked for needs to sign in again.

## Google Workspace Containment

Pion asks for Google's access to manage users, which suspending, resetting a
password and removing recovery details take; for its access to manage users'
security, which signing out, apps and app passwords take; and for its access to
act on mobile devices.

**Least access:** an admin account kept for Pion, with a custom role holding
only:

- **Users › Read**, to see an account's state
- **Users › Update › Suspend users**, **Reset password** and **Force password
  change**, and nothing else under Update
- **Security › User Security Management**, for sessions, apps and app passwords
- **Services › Mobile Device Management**, to list a user's phones and tablets
  and block one

To let agents remove a recovery email or phone too, add **Users › Update**
itself. Google names no narrower privilege for recovery details, and Update
lets the role change any non-admin's profile, so leave it out if you would
rather remove recovery details yourself; the other actions work without it.

With this role a lost sign-in could suspend users, end their sessions, reset
their passwords and block their phones, but could not make anyone an admin or
act on an admin. Only a super admin can reset another admin's password.

The access to act on mobile devices is the narrowest Google offers that both
lists them and acts on them. A connection made before this access was
asked for needs to sign in again, and its Google Cloud project needs the scope
`https://www.googleapis.com/auth/admin.directory.device.mobile.action` added
under Data Access.

What each action does:

| Action | Effect | Undo |
| --- | --- | --- |
| Sign out | Ends every web and device session; the user must sign in again. | Nothing to undo. |
| Reset password | Replaces the password with a random one nobody knows, Pion included, to be changed at the next sign-in. Sessions already open keep working, so agents sign the user out too. | An admin sets the user a new password in the Admin console, or the user recovers the account. |
| Remove recovery details | Clears the recovery email, phone or both; the result says what they were. | The user adds their own again in their Google Account. |
| Revoke an app's access | Removes every token the user granted that app. | The user grants it again. |
| Delete an app password | That password stops working. | The user makes a new one. |
| End backup codes | The user's backup codes for 2-step verification stop working. | The user makes new ones. |
| Block a phone | The phone or tablet stops syncing the account; what it holds stays. | Unblock it on the Admin console's [Devices](https://admin.google.com/ac/devices) page. |
| Suspend | The user cannot sign in or use any service. | Restore them. |
| Restore | Lifts a suspension. | Suspend again. |

Signing out alone does not lock an attacker out: a stolen password, an app the
attacker was granted, or an app password still works. To contain an account
that may be in someone else's hands, suspend it, or sign it out and also reset
its password, remove recovery details the attacker set, revoke the apps and app
passwords that should not be there, end the backup codes, and block a phone the
attacker added.

Pion never wipes the account from a phone. Google's account wipe leaves
personal data only on a personal device: it resets company-owned and work-only
Android phones and supervised iPhones to factory settings, personal data and
all ([Google's guide](https://knowledge.workspace.google.com/admin/devices/wipe-corporate-data-from-a-device)),
and Google's Directory cannot say how a phone is owned or managed. Agents block
the phone and recommend that you wipe the account in the Admin console's
[Devices](https://admin.google.com/ac/devices) page once you have confirmed how
it is owned and managed there.

Agents list the account's apps and app passwords before suspending it, as the
record of what it had granted. Restoring an account is not simply undoing: reset
its password and check its recovery details, 2-step verification and apps first.

## Caveats

- **Admins cannot be contained with the least-access role.** User Security
  Management only covers users who are not admins, and only a super admin can
  reset another admin's password, so signing out, revoking apps or resetting
  the password of an admin is refused. Contain a compromised admin yourself, in the
  Admin console.
- **User Security Management can also turn off 2-step verification** for users
  who are not admins. Pion never asks for that, but a lost sign-in with this
  role could. Keep the Pion admin account's own sign-in protected.
- **The consent screen looks alarming.** Google describes the containment access
  as seeing, adding, editing and deleting users. That is the broad access
  described above; the admin role is what narrows it.
- **Your organisation may block the sign-in.** If it limits which apps may reach
  Google's APIs, mark Pion's client as **Trusted** in the Admin console's
  [API controls](https://admin.google.com/ac/owl).
- **One client serves both tools.** Add the scopes of both to the same Google
  Cloud client and paste its Client ID into each tool. Each tool still signs in
  on its own, and can use a different admin account.

## When something does not work

Both tools can check their own setup. Ask an agent to run **check-access**: it
tries each thing the tool reads once, including the Gmail and Takeout reports,
which a working sign-in report does not prove, and lists what works and, for
what does not, exactly what to change: a scope missing from the sign-in (add it under
Data Access and sign the tool in again), an API turned off in the Google Cloud
project (with the link to turn it on), or a privilege missing from the admin's
role. Any refused call says the same, so an agent can tell you the fix without
running the check. Google Workspace Containment tries reading users, one
non-admin's sessions and the mobile devices; it does not try suspending,
resetting a password, removing recovery details or acting on a phone, as those
change an account, and says instead what each needs.

## Reading results

- **Results say when they are incomplete.** Every search reads page after page,
  and says when there was more than it read or when a report or account could
  not be read. What one report found is kept when another is refused. When the
  alert watch cannot read a report, it wakes the agents once to say so, and
  once more after Pion restarts if it still cannot.
- **The alert watch keeps at most 500 events a check.** When there are more,
  each watched event takes its turn, so a burst of one, such as a rule firing
  hundreds of times, cannot push out a suspicious sign-in. One watched event
  with more than its share in a check can still lose its oldest events there;
  the wake then says there may be more, and `security-events` reads them.
  Where the watch keeps only some of an event's records, such as apps granted
  access to mail but not a calendar app, it reads on further back in the
  window; if there are still more than it can read, it wakes the agents once
  to say so rather than staying silent.
- **Silence is not proof.** Google lists events minutes to hours after they
  happen and keeps most for 180 days. Gmail events can be read only for windows
  of 30 days at most, so a longer timeline reads Gmail for its last 30 days.
- **What these tools cannot see:** current mail forwarding addresses, filters
  and delegates, a list of laptops and desktops, and Google's own Alert Center.
  Google shows mail settings and the Alert Center only to a service account
  with domain-wide delegation, which Pion does not use. The mobile report's
  events do include laptops and desktops enrolled through endpoint
  verification. Connect Proofpoint or Microsoft Defender for mail, and
  CrowdStrike or Defender for endpoints.
- **Without a super admin, settings are seen only when they change.** Google
  lets only a super admin read the organisation's current settings, such as
  password and session rules, sharing limits and which apps may be granted
  access. With the least-access role the admin events show every change to
  them, and when a setting matters, agents ask you for that Admin console
  page.
- **Containment cannot act on admins.** User Security Management never covers
  admins, and only a super admin can act on a super admin, so agents hand a
  compromised admin to a super admin with exactly what to do in the Admin
  console.
- **Revoking tokens does not undo domain-wide delegation.** An app an admin
  gave it keeps acting as anyone until an admin removes it on the
  [Domain-wide delegation](https://admin.google.com/ac/owl/domainwidedelegation)
  page.

