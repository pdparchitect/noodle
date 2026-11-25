---
guides: [setup]
---

# Okta

Pion has two Okta tools, each added per org with a sign-in of its own:

- **Okta Detection** reads an org the way a defender does: who a user is, their
  groups, apps, sign-in factors and the apps they let act for them, who holds
  which admin role, every API token, the
  [System Log](https://developer.okta.com/docs/reference/api/system-log/), and,
  to audit how the org is set up, its sign-on, MFA and password policies. It
  wakes the agents it is assigned to when the System Log shows the org being
  handed over or its defences weakened. It only reads.
- **Okta Containment** acts on the same org to contain an account: it suspends
  or deactivates a user, ends their sessions and OAuth tokens, resets or
  removes their sign-in factors, expires their password, removes them from a
  group, and revokes an admin role, their apps' grants or an API token. Every
  one of these waits for your approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the Okta Admin Console:

- **Applications › Applications**, for each tool's app and its **Okta API
  Scopes**.
- **Security › Administrators**, for each tool's admin and their roles.
- **Reports › System Log**, to see what the tools read.

## How Okta limits what Pion can do

Both tools sign in as an Okta admin through OAuth, at the org's own
authorization server (`https://<your domain>/oauth2/v1/authorize` and
`/oauth2/v1/token`). Each signs in through a native app your org makes for that
tool alone, with an authorization code and PKCE, so Pion keeps no client secret.
Every sign-in asks for the admin's password again, so a browser already signed
in to Okta as someone else never answers for them.

Okta allows a request only when **both** of these allow it:

- **the app's scopes**, which you grant on its **Okta API Scopes** tab. Pion
  asks for exactly the scopes below, and refuses a sign-in that lacks any.
- **the signed-in admin's role.** Each tool gets an admin of its own.

| Tool | Scopes | Admin's role |
| --- | --- | --- |
| Okta Detection | `okta.users.read`, `okta.users.read.self`, `okta.groups.read`, `okta.apps.read`, `okta.logs.read`, `okta.roles.read`, `okta.apiTokens.read`, `okta.policies.read`, `okta.authenticators.read`, `okta.networkZones.read` | Read-Only Administrator, and a custom role that views admins and API tokens |
| Okta Containment | `okta.users.manage`, `okta.users.read.self`, `okta.groups.manage`, `okta.roles.manage`, `okta.apiTokens.manage` | a custom role with only the permissions its actions take |

Both also ask for `offline_access`, so the sign-in renews itself without asking
again. `okta.policies.read`, `okta.authenticators.read` and
`okta.networkZones.read` let Okta Detection read the org's policies, its
authenticators and the network zones policy rules name. A connection made
before Okta Detection asked for them stops until you grant them on the app's
**Okta API Scopes** tab and sign in again. Okta Detection's scopes only read, so it cannot change anything, whatever its
admin's role allows. Okta Containment's scopes are broad, as Okta has none
narrower, so its admin's custom role is what limits it: never make that admin a
super or organization administrator.

- **Sign Out** in **Settings → Tools** revokes the sign-in at Okta.
- When the sign-in expires or is revoked, or the admin is deactivated, the tool
  says to connect it again.

Both tools reach only the org's own domain, such as `acme.okta.com`: the
sign-in, its tokens and every call go there and nowhere else. Pion checks the
domain is a domain name alone, with no scheme, port or path. Okta pages its
listings with a link to the next page. Pion follows that link only when it is on
the same domain and at the same path, and takes only Okta's cursor from it, so
a listing never leads anywhere else.

## Setting it up with least access

1. **Create the app.** In **Applications › Applications**, choose **Create App
   Integration**, then **OIDC - OpenID Connect** and **Native Application**.
   Name it **Pion Detection**.
2. **Set its sign-in.** Keep the grant type **Authorization Code** and tick
   **Refresh Token**. Give `com.pdparchitect.pion:/oauth2callback` as the
   **Sign-in redirect URI** (`com.pdparchitect.pion.local:/oauth2callback` for
   Pion Dev). Under **Assignments**, allow only the admin who will sign in.
   Keep client authentication as PKCE, a native app's default.
3. **Grant its scopes.** On the app's **Okta API Scopes** tab, grant exactly
   Okta Detection's scopes from the table above. Only a super administrator can
   grant them.
4. **Choose its admin.** Keep an admin for Okta Detection alone, such as
   `pion-detection@example.com`, with the **Read-Only Administrator** role under
   **Security › Administrators**. It also views the org's policies,
   authenticators and network zones.
5. **To audit admins and API tokens too**, create a custom role under
   **Security › Administrators › Roles**, such as **Pion Detection**, with only
   **View roles, resources, and admin assignments** (`okta.iam.read`) and
   **View API tokens** (`okta.users.apitokens.read`). Assign it to the same
   admin for all users and all Identity and Access Management resources. The
   Read-Only Administrator cannot see admins or tokens.
6. **Add the account** with your org's domain, such as `acme.okta.com`, not its
   `-admin` address, and the app's **Client ID**. Choose **Add & Connect** and
   sign in as that admin.

Then ask an agent to run **check-access**.

## Coverage you should know

- **The System Log keeps 90 days.** Pion refuses a search reaching further
  back. Okta publishes a few events late, so the watch reads back an hour.
- **Searches are bounded.** Every System Log search names its end, so Okta's
  pages end. `sign-in-events` keeps the newest events up to its limit and says
  when more matched.
- **find-user matches the start of a first name, last name or email**, not a
  login, and says when more users match than it kept. Give a full login to
  the other tools.
- **user-apps lists every app assigned**, directly or through a group, including
  apps hidden from the user's dashboard.
- **admin-roles lists who Okta says holds an admin role.** It looks up the roles
  of the first 100 and says when there are more.
- **Rate limits.** When Okta rate limits a request, Pion tries again after a
  short pause. If Okta still refuses, the answer says when Okta's limit for that
  endpoint resets (from `X-Rate-Limit-Reset`). The System Log has a lower limit
  than most endpoints.
- **An event's actor is the account used**, not the person who held it.
- **Policies are read as they are now.** `sign-on-policies`, `mfa-policies`
  and `password-policies` say what the policies allow, not who signed in under
  them; `sign-in-events` shows that. They list inactive policies and rules but
  count only active ones among the gaps. They read the rules of the first 100
  policies of a kind and name up to 50 groups and users, showing the rest by
  ID. They do not say which apps an authentication policy covers: check that on
  the app's **Sign On** tab.
- **What counts as a gap.** A session that lasts longer than 12 hours, or never
  ends by time, an idle session longer than two hours, a session that survives
  closing the browser, a rule that lets one factor in when that factor may be a
  password, and re-authentication further apart than 12 hours; agents can give
  another length of time. SMS, voice call or a security question allowed, and
  an enrollment policy that requires nothing beyond a password and email. A
  password shorter than 12 characters, which agents can change, common
  passwords allowed, no lockout or one after more than 10 failed attempts,
  recovery by SMS, voice call or security question, and a reset with an email,
  SMS or voice code alone. A policy for people whose passwords Active Directory
  or LDAP keeps is not held to Okta's password rules, as the directory's apply.
- **Classic Engine orgs** have no authentication policies or authenticators;
  `sign-on-policies` and `mfa-policies` say so and read what there is.

## What agents can do

- `find-user`: users by the start of their name or email, with status, last
  sign-in and password change.
- `user-groups`, `user-apps`, `user-factors`, `user-grants`: a user's groups,
  apps, enrolled factors, and the OAuth grants they gave apps. A grant keeps
  working after a password change.
- `sign-in-events`: the System Log, newest first. It searches by the user who
  acted, the user or thing acted on, IP address, event type, failures and time.
- `admin-roles`: who holds which admin role, and whether through a group, with
  super administrators first.
- `api-tokens`: every API token, who made it, where it works from and when it
  expires.
- `sign-on-policies`: the global session and authentication policies, in the
  order Okta applies them, with every rule: whom it reaches, from which network
  zones, whether MFA or a phishing-resistant factor is required, and how long
  sessions last. Gaps come first.
- `mfa-policies`: the org's authenticators, which are active and what for, and
  the authenticator enrollment policies: which authenticators each requires,
  offers or refuses, and when people are asked to enroll.
- `password-policies`: the password policies: length and complexity, age and
  history, lockout, breached-password protection, recovery, and who may change,
  reset or unlock their password and how.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads the System Log, oldest first, for these
events:

- an admin role granted to a user or a group;
- an API token created;
- a user's sign-in factor changed, removed or reset by someone other than that
  user;
- a policy or policy rule turned off, deleted or changed. The log does not show
  whether a change weakened sign-on or MFA, so the agent reads the policy;
- an admin impersonating a user;
- an identity provider added or changed, or an app created;
- a network zone changed;
- a threat Okta ThreatInsight detected;
- suspicious activity a user reported;
- an org rate limit hit.

It reads from an hour before the newest event it has seen, up to five pages of
a thousand events each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing Okta wrote reaches the note: no event ID, login,
address or message. Each event is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind of event takes its turn;
- the watch says once that more follow;
- the checks after read on from the oldest event not yet handed over, until
  all of it is handed over, even across a check that could not read the log.

A check that reaches its five pages keeps Okta's cursor and the exact search it
belongs to. The next check goes on from that cursor, never from a time, so even
thousands of events published at the same moment are read through once. When
that search ends, the watch reads on from an hour before its end, however far
it has moved on meanwhile, so nothing published just after it is skipped. If
Okta rejects a kept cursor, the watch says so once and reads that window again
from its start.

A check that fails for a passing reason, such as a rate limit, keeps nothing but
how many checks in a row failed, so the next check reads the same window again.

**What it does not watch:**

- sign-ins themselves, including failed ones and bursts of failed MFA, which
  `sign-in-events` finds with `failuresOnly`;
- users created, deactivated or suspended;
- passwords reset by admins;
- group memberships and app assignments;
- users changing their own factors;
- admin roles granted through group rules.

ThreatInsight raises threats only when it is turned on, under **Security ›
General**.

**When it cannot read the System Log**, it says so rather than going quiet:

- A sign-in refused or rejected wakes the agents once, and once more after Pion
  relaunches if it is still so. It wakes them again only after the log has been
  read once since.
- A failure that passes, such as Okta rate limiting, holds the watch back for up
  to half an hour, reading the same window again, before it is told the same
  way.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- users, groups, apps, the System Log, admin assignments, API tokens,
  policies, authenticators and network zones;
- who is signed in and which admin roles they hold, saying when those roles
  could change the org;
- the scopes the sign-in holds, and the app they are granted to.

For anything that does not work, it says what to change. Any refused call says
the same: a scope the app lacks, which Okta names, the role or permission the
admin lacks, or a sign-in that Okta no longer accepts, which needs connecting
again.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why. A result that matched more than it kept says so. When Okta
  fails on a later page, the pages already read are kept and the result says
  which page it stopped at and why.
- **An answer Pion cannot read is an error, never "nothing found".**
- **"No events" is not "none happened".** A search says nothing matched only in
  what it read.

## Containing an incident

**Okta Containment** is a separate tool, with its own app, admin and sign-in, so
the detection sign-in stays read-only.

1. **Create another app** as in steps 1 to 3 above, named **Pion Containment**,
   and grant it Okta Containment's scopes from the table above.
2. **Choose another admin**, such as `pion-containment@example.com`.
3. **Create a custom role** under **Security › Administrators › Roles**, such as
   **Pion Containment**, with only these permissions, leaving out any you do not
   want:

   | Permission | For |
   | --- | --- |
   | `okta.users.read`, `okta.groups.read` | reading users and groups |
   | `okta.iam.read` | seeing who is a super administrator, and admin roles |
   | `okta.users.lifecycle.suspend`, `okta.users.lifecycle.unsuspend` | `suspend`, `unsuspend` |
   | `okta.users.lifecycle.deactivate` | `deactivate` |
   | `okta.users.lifecycle.clearSessions` | `clear-sessions` |
   | `okta.users.credentials.resetFactors` | `reset-factors`, `delete-factor` |
   | `okta.users.credentials.expirePassword` | `expire-password` |
   | `okta.users.groupMembership.manage` | `remove-from-group` |
   | `okta.users.apitokens.clear` | `revoke-api-token` |

4. **Assign it to the admin** with a resource set of all users and all groups.
   Never make them a super or organization administrator.
5. **Add the account** with the domain and this app's **Client ID**, sign in
   as that admin, and ask an agent to run its **check-access**. It reads the
   admin's role and says which actions it allows and what to add for the rest,
   warning when the role allows far more.

Revoking admin roles and users' app grants has no custom-role permission:

- Okta lets only a super administrator revoke admin roles.
- No custom-role permission covers users' app grants, so expect Okta to refuse
  them to this admin.

With the role above, Okta refuses both, and check-access says so. Hand those to
a super administrator, or give more access knowingly.

What agents can do. Each action is held for your approval. Each one's
description and result say how it is recovered:

| Action | What it does | Recovery |
| --- | --- | --- |
| `user` (not held) | Reads a user's status, admin roles with assignment IDs, groups, factors with IDs, and how many app grants they hold. | Nothing changes. |
| `suspend` | Stops an active user signing in. Groups and apps stay. | `unsuspend` restores sign-in. Sessions ended meanwhile are not restored. Suspending does not end sessions already open. |
| `unsuspend` | Restores a suspended user. Held, as it gives access back. | `suspend` again. Before restoring, reset factors and password, and revoke grants. |
| `deactivate` | Only with `confirmDeprovision`: ends sign-in and deprovisions the user from every app, which may delete their data there. | No simple undo. Reactivation needs a new activation, and app access is restored by hand. |
| `clear-sessions` | Ends the user's Okta sessions, revokes the OAuth and OpenID Connect tokens Okta issued them, and forgets remembered devices. | The user signs in afresh and OAuth apps need re-consent. Sessions that apps keep themselves are not ended. |
| `reset-factors` | Resets every sign-in factor, listing them. | The user re-enrolls every MFA factor. |
| `delete-factor` | Removes one factor, by ID. | The user enrolls it again. |
| `expire-password` | Expires the password, so it must be changed at the next sign-in. It never makes a temporary password, which would land in the conversation; if the user needs one, an admin issues it in the Okta Admin Console. | The user changes it at next sign-in. Expiry alone does not stop a stolen password: whoever signs in first chooses the new one, so suspend too. |
| `remove-from-group` | Removes the user from up to 20 groups. Checks every group first, and reports each removal. | Re-add by hand. A group rule may add them back. |
| `revoke-admin-role` | Revokes roles the user holds directly, by assignment ID. Roles held through a group are refused. | Re-assign by hand. |
| `revoke-app-grants` | Revokes all the OAuth grants the user gave apps, or one. | The user consents again. |
| `revoke-api-token` | Revokes one API token. | None: a new token must be made. |
| **check-access** (not held) | See step 5. | Nothing changes. |

Every action takes a user by their full Okta ID (`00u…`) or full login. Okta
also resolves short names, loosely, so Pion refuses them and checks that Okta
resolved exactly the user given. Pion refuses to act on:

- the admin signed in to it, as Okta names them from the sign-in;
- a super administrator, unless told the champion confirmed it with
  `allowSuperAdmin`.

Group, token, factor, grant and role-assignment IDs are checked for Okta's
format before anything is sent. Every action that makes several changes checks
all of them first. If one fails part way, it says which were made, which failed
and which were not tried.

**Okta takes no condition on a change.** It has no ETag or If-Match, so another
admin can change a user between Pion reading them and acting. Each result says
when Pion read the user. Pion reads what an action needs just before it acts,
and refuses what no longer fits: a user already suspended, a group they are not
in, a role held through a group. But Okta cannot refuse a change for Pion when
something changed in the second between.
