# Okta

Pion has two Okta tools, each added per org with an API token of its own:

- **Okta Audit** reads an org the way a defender does: who a user is, their
  groups, apps, sign-in factors and the apps they let act for them, who holds
  which admin role, every API token, and the
  [System Log](https://developer.okta.com/docs/reference/api/system-log/). It
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

- **Security › Administrators**, for each tool's admin and their roles.
- **Security › API › Tokens**, for each token.
- **Reports › System Log**, to see what the tools read.

## How Okta limits what Pion can do

Both tools sign in with an Okta API token, sent as `SSWS`. A token has exactly
the access of the admin who made it, so each tool gets an admin of its own, made
for it alone, and that admin's roles are all the tool can do.

- **Okta Audit's admin** has the Read-Only Administrator role and a custom role
  that only views admins and API tokens, so it cannot change anything, whatever
  Pion asks for. **check-access** warns when that admin holds anything that
  changes the org.
- **Okta Containment's admin** has a custom role with only the permissions its
  actions take. Leave out any you do not want agents to have, and never make it
  a super or organization administrator.

Okta also offers OAuth for its API, but only through each org's own
authorization server at the org's domain. Pion's sign-in reaches fixed
addresses for each tool, so it cannot use Okta OAuth yet. When it can, these
tools will move to an OAuth admin sign-in. Meanwhile:

- Okta revokes a token left unused for 30 days.
- **Sign Out** in **Settings → Tools** revokes the token at Okta.
- Where Okta offers it, limit each token to your network zone, so that a copy
  works nowhere else. **check-access** says whether a token is limited.

Both tools reach only the org's own domain, such as `acme.okta.com`. Okta pages
its listings with a link to the next page. Pion follows that link only when it
is on the same domain and at the same path, and takes only Okta's cursor from
it, so a listing never leads anywhere else.

## Setting it up with least access

1. **Create a user for Okta Audit alone**, such as `pion-audit@example.com`, so
   the token belongs to no person.
2. **Give it the Read-Only Administrator role** under **Security ›
   Administrators**.
3. **To audit admins and API tokens too**, create a custom role under
   **Security › Administrators › Roles**, such as **Pion Audit**, with only
   **View roles, resources, and admin assignments** (`okta.iam.read`) and
   **View API tokens** (`okta.users.apitokens.read`). Assign it to the same user
   for all users and all Identity and Access Management resources. The
   Read-Only Administrator cannot see admins or tokens.
4. **Sign in as that user and create a token** under **Security › API ›
   Tokens**. Limit it to your network zone where Okta offers it.
5. **Add the account** with your org's domain, such as `acme.okta.com`, not its
   `-admin` address, and paste the token.

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

- A token refused or rejected wakes the agents once, and once more after Pion
  relaunches if it is still so. It wakes them again only after the log has been
  read once since.
- A failure that passes, such as Okta rate limiting, holds the watch back for up
  to half an hour, reading the same window again, before it is told the same
  way.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- users, groups, apps, the System Log, admin assignments and API tokens;
- which admin roles the token's admin holds, warning when they can change the
  org;
- where the token may be used from.

For anything that does not work, it says what to change. Any refused call says
the same: the role or permission the admin lacks, or a token that Okta no longer
accepts.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why. A result that matched more than it kept says so. When Okta
  fails on a later page, the pages already read are kept and the result says
  which page it stopped at and why.
- **An answer Pion cannot read is an error, never "nothing found".**
- **"No events" is not "none happened".** A search says nothing matched only in
  what it read.

## Containing an incident

**Okta Containment** is a separate tool, with its own admin and token, so the
audit token stays read-only.

1. **Create another user**, such as `pion-containment@example.com`.
2. **Create a custom role** under **Security › Administrators › Roles**, such as
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

3. **Assign it to the user** with a resource set of all users and all groups.
   Never make the user a super or organization administrator.
4. **Create its token** as that user, add the account, and ask an agent to run
   its **check-access**. It reads the admin's role and says which actions it
   allows and what to add for the rest, warning when the role allows far more.

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
| `revoke-api-token` | Revokes one API token, never the connection's own. | None: a new token must be made. |
| **check-access** (not held) | See step 4. | Nothing changes. |

Every action takes a user by their full Okta ID (`00u…`) or full login. Okta
also resolves short names, loosely, so Pion refuses them and checks that Okta
resolved exactly the user given. Pion refuses to act on:

- the admin its own token belongs to;
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
