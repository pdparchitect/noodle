# Google Workspace

Pion has two Google Workspace tools, each with its own sign-in:

- **Google Workspace Audit** reads your audit reports: sign-ins, admin actions,
  apps granted access, Drive activity and more, and who holds which admin role.
  It wakes the agents it is assigned to when an audit event means an attack. It
  cannot change anything.
- **Google Workspace Containment** shows an account's state and contains it:
  signing a user out everywhere, revoking an app's access, deleting an app
  password, and suspending or restoring a user. Agents can look at an account
  freely, but every action waits under **Approvals** for the champion, showing
  exactly what it will do and the agent's reason, and runs only once approved.
  The Investigation's Audit Log records each request and how it was decided.

They are separate so that the access to change accounts is given on purpose, to
the agents you choose. An agent with only the audit tool has no way to ask for
an action, and the audit sign-in never carries access that could change an
account.

The quick steps for each are under **Setup Steps** in **Settings → Tools**. This
guide explains them.

The pages they use:

- [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com),
  to enable in the Google Cloud project. Enable it first: Data Access takes a
  scope only once its API is enabled.
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

## Google Workspace Audit

Pion asks only for read-only access: to audit reports, and to users, admin
roles, groups, mobile devices and domains. With it agents can investigate an account:

- **Its activity**, and what admins did to it, in one timeline across every
  report it appears in: sign-ins, password, recovery and 2-step verification
  changes, app grants, Drive, Gmail, Calendar, Chat, Meet, Takeout and Vault
  exports, groups and admin actions. The timeline says which reports it
  searched, which it could not read and which held more than it read. A
  deleted account's history is read by its profile ID, which listing deleted
  accounts gives.
- **An address:** everything one IP address did, across every report and
  account.
- **Who it is:** admin roles, 2-step verification and whether it is enforced,
  recovery email and phone (flagged when they lead outside the domain), aliases.
- **What it reaches:** its groups and who else reads them, flagging outside
  members; the phones and tablets that sync its mail and files.
- **OAuth apps:** every app people granted access in the last six months, by
  client ID and scopes, with who granted and revoked it, and what each app
  pulled through its API calls and how much data. Apps an admin gave
  domain-wide delegation, which act as anyone without their consent, are
  listed too, since no one's own app list shows them; the Admin console's
  [Domain-wide delegation](https://admin.google.com/ac/owl/domainwidedelegation)
  page lists every app that holds it now.
- **Who clicked:** in a phishing case, who clicked a link in mail, in the
  message or in an attachment preview, found by the link's address or domain,
  or by the message's subject. A link copied into a browser is not counted.
- **What left:** files opened, shared, downloaded or made public, and exports
  through Takeout or Vault.
- **The domains:** every domain and alias the organisation has, which is
  primary and which are not verified. Whether others can send mail as them
  (SPF, DKIM, DMARC) is public, and Pion's DNS tool checks it with no setup.

It also wakes the agents for the signs of an account being taken over: 2-step
verification turned off, recovery details changed, mail forwarded outside the
domain, an email monitor or mail route added, backup codes generated by an admin,
or a mailbox dump requested; and for an app given domain-wide delegation, or
trusted, unblocked or exempted from the domain's app controls. A check that
cannot read one of these for the moment fails and is tried again from the same
point, so nothing is skipped.

The access apps hold *now*, rather than what the audit log recorded, can only be
read with the access that also signs people out, so it is in Google Workspace
Containment.

**Least access:** an admin account kept for Pion, with a custom role holding only
**Reports**, **Users › Read**, **Groups › Read**, and read access to admin roles,
mobile devices and domains. Its Google Cloud project needs the
[Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com)
enabled. A super admin works too, but gives a lost sign-in far more
reach than reading needs.

Google does not say which Admin console privileges let a role read admin roles,
mobile devices and domains. If agents are told something cannot be read, add the
privilege for it to the role and try again; audit reports keep working
meanwhile. Laptops, desktops and company-owned devices are not listed: Google
lets only a service account with domain-wide delegation read them, which Pion
does not use. A connection made before this
access was asked for needs to sign in again.

## Google Workspace Containment

Pion asks for Google's access to manage users, which suspending takes, and for
its access to manage users' security, which signing out, apps and app passwords
take.

**Least access:** an admin account kept for Pion, with a custom role holding
only:

- **Users › Read**, to see an account's state
- **Users › Update › Suspend users**, and nothing else under Update
- **Security › User Security Management**, for sessions, apps and app passwords

With this role a lost sign-in could suspend users and end their sessions, but
could not reset a password, change recovery details or make anyone an admin.

What each action does:

| Action | Effect | Undo |
| --- | --- | --- |
| Sign out | Ends every web and device session; the user must sign in again. | Nothing to undo. |
| Revoke an app's access | Removes every token the user granted that app. | The user grants it again. |
| Delete an app password | That password stops working. | The user makes a new one. |
| Suspend | The user cannot sign in or use any service. | Restore them. |
| Restore | Lifts a suspension. | Suspend again. |

Signing out alone does not lock an attacker out: a stolen password, an app the
attacker was granted, or an app password still works. To contain an account
that may be in someone else's hands, suspend it, or sign it out and also revoke
the apps and app passwords that should not be there.

## Caveats

- **Admins cannot be contained with the least-access role.** User Security
  Management only covers users who are not admins, so signing out or revoking
  apps for an admin is refused. Contain a compromised admin yourself, in the
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
running the check. Google Workspace Containment does not try suspending, as that
would change an account.

## Reading results

- **Results say when they are incomplete.** Every search reads page after page,
  and says when there was more than it read or when a report or account could
  not be read. What one report found is kept when another is refused.
- **Silence is not proof.** Google lists events minutes to hours after they
  happen and keeps most for 180 days. Gmail events can be read only for windows
  of 30 days at most.
- **What these tools cannot see:** current mail forwarding addresses, filters
  and delegates, laptops and desktops, and Google's own Alert Center. Google
  shows those only to a service account with domain-wide delegation, which
  Pion does not use. Connect Proofpoint or Microsoft Defender for mail, and
  CrowdStrike or Defender for endpoints.
- **Settings are seen only when they change.** The Admin console's current
  settings, such as password and session rules, sharing limits and which apps
  may be granted access, cannot be read; the admin events show every change to
  them. Google's API for current settings is documented only for a service
  account with domain-wide delegation. When a setting matters, agents ask you
  for that Admin console page.
- **Containment cannot act on admins.** User Security Management never covers
  admins, so their tokens, app passwords and sessions cannot be read or ended
  here; suspend an admin, or act in the Admin console.
- **Revoking tokens does not undo domain-wide delegation.** An app an admin
  gave it keeps acting as anyone until an admin removes it on the
  [Domain-wide delegation](https://admin.google.com/ac/owl/domainwidedelegation)
  page.

