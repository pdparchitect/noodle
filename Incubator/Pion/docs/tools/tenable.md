---
guides: [setup]
---

# Tenable

The **Tenable** tool reads what Tenable Vulnerability Management knows of an
asset: find it by IP address, with its hostnames, operating system and when it
was last seen, and its vulnerabilities by severity. Agents use it to judge how
exposed a host in an incident was. It only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Tenable limits what Pion can do

Pion reaches Tenable Vulnerability Management at `cloud.tenable.com` with a
user's **API keys**: an access key and a secret key. It keeps them in this
Mac's Keychain and sends them as `X-ApiKeys: accessKey=…;secretKey=…`, only to
`cloud.tenable.com`. To revoke them, generate new keys for the user, or turn
off its API access.

The keys reach what their **user** may, so the user's role and access are what
limit Pion. Give Pion a user of its own, such as `pion@example.com`:

| Setting | What to give |
| --- | --- |
| **Role** | **Basic**, the least role that reads the asset workbench and an asset's vulnerabilities. |
| **Access** | **Can View** on the assets agents should investigate, through an access group or a permission. Leave out **Can Scan**. |

Don't give it **Scan Operator**, **Standard**, **Scan Manager** or
**Administrator**: they can start scans or change Tenable, which Pion never
does. check-access says when the user's role is above **Basic**.

**Generating keys replaces the old ones.** Each user has one pair at a time:
generating a new pair, or another administrator doing it, stops the pair Pion
has.

**Limits.** Tenable limits how fast each pair of keys may send requests, and
refuses the rest for a while. A lookup sends two requests: one to find the
asset, one for its vulnerabilities.

## Setting it up

1. **Make the user.** In Tenable Vulnerability Management, open **Settings ›
   Access Control › Users** and create a user for Pion with the **Basic** role,
   and give it **Can View** on the assets through an access group.
2. **Generate the keys.** Open that user, choose **API Keys › Generate**, and
   copy the **Access Key** and **Secret Key**.
3. **Add the tool** with both keys.

Then ask an agent to run **check-access**.

## What agents can do

- `asset-vulnerabilities` finds the asset at an IPv4 address, seen in the last
  30 days or as many as asked, up to 180, and lists its medium and worse
  vulnerabilities, worst first. An address Tenable has no asset for is a
  finding: the result says so.
- `check-access` tries the keys once; see below.

## When something does not work

Ask an agent to run **check-access**. It searches the asset workbench once for
`192.0.2.1`, an address reserved for documentation that no asset has, and
says whether that works and, if not, what to change. Where Tenable still
answers it, it also says whose keys they are and the user's role.

- **"did not accept the keys"**: they are wrong, were replaced by a new pair,
  or the user is disabled or lost API access. Generate new keys.
- **"may not read this"**: give the user **Basic** or higher, with **Can
  View** on the assets.
- **"rate limiting"**: wait before trying again.

A lookup that finds no asset at an address the user should see may be its
access, not a missing asset: check the user's access group.

## What to check on a live account

These follow Tenable's documentation, but were tested only against stand-ins:

- that Tenable still says whose keys they are and the user's role, which its
  current documentation no longer lists; check-access leaves that line out
  when it does not;
- that the asset workbench shows only the assets the user's access group
  allows.
