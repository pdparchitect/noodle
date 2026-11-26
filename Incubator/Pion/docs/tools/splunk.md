---
guides: [setup]
---

# Splunk

The **Splunk** tool searches one Splunk deployment, Splunk Cloud Platform or
Splunk Enterprise, with SPL. Agents use it to find the logs and events behind
an incident: failed sign-ins from an address, what a host did around a time,
which users a source touched. It only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Splunk limits what Pion can do

Pion reaches Splunk's REST API with an **authentication token** made for one
Splunk user. It keeps the token in this Mac's Keychain and sends it as
`Authorization: Bearer <token>`, only to the host you give, over `https` on
port **8089**, Splunk's management port. To revoke it, delete the token under
**Settings › Tokens**.

The token reaches whatever that user's **roles** allow, so the role is what
limits Pion. Splunk has no read-only token: a token of an admin can do
everything the admin can. Give Pion a user of its own with a role made for it:

| Role setting | What to give |
| --- | --- |
| **Capabilities** | `search` only. Leave out everything that writes or changes Splunk or its users: `delete_by_keyword`, `run_collect`, `run_mcollect`, `run_sendalert`, `run_dump`, `run_custom_command`, `schedule_search`, `admin_all_objects`, `change_authentication` and every `edit_` capability, such as `edit_user` and `edit_roles`. |
| **Indexes** | only the indexes agents should read, such as `auth` or `firewall`. Don't give it **All non-internal indexes** or `*`. |
| **Inheritance** | none, or a role that adds nothing beyond the above. |
| **Resources** | keep the role's limits on searches at once and on search time low; a role made for Pion can keep them as Splunk's `user` role has them. |

Give the token an **expiry date**, and make a new one before it ends.

**The role is what keeps searches to reading.** Pion also refuses, before
sending anything, a search that uses a command that writes or sends data, or
runs a search Pion cannot read first: `delete`, `outputlookup`, `outputcsv`,
`outputtext`, `collect` and `summaryindex`, `mcollect`, `meventcollect`,
`tscollect`, `sendemail`, `sendalert`, `script`, `run`, `runshellscript`,
`dump`, DB Connect's `dbxquery`, `dbxoutput` and `dbxlookup`, which can run
any SQL on a database, `map`, `savedsearch` and `fit`. It refuses every
**macro**, written between backticks, as a macro can expand to any of these:
agents write out the search a macro stands for instead. But apps can add
commands of their own that write or reach out, which Pion cannot know, so a
role without the capabilities above, `run_custom_command` among them, is the
guard that holds.

**Splunk Cloud Platform.** Its REST API is closed until you open it: add this
Mac's public IP address to the `search-api` allow list with the Admin Config
Service, or ask Splunk Support to. Free trials have no REST access at all.

**Splunk Enterprise.** Pion reaches the management port over `https` and
checks its certificate, so a deployment with Splunk's own default certificate
is refused until it has one this Mac trusts.

## Setting it up

1. **Open the API** to this Mac, on Splunk Cloud Platform.
2. **Make the role** under **Settings › Roles**, as in the table above, and a
   user for Pion with that role alone, such as `pion`.
3. **Make the token.** Under **Settings › Tokens**, turn on token
   authentication if it is off, choose **New Token** for that user, and give it
   an expiry date.
4. **Add the tool** with the token and the host only, such as
   `acme.splunkcloud.com`.

Then ask an agent to run **check-access**.

## What agents can do

- `search` runs an SPL search once and returns its results, up to 500, over
  the last 24 hours unless the search gives another time range. Agents name
  the index and end with `head`, `stats` or `table` to keep results small.
  Each search counts against the role's limits like any other.
- `check-access` says whose token it is and what it may search; see below.

## When something does not work

Ask an agent to run **check-access**. It sends two reads and says, a line each:

- whether Splunk takes the token, whose it is and the user's roles;
- whether the roles may search, and which indexes, from one search of index
  metadata that reads no events;
- capabilities the roles hold that write or change Splunk, which searching
  never needs, such as `run_collect`, `run_custom_command` or any `edit_`
  capability.

What its lines mean:

- **"did not accept the token"**: the token is wrong, expired or deleted, or
  token authentication is off. Make a new one.
- **"lack the search capability"** or **"may search no index"**: change the
  role as in the table above.
- **"could not reach the REST API on port 8089"**: on Splunk Cloud Platform,
  add this Mac's address to the `search-api` allow list.
- **"turning searches away"**: the role's limit of searches at once is
  reached. Wait, or raise it.

## What to check on a live account

These follow Splunk's documentation, but were tested only against stand-ins:

- that a role's `eventcount` search lists only the indexes the role may
  search, as check-access reads it;
- that a token made under **Settings › Tokens** is taken as
  `Authorization: Bearer` on Splunk Cloud Platform's management port.
