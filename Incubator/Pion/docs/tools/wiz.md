---
guides: [setup]
---

# Wiz

The **Wiz** tool reads one Wiz tenant's security graph: the cloud security
issues Wiz found, by severity and status, with the resource each concerns, and
read-only queries over the graph for anything else, such as cloud resources.
Watching the tool wakes its agents for new open critical and high issues. It
only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Wiz limits what Pion can do

Pion reaches Wiz's GraphQL API as a **service account**, with its client ID and
client secret. It keeps them in this Mac's Keychain, exchanges them for a
short-lived token at `auth.app.wiz.io`, and sends that token as
`Authorization: Bearer <token>`, only to the tenant's API at
`api.<data center>.app.wiz.io`. To revoke it, delete the service account, or
rotate its secret, under **Settings › Access Management › Service Accounts**.

A service account reaches only its **scopes**, and only its **projects**. Give
it these, which only read:

| Scope | What it is for |
| --- | --- |
| `read:issues` | `issues`, and watching for new critical and high issues |
| `read:resources` | queries over cloud resources |

Leave **Projects** empty to read the whole tenant, or choose the projects
agents should see. A query that reads something else, such as vulnerability
findings, needs that thing's own read scope; Wiz refuses it until you add it.
Never give the service account a scope that writes, starting `write:`, or an
admin scope: Pion refuses mutations itself, but the scopes are the stronger
guard.

**The data center** is the part of the tenant's API endpoint after `api.`,
under **User Settings › Tenant**: `https://api.us17.app.wiz.io/graphql` is
`us17`. A wrong one cannot be reached, or refuses the token.

## Setting it up

1. **Make the service account.** In Wiz, open **Settings › Access Management ›
   Service Accounts**, choose **Add Service Account**, and choose the type
   **Custom Integration (GraphQL API)**.
2. **Give it only the scopes above**, and the projects agents should see.
3. **Add the tool** with the **Client ID**, the **Client Secret**, shown only
   once, and the data center.

Then ask an agent to run **check-access**.

## What agents can do

- `issues` lists issues by severity, status and when they were raised, up to
  100, open and in progress unless asked, each with the rule that raised it
  and the resource, cloud and subscription it concerns.
- `query` runs a GraphQL query over the graph and returns its data, cut at
  4,000 characters. Pion refuses any document that holds a mutation or
  subscription.
- `check-access` tries each scope once; see below.

## When something does not work

Ask an agent to run **check-access**. It asks Wiz for one issue and one cloud
resource, only their IDs, and says, a line each, whether each works and, if
not, the scope to give or what else to change:

- **"did not accept the service account's token"**: the secret is wrong or was
  rotated, the service account was deleted, or the data center is not the
  tenant's.
- **"Wiz refused it ... give the service account"** a scope: add that scope.
- **"could not reach the Wiz API at this data center"**: check the data
  center.

## What to check on a live account

Wiz's API documentation is open only to its customers. These follow what Wiz
publishes for integrations, but were tested only against stand-ins:

- the names of the scopes, and that `read:resources` lets a query read cloud
  resources;
- how Wiz says a scope is missing: Pion reads it from the errors in the
  answer;
- that tenants in every data center sign in at `auth.app.wiz.io`.
