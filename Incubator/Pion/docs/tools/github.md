---
guides: [setup]
---

# GitHub

Pion has two GitHub tools, each for one organisation:

- **GitHub Detection** reads the organisation: its audit log, members, owners,
  outside collaborators and teams, and its open secret scanning, code scanning
  and Dependabot alerts, which it watches. For an audit it also reads the
  organisation's security settings, members without two-factor
  authentication, the other GitHub Apps installed, webhooks, each repository's
  secret scanning, push protection and branch rules, deploy keys, fine-grained
  personal access tokens, GitHub Actions settings and runners, and SAML
  credential authorizations. It only reads.
- **GitHub Containment** acts in the organisation: it removes members and
  outside collaborators, blocks users, demotes owners, takes people off teams,
  cancels invitations, revokes fine-grained tokens and SAML authorizations,
  deletes deploy keys, disables webhooks and Actions, cancels workflow runs,
  and reports leaked GitHub tokens to GitHub. Every one of these waits for your
  approval, and Pion records what undoing it takes before it acts.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, on github.com:

- the organisation's **Settings › Developer settings › GitHub Apps**, to
  register each tool's App;
- the App's page, to **Install App** on the organisation;
- the organisation's **Settings › GitHub Apps**, to see an installation's
  permissions, approve new ones, or suspend another App;
- **Settings › People**, to see or invite members back.

## How GitHub limits what Pion can do

Each tool signs in through a **private GitHub App** your organisation
registers itself; Pion ships none. A private App can be installed only on the
organisation that owns it, and only its members can sign in through it.

- **The App's permissions are the ceiling.** A GitHub App has no scopes: its
  registration lists, for each kind of thing, **No access**, **Read-only** or
  **Read and write**. Detection's App holds only read permissions, so nothing
  signed in through it can change the organisation, whoever signs in.
- **The person's role is the other limit.** The sign-in acts as the person who
  enters the code, and never gets more than they have. Most of what Pion
  reads for an audit, and everything Containment does, needs an
  **organisation owner**; security alerts need an owner or a **security
  manager**.
- **Signing in uses a code**, GitHub's device flow, which needs only the App's
  Client ID and no client secret. Pion shows the code and opens GitHub, where
  you enter it.
- **Sign-ins last.** GitHub gives the App an access token for eight hours and a
  refresh token for six months; Pion renews the access token on its own,
  without a secret, and keeps each new pair. After six months unused, or when
  the App is uninstalled or its authorization revoked, connect the tool again.
- **SAML single sign-on.** If the organisation enforces it, sign in to GitHub
  through your identity provider before entering the code, or the
  organisation's resources stay hidden from the sign-in.

Pion reaches only `api.github.com`, and every request names the organisation:
a repository is always one of the organisation's own, and Pion refuses a
repository of any other owner before sending anything.

- **Removing a tool** in **Settings → Tools** forgets its sign-in. To end it at
  GitHub, revoke the App's authorization under your **Settings › Applications ›
  Authorized GitHub Apps**, or uninstall the App.

## The two Apps' permissions

Under **Permissions** when registering each App, give only these and leave
every other at **No access**.

**Pion Detection**, every one **Read-only**:

| Section | Permission | What reads it |
| --- | --- | --- |
| Repository | Administration | deploy keys |
| Repository | Code scanning alerts | security alerts |
| Repository | Dependabot alerts | security alerts |
| Repository | Metadata | repositories and their branch rules (GitHub requires it) |
| Repository | Secret scanning alerts | security alerts |
| Organization | Administration | audit log, App installations, code security configurations, Actions policy, SAML authorizations |
| Organization | Members | members, owners, outside collaborators, teams, two-factor filters |
| Organization | Personal access token requests | pending fine-grained token requests |
| Organization | Personal access tokens | fine-grained tokens with access |
| Organization | Self-hosted runners | self-hosted runners |
| Organization | Webhooks | webhooks |

**Pion Containment**:

| Section | Permission | Access | What it is for |
| --- | --- | --- | --- |
| Repository | Actions | Read and write | cancelling workflow runs |
| Repository | Administration | Read and write | deploy keys, adding collaborators back, a repository's Actions setting |
| Repository | Metadata | Read-only | finding the repositories an outside collaborator reaches |
| Organization | Administration | Read and write | the organisation's Actions setting, SAML authorizations |
| Organization | Blocking users | Read and write | blocking and unblocking |
| Organization | Members | Read and write | members, owners, outside collaborators, invitations, teams |
| Organization | Personal access tokens | Read and write | revoking fine-grained tokens |
| Organization | Webhooks | Read and write | disabling and enabling webhooks |

