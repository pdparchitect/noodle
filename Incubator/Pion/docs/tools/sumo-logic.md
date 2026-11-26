---
guides: [setup]
---

# Sumo Logic

The **Sumo Logic** tool searches one Sumo Logic account's logs with Sumo
Logic's query language. Agents use it to find the logs behind an incident,
such as every sign-in from an address. It only reads: Pion refuses a query
that uses the **save** operator, which writes results to a lookup table.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Sumo Logic limits what Pion can do

Pion searches through Sumo Logic's **Search Job API** with an **access key**:
an access ID and access key, made by one Sumo Logic user. It keeps them in this
Mac's Keychain and sends them with HTTP Basic authentication, only to the
API address of the deployment you choose, such as `api.eu.sumologic.com`. To
revoke them, delete or turn off the key under **Preferences › My Access Keys**,
or under **Administration › Security › Access Keys**.

An access key acts as the user who made it, so that user's **role** is what
limits Pion. Use a user of its own, such as `pion@example.com`, with a role
made for it:

- **Capabilities**: only **Create Access Keys**, so the user can make its own
  key. Not **Manage Access Keys**: that one sets up, turns off and deletes
  every user's access keys across the organisation. Leave out everything that
  manages data, collectors, users or the account.
- **Search filter**: limit the role to the logs agents should read, such as
  `_sourceCategory=prod/auth*`. Without one, the role searches every log. The
  filter is what limits the data Pion can see.
- **Access key scopes**, where Sumo Logic offers them: choose **Custom** and
  give the key only **Run Log Search**, so the key itself can do nothing but
  search, whatever the role holds. A key with the **Default** scope has all of
  the user's permissions.

**The Search Job API needs an Enterprise account**, or a Sumo Logic trial. On
other plans every search is refused.

**Searching is not free.** Each search runs a job in Sumo Logic, counted like
any search: on credit-based plans, the data it scans may spend credits. Sumo
Logic also limits each access key to 4 requests a second and 10 at once, and
an organisation to 200 search jobs running at once.

**The deployment** is the one your Sumo Logic address names:
`service.sumologic.com` is US1, `service.eu.sumologic.com` is EU, and so on
for US2, DE, AU, JP, CA, IN and FED. A key used at another deployment is
refused.

## Setting it up

1. **Make the role and the user**, as above, signed in as an administrator.
2. **Make the key.** Signed in as that user, open **Preferences › My Access
   Keys** and choose **Add Access Key**. Under **Scopes**, choose **Custom**
   and only **Run Log Search**. Copy the **Access ID** and **Access Key**; the
   key is shown only once.
3. **Add the tool** with both and the deployment.

Then ask an agent to run **check-access**.

## What agents can do

- `search` runs a query over a time range, the last 24 hours unless given,
  waits for it to finish, and returns its first 100 messages, or for an
  aggregate query its first 100 records. Then it removes the search job, so
  nothing is left running.
- `check-access` tries searching once; see below.

## When something does not work

Ask an agent to run **check-access**. It starts one search, `* | limit 1`,
over the last minute, and removes it at once without reading it. It says which
deployment it reached and whether searching works, and if not, what to change:

- **"did not accept the access ID and key"**: they are wrong, the key was
  deleted or turned off, or the deployment is not the account's.
- **"sent the request to another deployment"**: choose the deployment your
  Sumo Logic address names.
- **"refused searching through the API"**: the plan has no Search Job API,
  the role may not search, or the key's Custom scope leaves out **Run Log
  Search**.
- **"limiting this key"**: too many requests or searches at once. Wait.

A search that works but finds nothing may be the role's search filter, not a
missing log.

## What to check on a live account

These follow Sumo Logic's documentation, but were tested only against
stand-ins:

- whether a search through the API spends credits on a credit-based plan;
- that searching works with a role holding **Create Access Keys** alone.
  Sumo Logic's Search Job API page lists **Manage Access Keys** as the
  capability it needs. Should searches be refused without it, give it only
  with a key whose Custom scope is **Run Log Search** alone, so the key still
  cannot manage anyone's keys.
