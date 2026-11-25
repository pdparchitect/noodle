---
guides: [setup]
---

# Proofpoint TAP

The **Proofpoint TAP** tool reads what Proofpoint Targeted Attack Protection
saw in the last hour: messages with threats it delivered or blocked, with
sender, recipients, subject and the threat, and clicks on threat links it
permitted or blocked, with who clicked and from where. Watching the tool wakes
its agents for threats that reached people: a delivered message or a
permitted click. It only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Proofpoint limits what Pion can do

Pion reaches TAP's SIEM API with a **service principal and secret**, a
credential made in the TAP Dashboard. It keeps them in this Mac's Keychain and
sends them with HTTP Basic authentication, only to
`tap-api-v2.proofpoint.com`. To revoke them, delete the credential under
**Settings › Connected Applications**.

A credential reaches **all of the organisation's TAP data** through every TAP
API: Proofpoint has no narrower credential. The TAP APIs only read, so the
credential cannot change anything, but it does show every threat message's
recipients and subjects. Make one for Pion alone, so you can revoke it without
breaking anything else.

**Limits.** Proofpoint allows each credential **1,800 requests in any 24
hours**, and refuses the rest until the oldest age out. Each `siem-events`
call, each check while the tool is watched, and check-access send one request.
Each request reads at most the last hour.

## Setting it up

1. **Make the credential.** In the TAP Dashboard, open **Settings › Connected
   Applications** and choose **Create New Credential**. Name it **Pion**, and
   copy the **Service Principal** and **Secret**; the secret is shown only
   once.
2. **Add the tool** with both.

Then ask an agent to run **check-access**.

## What agents can do

- `siem-events` lists the threat messages delivered and blocked, and the
  clicks on threat links permitted and blocked, over the last 60 minutes or as
  many as asked. Pulling a message or blocking a sender is for the champion to
  do in Proofpoint.
- `check-access` tries the credential once; see below.

## When something does not work

Ask an agent to run **check-access**. It reads the last minute once, which
counts toward the 1,800 requests, and says how many threat messages and clicks
it held, or what to change:

- **"did not accept the service principal and secret"**: they are wrong, or
  the credential was deleted. Make a new one.
- **"may not read this organisation's data"**: the credential was made for
  another organisation; make it in the TAP Dashboard of the one agents should
  read.
- **"used Proofpoint's 1,800 requests"**: wait for the oldest to age out.

## What to check on a live account

These follow Proofpoint's documentation, but were tested only against
stand-ins:

- whether a credential expires, and how the TAP Dashboard shows it;
- that a watched tool's checks and agents' calls together stay well under
  1,800 requests a day.
