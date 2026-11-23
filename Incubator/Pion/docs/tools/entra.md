# Microsoft Entra ID

Pion has two Microsoft Entra ID tools, each added per tenant with a sign-in of
its own:

- **Microsoft Entra ID Audit** reads a tenant the way a defender does: who a
  user is, their groups, roles and sign-in methods, the sign-in log, Identity
  Protection's risky users, who holds which directory role, which apps hold
  which Microsoft Graph permissions and credentials, and the directory audit
  log. It wakes the agents it is assigned to when the audit log shows the
  tenant being handed over, a way back in being opened or its defences
  weakened, and when Identity Protection rates a user or a sign-in at high
  risk. It only reads.
- **Microsoft Entra ID Containment** acts on the same tenant to contain an
  account: it disables or restores a user's sign-in, revokes their sessions,
  deletes their sign-in methods, removes their directory roles, removes a
  client secret from an app, and confirms a user compromised or dismisses
  their risk. Every one of these waits for your approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the [Microsoft Entra admin center](https://entra.microsoft.com):

- **App registrations**, for each tool's app, its redirect URI and its API
  permissions.
- **Enterprise applications**, to let only each tool's admin use its app.
- **Roles and administrators**, or **Privileged Identity Management**, for each
  tool's admin and their roles.
- **Audit logs** and **Sign-in logs**, to see what the tools read.

## How Microsoft limits what Pion can do

Both tools sign in as a Microsoft Entra admin through OAuth, at your tenant's
own address on Microsoft's sign-in service
(`https://login.microsoftonline.com/<your tenant>/oauth2/v2.0/authorize` and
`/token`). Each signs in through an app registration your organisation makes
for that tool alone, as a public client with an authorization code and PKCE, so
Pion keeps no client secret or certificate. Every sign-in asks for the admin's
password again, so a browser already signed in to Microsoft as someone else
never answers for them. Your Conditional Access policies, such as MFA for
admins, apply to the sign-in as to any other.

Microsoft allows a request only when **both** of these allow it:

- **the app's delegated permissions**, which you add under **API permissions**
  and grant admin consent for. Pion asks for exactly the permissions below,
  and refuses a sign-in that lacks any.
- **the signed-in admin's roles.** Each tool gets an admin of its own.

| Tool | Delegated Microsoft Graph permissions | Admin's roles |
| --- | --- | --- |
| Microsoft Entra ID Audit | `Directory.Read.All`, `AuditLog.Read.All`, `UserAuthenticationMethod.Read.All`, `IdentityRiskyUser.Read.All`, `IdentityRiskEvent.Read.All`, `RoleManagement.Read.Directory` | Global Reader |
| Microsoft Entra ID Containment | `User.Read.All`, `User.EnableDisableAccount.All`, `User.RevokeSessions.All`, `UserAuthenticationMethod.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `Application.ReadWrite.All`, `IdentityRiskyUser.ReadWrite.All`, `GroupMember.Read.All` | only the roles its actions take, below |

Both also ask for `offline_access`, so the sign-in renews itself without asking
again; Microsoft never lists it among the permissions it granted, so Pion does
not require it back.

Why Audit asks for each:

- `Directory.Read.All` reads users, groups, apps, enterprise apps and their
  consents. Microsoft's sign-in log needs it beside `AuditLog.Read.All`, so it
  covers the narrower `User.Read.All`, `Group.Read.All` and
  `Application.Read.All` too.
- `AuditLog.Read.All` reads the directory audit log and the sign-in log.
- `UserAuthenticationMethod.Read.All` reads users' sign-in methods.
- `IdentityRiskyUser.Read.All` and `IdentityRiskEvent.Read.All` read Identity
  Protection's risky users and risk detections.
- `RoleManagement.Read.Directory` reads role assignments and, in Privileged
  Identity Management, eligibility.

Audit's permissions only read, so it cannot change anything, whatever its
admin's roles allow. Containment's permissions can change users, roles and
apps, so its admin's roles are what limit it: never make that admin a Global
Administrator.

- **Sign Out** in **Settings → Tools** forgets the sign-in. Microsoft offers no
  way for an app to revoke its own sign-in; to end it at Microsoft, revoke the
  admin's sessions in the admin center.
- When the sign-in expires or is revoked, the admin is disabled or their
  password changes, or a Conditional Access policy blocks it, the tool says to
  connect it again.

Both tools reach only `login.microsoftonline.com`, to sign in, at your tenant's
own address, and `graph.microsoft.com`. Pion checks the tenant is a Directory
(tenant) ID or a domain alone, letters, digits, dots, hyphens and underscores,
and not dots alone, so it can never lead the sign-in anywhere else, and refuses
`common`, `organizations` and `consumers`, which stand for any tenant. It
checks when you add the account and again before every sign-in, call and
renewal: if the tenant saved under an account no longer passes, nothing is sent
and the tool says to correct it. A sign-in made for one tenant is never used for
another. Graph pages its listings with a link to
the next page. Pion follows that link only on `graph.microsoft.com` at the same
path, and takes only its `$skiptoken`, asking again with its own query, so a
listing never leads anywhere else.

## Setting it up with least access

1. **Register the app.** In **App registrations**, choose **New registration**.
   Name it **Pion Audit** and keep **Single tenant**. Under **Redirect URI**,
   choose **Public client/native (mobile & desktop)** and give
   `com.pdparchitect.pion:/oauth2callback`
   (`com.pdparchitect.pion.local:/oauth2callback` for Pion Dev). Add no client
   secret or certificate.
2. **Add its permissions.** Under **API permissions**, choose **Add a
   permission › Microsoft Graph › Delegated permissions** and add exactly
   Audit's permissions from the table above. Remove `User.Read`, which a new
   app is given. Choose **Grant admin consent**; only a Global Administrator or
   a Privileged Role Administrator can.
3. **Let only its admin use it.** Under **Enterprise applications**, open the
   app. In **Properties**, set **Assignment required?** to **Yes**, and under
   **Users and groups** assign only the admin who will sign in.
4. **Choose its admin.** Keep an admin for Microsoft Entra ID Audit alone, such
   as `pion-audit@contoso.com`, with only the **Global Reader** role. It reads
   everything this tool reads and changes nothing.
5. **Add the account** with the **Directory (tenant) ID** and the app's
   **Application (client) ID**, from its **Overview**. Choose **Add & Connect**
   and sign in as that admin.

Then ask an agent to run **check-access**.

## Licences

- **The sign-in log needs Microsoft Entra ID P1.** Without it, `sign-ins` says
  so.
- **Identity Protection needs Microsoft Entra ID P2**: `risky-users`, the
  watch's risky users and risk detections, and Containment's
  `confirm-compromised` and `dismiss-user-risk`. Without it, the watch says
  once that those feeds are off.
- **Eligible roles need Privileged Identity Management**, part of P2. Without
  it, `role-holders` says it could not read them, and nobody can be eligible.

## Coverage you should know

- **The audit and sign-in logs keep 30 days** with P1 or P2, seven without.
  Pion refuses a search reaching further back than 30 days.
- **Searches are bounded.** Every log search names its start and end.
  `sign-ins` and `directory-audit` keep the newest up to their limit and say
  when more matched.
- **find-user matches the start of a name, user principal name or email**, and
  says when more users match than it kept.
- **A guest's user principal name holds `#EXT#`**, which no address can take:
  give guests by object ID.
- **role-holders lists active and eligible holders.** A group shown holding a
  role gives it to every member.
- **app-credentials lists each app's object ID and each credential's keyId**,
  which Containment's `remove-app-credential` takes.
- **Throttling.** When Graph throttles a request, Pion waits as long as Graph's
  `Retry-After` asks and tries again. If Graph still refuses, the answer says
  how long it asked to wait.
- **An event's actor is the account used**, not the person who held it.

## What agents can do

- `find-user`: users by the start of their name, user principal name or email,
  with whether they can sign in.
- `user-groups`, `user-sign-in-methods`: a user's groups and roles, nested ones
  marked, and their registered sign-in methods with their IDs.
- `sign-ins`: the sign-in log, newest first, by user, IP address, failures and
  time, with app, location, Conditional Access and risk.
- `risky-users`: the users Identity Protection rates at risk, highest first.
- `role-holders`: each directory role's active and eligible holders, Global
  Administrator and the other privileged roles first.
- `app-permissions`: which apps hold which Microsoft Graph permissions, flagging
  those that can change the tenant or make administrators.
- `app-credentials`: the secrets and certificates apps sign in with, newest
  first, flagging those added in the last 30 days, long-lived or expired.
- `directory-audit`: who changed what, by who made it, activity, category and
  time, and from which IP address.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes the watch reads three feeds:

- **the directory audit log**, for:
  - a privileged role granted, made eligible, or activated in Privileged
    Identity Management: Global, Privileged Role, Privileged Authentication,
    Security, Exchange, SharePoint, Application, Cloud Application, User,
    Conditional Access, Hybrid Identity and Authentication Administrator;
  - a secret or certificate added to an app registration or enterprise app;
  - admin consent to an app, or consent or a grant that gives an app
    high-privilege permissions, such as reading mail or files or making
    administrators;
  - a domain's federation changed, or a domain added;
  - a Conditional Access policy added, changed or deleted, or a named location
    changed. The log does not show whether a change weakened sign-in, so the
    agent reads the policy;
  - a user's sign-in methods changed by an admin or by anyone other than them;
- **Identity Protection's risky users**, for users rated at high risk;
- **Identity Protection's risk detections**, for sign-ins and other detections
  at high risk.

Each feed reads from six hours before the newest entry it has seen, as
Microsoft lists audit entries minutes late and Identity Protection may rate a
user hours after, up to four pages each time.

It wakes the agents with a note naming `security-events`. The note carries only
how many, and when. Nothing Microsoft wrote reaches the note: no ID, name,
address or text. Each entry is told once.

When one check finds more than it can hand over (500), or more than it may
read:

- each kind of entry takes its turn;
- the watch says once that more follow;
- the checks after read on from the oldest entry not yet handed over, until all
  of it is handed over, even across a check that could not read the feed.

A check that reaches its four pages keeps Graph's `$skiptoken` and the exact
search it belongs to. The next check goes on from that token, never from a
time, so even thousands of entries made at the same moment are read through
once. When that search ends, the feed reads on from six hours before its end,
however far the watch has moved on meanwhile, so nothing made just after it is
skipped. If Graph turns down a kept token, the watch says so once and reads
that window again from its start.

A check that fails for a passing reason, such as Graph throttling, keeps nothing
but how many checks in a row failed, so the next check reads the same window
again.

**What it does not watch:**

- sign-ins themselves, including failed ones and bursts of failed MFA, which
  `sign-ins` finds with `failuresOnly`;
- users created, deleted, disabled or given new passwords;
- group memberships and app assignments;
- roles other than the privileged ones above, and roles given through a group's
  membership;
- users registering their own sign-in methods;
- consent a user gives with low privileges;
- users and sign-ins at medium or low risk.

**When it cannot read a feed**, it says so rather than going quiet:

- A feed refused, or a sign-in Microsoft no longer accepts, wakes the agents
  once, and once more after Pion relaunches if it is still so. It wakes them
  again only after the feed has been read once since.
- Identity Protection without P2 is said once to be off, and again after a
  relaunch.
- A failure that passes, such as Graph throttling, holds the watch back for up
  to half an hour, reading the same window again, before it is told the same
  way.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries once each:

- which tenant the sign-in reads, and whether it is the one the account names;
- users, apps, the audit log, the sign-in log, risky users, risk detections,
  role assignments, eligible roles and sign-in methods;
- who is signed in and which roles they hold, saying when those roles could
  change the tenant;
- which permissions the app is consented, warning of any beyond what the tool
  asks for, of permissions to other APIs, and of application permissions, which
  Pion never uses.

For anything that does not work, it says what to change. Any refused call says
the same: a licence the tenant lacks, the app's permission or the admin's role,
or a sign-in that Microsoft no longer accepts, which needs connecting again.
Microsoft's refusal does not say whether the app's permission or the admin's
role is missing, so Pion names both.

## Reading results

- **Results say what they covered.** A listing that stopped before the end says
  so, and why. A result that matched more than it kept says so. When Graph
  fails on a later page, the pages already read are kept and the result says
  which page it stopped at and why.
- **An answer Pion cannot read is an error, never "nothing found".**
- **"No events" is not "none happened".** A search says nothing matched only in
  what it read.

## Containing an incident

**Microsoft Entra ID Containment** is a separate tool, with its own app, admin
and sign-in, so the audit sign-in stays read-only.

1. **Register another app** as in steps 1 to 3 above, named **Pion
   Containment**, and give it Containment's permissions from the table above.
2. **Choose another admin**, such as `pion-containment@contoso.com`.
3. **Give that admin only the roles its actions take**, leaving out any you do
   not want agents to have. Better, make them eligible in Privileged Identity
   Management, so the admin activates them only while containing:

   | Role | For |
   | --- | --- |
   | Privileged Authentication Administrator | `disable-sign-in`, `enable-sign-in`, `revoke-sessions` and `delete-sign-in-methods`, for any user |
   | Privileged Role Administrator | `remove-directory-role` |
   | Cloud Application Administrator | `remove-app-credential` (client secrets) |
   | Security Operator | `confirm-compromised`, `dismiss-user-risk` |

   A **User Administrator** or **Authentication Administrator** can do the
   first ones only for users who hold no admin role. These roles are powerful
   in their own right: a Privileged Role Administrator can make anyone a Global
   Administrator. Never make the admin a Global Administrator.
4. **Add the account** with the tenant and this app's **Client ID**, sign in as
   that admin, and ask an agent to run its **check-access**. It reads the
   admin's roles and says which actions they allow and what to add for the
   rest, warning when they allow far more.

What agents can do. Each action is held for your approval. Each one's
description and result say how it is recovered:

| Action | What it does | Recovery |
| --- | --- | --- |
| `user` (not held) | Reads whether the user can sign in, whether they are synced from on-premises, their active and eligible roles with IDs, sign-in methods with IDs, risk, and whether they are a Global Administrator. | Nothing changes. |
| `disable-sign-in` | Stops the user signing in (`accountEnabled` false). | `enable-sign-in` restores it. Disabling does not end sessions or tokens already issued. |
| `enable-sign-in` | Restores sign-in. Held, as it gives access back. | `disable-sign-in` again. Before restoring, remove untrusted methods, reset the password and revoke sessions. |
| `revoke-sessions` | Invalidates the user's refresh tokens and session cookies, so they must sign in again everywhere. | Nothing to restore. Access tokens already issued last until they expire, usually within an hour, except in apps that honour Continuous Access Evaluation. |
| `delete-sign-in-methods` | Deletes up to 20 sign-in methods by ID, such as an authenticator an attacker registered. Checks every one first, and reports each deletion. The password is not one. | The user registers them again. |
| `remove-directory-role` | Removes active role assignments and eligibility the user holds directly, by ID. Roles held through a group are refused. | Assign each role again; its ID and schedule are not restored. |
| `remove-app-credential` | Removes one client secret from an app registration or enterprise app, by the app's object ID and the secret's keyId. A certificate is refused, with the steps to remove it yourself. | None: whatever used the secret needs a new one. |
| `confirm-compromised` | Tells Identity Protection the user is compromised, setting their risk to high. | `dismiss-user-risk`. Risk-based Conditional Access may block the user meanwhile. |
| `dismiss-user-risk` | Dismisses the user's risk. Held, as it hides risk. | None directly; `confirm-compromised` raises it again. |
| **check-access** (not held) | See step 4. | Nothing changes. |

A typical containment is `disable-sign-in`, `revoke-sessions`,
`confirm-compromised` and, if the sign-in methods may be the attacker's,
`delete-sign-in-methods`.

Every action takes a user by their object ID (a GUID) or full user principal
name, and Pion checks Graph resolved exactly the user given. Pion refuses to
act on:

- the admin signed in to it, as Graph names them from the sign-in;
- a Global Administrator, active or eligible, directly or through a group,
  unless told the champion confirmed it with `allowGlobalAdmin`. Pion judges
  each assignment by the ID it names. When it cannot tell, because an
  assignment's holder is not named as a user, an app or a group, or a group's
  members cannot all be read, it refuses the same way;
- a user synced from on-premises Active Directory, for `disable-sign-in` and
  `enable-sign-in`: disable them there, then revoke their sessions here;
- the app it signs in through, for `remove-app-credential`, and any app whose
  answer does not name the app asked for and its application (client) ID.

Role assignment, eligibility, sign-in method, app and keyId IDs are checked for
their format and against what Graph lists before anything is sent. Every action
that makes several changes checks all of them first. If one fails part way, it
says which were made, which failed and which were not tried. Microsoft refuses
to delete a user's default sign-in method while others remain, so delete the
others first.

**Microsoft Graph takes no condition on these changes.** Users, roles, apps and
risky users have no ETag or If-Match, so another admin can change them between
Pion reading them and acting. Each result says when Pion read what it acted on.
Pion reads what an action needs just before it acts, and refuses what no longer
fits: sign-in already disabled, a method the user no longer has, a role held
through a group. A secret is removed by its keyId alone, so no other credential
is touched. Pion reads the app again after and says the secret is gone only when
Graph answers for that very app and lists its secrets, each with a valid key
ID, without it; otherwise it
says Graph accepted the removal but whether it holds is not known, and why.

**Pion never removes an app's certificate.** Graph removes one only with proof
signed by one of the app's own keys, which Pion does not hold, and writing the
app's list of certificates back without it would undo any certificate someone
added in the meantime. When asked, it changes nothing and tells you where to
remove it:

- an app registration: **App registrations › All applications**, open the app,
  **Certificates & secrets › Certificates**, find the certificate whose
  **Certificate ID** is the keyId, and choose **Delete**;
- an enterprise app: **Enterprise applications › All applications**, open the
  app, **Single sign-on › SAML Certificates**, choose **Edit** and delete the
  certificate there. If it is not listed there, take it to whoever manages
  that enterprise app. Never replace an app's whole list of certificates to
  remove one: that undoes any added meanwhile.
