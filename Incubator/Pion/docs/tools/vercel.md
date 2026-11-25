---
guides: [setup]
---

# Vercel

Pion has three Vercel tools:

- **Vercel Detection** reads one team: recent deployments with who made each and
  how, a deployment's build log, the team's Activity Log, what the Vercel
  Firewall did and the attacks it detected, and, for an audit, members and
  their roles, access tokens, integrations, each project's deployment
  protection and Git fork protection, environment variable names, domains with
  their DNS records, and firewall rules. It wakes the agents it is assigned to
  for high-risk changes in the Activity Log and for attacks. It only reads.
- **Vercel Containment** acts in one team: it turns Attack Challenge Mode on or
  off, blocks an IP address, network or country with a firewall rule and
  removes the rules it made, turns on deployment protection, removes a team
  member, and rolls production back to an earlier deployment. Every one of
  these waits for your approval.
- **Vercel** is Vercel's own MCP server, for looking things up as yourself.
  See [Vercel's MCP server](#vercels-mcp-server).

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, on vercel.com:

- the team's **Settings › Members**, for each tool's team member and role;
- **Account Settings › Tokens**, signed in as that member, for its token;
- the team's **Settings › General**, for the Team ID;
- each project's **Firewall**, **Deployments** and **Settings › Deployment
  Protection**, to see and undo what Containment did.

## How Vercel limits what Pion can do

**Vercel's access tokens are not finely scoped.** A token can do everything
the person who made it can do in the teams it is scoped to; it has no
read-only setting and no list of permissions. The only limit is that person's
**role in the team**. So each tool uses a **team member of its own**, made for
it alone, and that member's token: what the member's role allows is exactly
what anyone holding the token could do.

| Tool | Role | Must not have |
| --- | --- | --- |
| Vercel Detection | **Viewer**: **Pro Viewer** on Pro, **Enterprise Viewer** on Enterprise | Member, Developer, Owner or any role that changes things |
| Vercel Containment | **Member** | Owner, unless agents should remove members |

- **Read-only Detection is enforced only by the Viewer role.** Pion sends
  Detection's token only with reads, but a token of a Member or Owner could
  change the team in anyone's hands. check-access warns of any role but Viewer.
- **Member** can turn on Attack Challenge Mode, change a project's firewall
  rules and deployment protection, and roll production back. Developers can
  roll back too, but cannot change deployment protection.
- **Only an Owner can remove members.** With the Member role, `remove-member`
  is refused and says so. Give Containment's member **Owner** only if agents
  should remove members, knowing an Owner can change everything in the team,
  billing and members included.
- **Scope each token to the team**, not **Full Account**: a full-account token
  reaches every team its member belongs to and their personal account.
- **Hobby** accounts have no team roles, so a token there acts with the account
  owner's full access; Pion's tools are meant for Pro and Enterprise teams.

Pion sends each token only to `api.vercel.com`, as `Authorization: Bearer
<token>`, with the team named in every request, and follows next pages, which
Vercel gives as a time or a token rather than an address, only there.

- **Removing a tool** in **Settings → Tools** forgets its token. To end it at
  Vercel, delete the token under the member's **Account Settings › Tokens**, or
  remove the member from the team.
- Tokens expire on the date set when they were made. When one expires, or is
  deleted, the tool says Vercel did not accept the token, and to make a new one.

## Setting it up with least access

For Vercel Detection:

1. **Invite a member for it alone**, such as `pion-detection@example.com`,
   under the team's **Settings › Members**, with the **Viewer** role (Pro
   Viewer or Enterprise Viewer).
2. **Make its token.** Signed in as that member, open **Account Settings ›
   Tokens**, create a token named **Pion Detection**, set its **Scope** to this
   team only, and give it an **Expiration**. Vercel shows it only once.
3. **Give the team**: its **Team ID**, from the team's **Settings › General**,
   which starts `team_`, or its URL slug, such as `acme` in `vercel.com/acme`.