Also when registering each App: leave **Callback URL** empty, untick
**Webhook › Active** (Pion receives no events), tick **Enable Device Flow**,
keep **Expire user authorization tokens** ticked, and choose **Only on this
account**. Then install it on the organisation, for **All repositories** or
only those Pion should reach: the App sees nothing in a repository it is not
installed on.

Keep the two Apps apart. Containment's App can write, so giving Detection its
permissions would let a read-only tool change the organisation.

## Plans and roles

| What | Needs |
| --- | --- |
| Audit log | GitHub **Enterprise Cloud**, an owner |
| SAML credential authorizations, reading and revoking | **Enterprise Cloud** with SAML single sign-on, an owner |
| Secret scanning and push protection on private repositories | GitHub's paid **Secret Protection** (Team or Enterprise Cloud) |
| Code scanning on private repositories | GitHub's paid **Code Security** (Team or Enterprise Cloud) |
| Branch rules on private repositories | Team or Enterprise Cloud |
| Security alerts | an owner or security manager |
| Organisation settings, two-factor filters, App installations, webhooks, tokens, Actions settings | an owner |
| Everything Containment does | an owner (a team maintainer can take people off their own team) |

Everything else works on every plan.

## What agents can do

GitHub Detection:

- `audit-log`: the audit log, newest first, by GitHub's search phrase, such as
  `actor:mallory action:repo.destroy`.
- `people`: members, which are owners, and outside collaborators.
- `teams`: teams, with their members and parent team.
- `security-alerts`: open secret scanning, code scanning and Dependabot alerts,
  newest first, with whether a leaked secret is still valid.
- `org-settings`: whether two-factor authentication is required, the base
  repository permission, what members may create, fork, delete and invite,
  web commit sign-off, deploy keys, and the code security configurations that
  set up secret scanning and push protection. GitHub shows most of these only
  to an owner; the result says which were hidden.
- `members-without-2fa`: members and outside collaborators without two-factor
  authentication, or with a method GitHub counts as insecure. Refused unless
  the signed-in person is an owner, as GitHub filters only for owners.
- `app-installations`: other GitHub Apps installed on the organisation, those
  that write to administration, contents, members, workflows or secrets, or
  reach every repository, first.
- `webhooks`: where the organisation sends its events: each hook's host only,
  its events, and whether it skips TLS verification, uses plain HTTP, has no
  secret or sends every event.
- `repo-security`: each repository's secret scanning and push protection,
  private and internal repositories without them first, and the rules on the
  default branch of the most recently pushed repositories (30 unless asked
  for up to 100).
- `deploy-keys`: deploy keys of one repository, or of the most recently pushed
  ones, keys that can write first.
- `fine-grained-tokens`: fine-grained tokens with access to the organisation,
  and requests waiting, those that write, never expire or reach every
  repository first.
- `actions-settings`: which repositories may run Actions and which actions,
  the `GITHUB_TOKEN`'s default permissions, whether workflows may approve pull
  requests, and self-hosted runners.
- `credential-authorizations`: credentials authorized for SAML single sign-on,
  with who holds each and when it was last used.
