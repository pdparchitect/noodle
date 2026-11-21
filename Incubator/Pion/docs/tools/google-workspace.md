# Google Workspace

Pion has two Google Workspace tools, each with its own sign-in:

- **Google Workspace Audit** reads your audit reports: sign-ins, admin actions,
  apps granted access, Drive activity and more. It wakes the agents it is
  assigned to when an audit event means an attack. It cannot change anything.
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

Pion asks only for read-only access to audit reports.

**Least access:** an admin account kept for Pion, with a custom role holding only
the **Reports** privilege. A super admin works too, but gives a lost sign-in far
more reach than reading reports needs.

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
  Google's APIs, mark Pion's client as **Trusted** under **Security › Access and
  data control › API controls** in the Admin console.
- **One client serves both tools.** Add the scopes of both to the same Google
  Cloud client and paste its Client ID into each tool. Each tool still signs in
  on its own, and can use a different admin account.