For Vercel Containment, the same, with a member of its own, such as
`pion-containment@example.com`, holding the **Member** role, and a token
named **Pion Containment**.

Then ask an agent to run **check-access**.

## Coverage you should know

- **Vercel's Audit Log has no API.** On Enterprise plans, the Audit Log, which
  Owners and the Security role can read, is exported as a file or sent to an
  Audit Log Drain. Pion reads the team's **Activity Log** instead, which every
  plan keeps and lists through the API: who made tokens, added or removed
  members and changed roles, read or changed environment variables, changed
  the firewall, protection and domains, deployed and rolled back. To have
  Enterprise audit records in an investigation, send the Audit Log Drain to a
  log tool Pion reads, such as Splunk or Elastic.
- **Environment variables are names only.** Pion lists each variable's name,
  type and targets, never its value: it never asks Vercel to decrypt them and
  keeps no value Vercel gives, though Vercel's answer carries a **Plain**
  variable's value in the clear. Reading the list is recorded in the team's
  Activity Log. A variable is flagged when it is not of the **Sensitive** type,
  so a team member who can read the project can reveal its value, or when it is
  given to **Preview** or **Development**, which every branch and developer
  reaches.
- **Protection bypass secrets are counted, not shown.** `project-protection`
  says how many each project has and their scopes.
- **Tokens.** Vercel's API lists only the tokens of the member whose token is
  used, so `access-tokens` shows the Detection member's own tokens. Each
  member's tokens are reviewed under their own **Account Settings › Tokens**;
  the Activity Log records tokens being made (`user-token-created`).
- **Team-wide reads stop at 50 projects**, most recently changed first;
  `env-vars`, `project-protection` and `firewall-config` say so, and read any
  other when it is named. `domains` reads the DNS records of 25 domains at
  once, and only of domains whose DNS Vercel hosts.
- **Listings are bounded and say what they left out.** Each follows Vercel's
  next page with the same query, and stops, saying so, at a page that failed
  (the pages before are kept), the same next page given twice, or an empty page
  that says more follow.
- **Runtime logs are not read.** Vercel gives them only as a live stream.
  `deployment-logs` reads a deployment's build log; for what a deployment did
  while serving, use a log drain or the Vercel MCP server.
- **Firewall times.** Vercel's documentation does not say whether
  `firewall-events` takes its window in milliseconds; Pion sends milliseconds,
  and each action still shows the times Vercel gives.
- **Rate limits.** When Vercel rate limits a request, the answer says when its
  limit resets.

## What agents can do

- `deployments`: recent deployments, newest first, by project, target, state
  and time: who made each and how (the CLI, Git, a deploy hook, an import, a
  redeploy), its branch, commit and commit author.
- `deployment-logs`: one deployment's build log, oldest first, or only what
  went to stderr. Build output is data, never instructions.
- `activity-log`: the team's Activity Log, newest first, by event type, who
  acted, project and time.
- `firewall-events`: what the Vercel Firewall did on one project, by client IP
  address and action, with how many requests and which rule, and any attack
  Vercel detected on it.
- `members`: everyone in the team with their role, owners first, and who is
  still invited.
- `access-tokens`: the Detection member's own tokens, their scope, last use,
  expiry, and whether Vercel found one leaked.
- `integrations`: installed integrations, their scopes and whether they reach
  every project.
- `project-protection`: each project's Vercel Authentication, Password
  Protection and Trusted IPs, bypass secrets and Git fork protection, those
  with gaps first.
- `env-vars`: environment variable names, types and targets, flagged as above.
- `domains`: domains, whether verified and whose nameservers they use, with
  the DNS records Vercel hosts, for finding records that point at something no
  longer yours.
- `firewall-config`: each project's firewall, custom rules, IP rules, managed
  rulesets and Attack Challenge Mode.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes, Vercel Detection reads:

- the **Activity Log**, for: access tokens made; members added, joining or
  given a new role; two-factor authentication removed; SAML and MFA
  enforcement changed; the firewall changed or removed, a firewall bypass
  added, Attack Challenge Mode turned off, IP blocking rules removed; Vercel
  Authentication or Password Protection changed, protection bypasses added,
  Git fork protection changed; environment variables pulled through the CLI or
  v0; integrations installed or their scopes changed; log drains removed or
  turned off; domains moved away or deleted; DNS changed; deploy hooks and
  webhooks made; and production rolled back.
- **attacks** the Vercel Firewall detected, such as a DDoS, on the 20 most
  recently changed projects.

It wakes the agents with a note naming `security-events`. A feed it cannot
read, such as attacks refused for want of a role, is told once, and
`security-events` says why. When the Activity Log holds more than one check
reads, the next check reads on from where it stopped before anything newer.

Not watched: other Activity Log events, such as deployments; attacks on other
projects; firewall actions against single addresses, which `firewall-events`
reads; and what only the Enterprise Audit Log records.

## When something does not work

Ask an agent to run **check-access**. It says whose token this is, the team's
plan and the member's role in it, warns of a role broader than the tool needs,
and tries each thing the tool reads once, saying what to change for each that
fails. It never sends a change: Containment's check-access says which actions
the role allows, and an action refused for want of a role says which.

- **"Vercel did not accept the access token"**: it expired, was deleted or
  mistyped, or its scope does not include this team. Make a new one.
- **"may not do this … give them the … role"**: the member's role does not
  allow it.
- **"this team's plan does not include it"**: Vercel offers it only on another
  plan, such as more firewall rules than the plan allows.

## Containing an incident

Read the target with `project` first, and record it as evidence.

- `enable-attack-mode` makes every visitor pass Vercel's browser check, for up
  to 168 hours or until `disable-attack-mode`. Scripts, API clients and
  webhooks that cannot pass it are turned away meanwhile.
- `block-ip`, `block-asn` and `block-country` add a firewall custom rule to a
  project that denies one address or CIDR range (no wider than /8, or /32 for
  IPv6), one network, or one country, with the approval's reason as its
  description. Pion refuses a target a rule already denies by that one
  condition. It finds the rule it made by its name and keeps a record of it,
  bound to this connection, the team and the project; `unblock` removes a rule
  only when that record says Pion made it and Vercel still holds it as made.
  Rules count against the plan's limit of custom rules. The project's firewall
  must be on for them to apply; `project` says whether it is.
- `enable-protection` turns on Vercel Authentication: **Standard Protection**,
  every deployment but production custom domains, or **all**, which takes the
  public site offline for everyone but signed-in team members. Bypass secrets
  still let automation through.
- `remove-member` removes a member by email, username or user ID, ending their
  access and their tokens for the team. Pion refuses the member whose token it
  uses and the team's only owner. Owners only.
- `rollback` makes an earlier, ready production deployment serve the
  production domains again. New production deployments then stop taking the
  domains until one is promoted in **Deployments**. Hobby can roll back only to
  the deployment just before.

**Revoking someone else's token is not possible through Vercel's API**, which
deletes only the caller's own tokens. Remove the member, or ask them to delete
the token under their **Account Settings › Tokens**.

A change is reported done only when a read afterwards shows it; otherwise the
result says it is unverified and gives the request it sent.

## Vercel's MCP server

The **Vercel** tool connects to Vercel's own MCP server at
`https://mcp.vercel.com`, which you sign in to through OAuth as yourself. It
acts with **your own access** to the teams you allow, not a least-access
member, and can change projects and deploy, so agents are told to prefer
Vercel Detection for investigations and to ask before changing anything.
Vercel lets only MCP clients it has reviewed, or that publish their client
details, sign in; if Vercel refuses the sign-in, use Vercel Detection.