- **check-access**: see [When something does not work](#when-something-does-not-work).

**Listings are bounded and say so.** Each reads up to ten pages of a hundred.
Reads that go repository by repository, such as rules and deploy keys, take
the most recently pushed first and say when there were more.

## The alert watch

GitHub Detection checks the organisation's alerts and wakes the agents it is
assigned to for every new leaked secret, and for new code scanning and
Dependabot alerts that are high or critical, naming `security-alerts`. A feed
that cannot be read, such as code scanning on an organisation without it, does
not stop the others.

## When something does not work

Ask an agent to run **check-access**. It says who signed in and whether they
are an owner, how the App is installed on the organisation, which of the
permissions the tool uses the installation lacks, and any it holds beyond
them, then tries each read once and says, for each that fails, what to change:

- **"the GitHub App lacks …"**: add that permission to the App, then approve it
  on the organisation's installation (**Settings › GitHub Apps › Configure**).
  GitHub asks an owner to approve every permission added later.
- **"it needs an organisation owner"**: connect the tool again, signed in as an
  owner.
- **"needs GitHub Enterprise Cloud"**: the organisation's plan does not have it.
- **"enforces SAML single sign-on"**: sign in through the identity provider,
  then connect again.
- **"GitHub did not accept the sign-in"**: it was revoked, unused for six
  months, or the App was suspended or uninstalled. Connect again.

## Containing an incident

Find the target with GitHub Detection first, and record it as evidence. Each
action reads what it acts on first, refuses what is already as asked, and
keeps an **undo record** of what undoing it takes before sending anything; its
result gives the record's ID. `undo-records` lists them. A change is reported
done only when a read afterwards shows it.

Pion refuses to remove, block or demote the person the tool is signed in as,
and the organisation's last owner.

| Action | What happens | Undo |
| --- | --- | --- |
| `remove-member` | Loses every team and repository; their forks of private repositories are deleted; GitHub emails them | `reinstate-member` re-invites them with GitHub's **reinstate** role, which within three months gives back their role, teams, access and forks once they accept; it needs a free seat |
| `remove-outside-collaborator` | Removed from every repository. Pion first records the repositories they reach and their permission on each, reading up to 300 repositories, and says when it read fewer than the organisation has | `restore-collaborator` invites them back to each recorded repository with its permission; they accept each invitation |
| `cancel-invitation` | The invitation can no longer be accepted | Invite them again; the record keeps the role and teams |
| `block-user` | If they are a member or outside collaborator, removes them first, as above, all under one approval; then blocks them. Their invitations are cancelled and their stars, watches and assignments removed | `unblock-user` lifts the block; giving back membership or repository access is a separate step, with the removal's own record. Stars and watches do not come back |
| `demote-owner` | An owner becomes a member | `restore-owner`; GitHub emails them |
| `remove-from-team` | Loses what that team gives them; they stay in the organisation | `restore-team-membership`, with their recorded role |
| `revoke-fine-grained-token` | The token loses access to the organisation; its owner is emailed | **Cannot be undone**: the owner asks for access again |
| `delete-deploy-key` | Whoever holds the private key loses the repository | `restore-deploy-key` adds the same public key back, under a new ID |
| `disable-webhook` | The hook stops delivering; it and its settings are kept | `enable-webhook`; events missed meanwhile are not sent again |
| `revoke-sso-credential` | A token, SSH key or App token loses the organisation (Enterprise Cloud) | **Cannot be undone** by Pion: the person authorizes it again |
| `disable-actions` | No workflows run in one repository, or in the whole organisation | `enable-actions` puts back the recorded settings, and which repositories were allowed |
| `cancel-workflow-run` | A queued or running run stops | **Cannot be undone**; the workflow can be run again as a new run |
| `report-leaked-token` | GitHub revokes the token and tells its owner | **Cannot be undone**: the owner makes a new token |

**Reporting a leaked token** works for any classic or fine-grained personal
access token, OAuth app token, or GitHub App user or refresh token, the
organisation's or not. GitHub accepts these reports only from someone not
signed in, so Pion sends it to `api.github.com` without the tool's sign-in.
Pion never keeps or repeats the token: its record holds only the kind of token
and a short SHA-256 fingerprint. The token is still in the approval request and
the conversation it came from, and Noodle keeps a declined or expired approval
request for 7 days. GitHub takes 60 such reports an hour from one address.

## What GitHub's API cannot do

- **Suspend or uninstall another GitHub App.** Only an owner can, in the
  organisation's **Settings › GitHub Apps**: choose **Configure** on the App,
  then **Suspend** or **Uninstall**. `app-installations` says so beside each.
- **List or revoke classic personal access tokens**, except through SAML
  credential authorizations on Enterprise Cloud.
- **Give a revoked fine-grained token its access back.**
- **List deploy keys across the organisation** at once: they are read
  repository by repository.
- **Read or change which OAuth apps the organisation allows.**
- **Block for a time**: a block made through the API lasts until lifted.

Left out of Containment on purpose: removing self-hosted runners (the machine
must be re-registered, and stays compromised), deleting webhooks (disabling
keeps them), and making repositories private (stars, watchers and forks are
lost for good).

## What to check on a live account

Some of GitHub's behaviour is not stated plainly in its documentation. When
first connecting each tool, check:

- **Renewal.** After eight hours, a read still works without connecting again:
  Pion renews the sign-in with no client secret, as GitHub's documentation
  says the device flow allows.
- **Membership reads.** `GET /orgs/{org}/memberships/{user}`, which
  Containment reads before removing, demoting or blocking, works under
  Members: read; GitHub's permissions page does not list it.
- **Sign-in with no scopes.** GitHub's answer to a GitHub App sign-in lists no
  scopes, and Pion asks for none; the sign-in completes.
- **A webhook's secret.** GitHub's documentation warns that updating a webhook
  may remove its secret. `disable-webhook` and `enable-webhook` send only
  whether the hook is active, then check whether a secret is still set, and
  say so if it was lost.
- **Owner-only fields.** Run `org-settings` and `members-without-2fa` signed in
  as a member and as an owner, to see which fields GitHub hides from a member.
- **Rate limits.** A user sign-in has 5,000 requests an hour; reads that go
  repository by repository use one request per repository, so an organisation
  with thousands of repositories reads only part at a time.
