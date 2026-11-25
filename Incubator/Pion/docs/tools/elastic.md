---
guides: [setup]
---

# Elastic

The **Elastic** tool queries one Elasticsearch deployment, on Elastic Cloud or
your own, with ES|QL. Agents use it to search logs and security events, such
as every event from an address in the last day. It only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Elasticsearch limits what Pion can do

Pion reaches Elasticsearch with an **API key**. It keeps the key in this Mac's
Keychain and sends it as `Authorization: ApiKey <encoded key>`, only to the
host you give, over `https` on the default port. To revoke it, invalidate the
key under **Stack Management › API keys** in Kibana.

An API key reaches what its **role descriptor** allows, and never more than the
user who made it may do. Make it with **Control security privileges** turned
on, and give it only these, on only the indices agents should search:

```json
{
  "pion": {
    "indices": [
      { "names": ["logs-*"], "privileges": ["read", "view_index_metadata"] }
    ]
  }
}
```

| Privilege | What it is for |
| --- | --- |
| `read` | running ES\|QL over the indices and data streams |
| `view_index_metadata` | letting check-access list the indices the key can see |

Give it no cluster privileges, and give it an expiry. A key made without
**Control security privileges** carries all of its maker's privileges: an
administrator's key could then change or delete data, even though Pion's
queries only read.

**The address.** Give the Elasticsearch endpoint's host, not Kibana's; on
Elastic Cloud it is on the deployment's page, such as
`acme.es.eu-west-1.aws.elastic.cloud`. Pion reaches it only over `https` on
port 443, so a deployment of your own that listens on `9200` needs a reverse
proxy that serves it on 443 with a certificate this Mac trusts.

**ES|QL** needs Elasticsearch 8.11 or later, and is generally available from
8.14. An older deployment refuses every query.

## Setting it up

1. **Make the key.** In Kibana, open **Stack Management › API keys**, choose
   **Create API key**, turn on **Control security privileges** and give it the
   role descriptor above, with your own index names, and an expiry.
2. **Add the tool** with the **Encoded** key and the Elasticsearch host.

Then ask an agent to run **check-access**.

## What agents can do

- `esql` runs an ES|QL query and returns its columns and rows. Agents filter by
  time and end with `LIMIT` to keep results small. ES|QL has no command that
  writes.
- `check-access` says whose key it is and what it may read; see below.

## When something does not work

Ask an agent to run **check-access**. It sends only reads and says, a line
each:

- whether Elasticsearch takes the key, its name and the user who made it;
- how many indices and data streams the key can see;
- which of them it may read, and which not;
- whether ES|QL runs, with a query that reads no index.

What its lines mean:

- **"did not accept the API key"**: the key is wrong, expired or invalidated,
  or it was made on another deployment. Make a new one.
- **"may not see index metadata"**: add `view_index_metadata`.
- **"sees no index"** or **"may read none of them"**: add the indices, with
  `read`, to the role descriptor. Recent versions of Kibana let you edit a
  key's privileges; otherwise make a new key.
- **"ES|QL is refused"**: the deployment is older than 8.11, or its licence
  or the key's privileges exclude ES|QL.

## What to check on a live account

These follow Elastic's documentation, but were tested only against stand-ins:

- that an ES|QL query that reads no index, `ROW ok = 1`, runs for a key with
  only index privileges;
- that the privileges check answers for an API key, giving the key's own
  privileges rather than its maker's.
