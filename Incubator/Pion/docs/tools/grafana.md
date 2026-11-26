---
guides: [setup]
---

# Grafana

Pion has two Grafana tools, each added per Grafana with a token of its own:

- **Grafana Cloud**, for a stack on Grafana Cloud, such as `acme.grafana.net`.
- **Self-Hosted Grafana**, for a Grafana you run: on this Mac, on the local
  network, or anywhere over `https`.

Both read the same things: dashboards and the queries behind their panels,
queries over a data source, the alerts Grafana is firing, and annotations such
as deploys. Agents use them to see what metrics and logs showed around an
incident. They only read.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Grafana limits what Pion can do

Pion reaches Grafana's HTTP API with a **service account token**. It keeps the
token in this Mac's Keychain and sends it as `Authorization: Bearer <token>`,
only to the address you give. To revoke it, delete the token or the service
account under **Administration › Users and access › Service accounts**.

A token reaches what its **service account's role** allows, in the one
organisation the service account belongs to. Give it the **Viewer** role:

| What Pion reads | What Viewer gives |
| --- | --- |
| Dashboards and their panels | the dashboards and folders it may see |
| Queries over a data source | queries over the data sources it may see |
| Firing alerts | reading alert instances |
| Annotations | reading annotations |
| The list of data sources | often not: see below |

Don't give it **Editor** or **Admin**: Pion never needs them.

**Listing data sources.** Recent Grafanas let Viewer query data sources but not
list them. When agents cannot list them, they take each data source's UID from
a dashboard's panel instead, which is enough to query it. To let them list
data sources too, give the service account a role that adds
`datasources:read`, where your Grafana has custom roles.

**What a query reaches.** A query runs with the data source's own connection,
not the service account's, so it reaches whatever that data source's database
user may, and Viewer does not limit it. **The real guard is a read-only
database user**: make sure every data source agents may query connects as a
user that can only read, such as one granted only `SELECT` on what it needs.
Grafana Cloud and Grafana Enterprise can also keep the service account out of
a data source with data source permissions.

Pion checks each query before sending it, as a second guard behind that user:

- **SQL** (PostgreSQL, MySQL, Microsoft SQL Server, ClickHouse): one
  `SELECT`, `WITH`, `SHOW` or `EXPLAIN` statement, with no comment and no
  second statement. It refuses one holding, anywhere outside quoted text, a
  word that changes data, rights or the database, such as `INSERT`, `UPDATE`,
  `DELETE`, `MERGE`, `CREATE`, `DROP`, `GRANT`, `COPY`, `CALL`, `EXEC`,
  `INTO` (as in `SELECT … INTO`), `LOCK`, `SET` or `LOAD`, or a function known
  to change something or run text as SQL, such as `setval` or `dblink_exec`.
  So a `WITH` whose first part deletes is refused too. It cannot know every
  function a database has, which is why the read-only user matters.
- **InfluxQL**: no `INTO`, `DROP`, `DELETE`, `CREATE`, `ALTER`, `GRANT`,
  `REVOKE`, `KILL` or `SET`, and no comment.
- **Flux**: no `to()` or `wideTo()`, which write, and no import but packages
  that only work on what was read, such as `strings`, `math` or `date`, so
  nothing like `experimental.to`, `sql.to` or `http.post` is reached.
- **Prometheus, Loki, Tempo, Jaeger, Zipkin, Elasticsearch, OpenSearch,
  Graphite, CloudWatch, Google Cloud Monitoring, Azure Monitor and
  Pyroscope**: their query languages only read, so queries go as they are.
- **Any other kind of data source** is refused, as Pion cannot tell whether
  its queries only read. So is a data source whose kind Grafana does not say.

Pion learns a data source's kind from Grafana before each query.

**The address.** Grafana Cloud is always `https`. A Self-Hosted Grafana is
reached at the address you open it at, with any path it is served under, such
as `https://grafana.example.com/grafana`; plain `http` works only on this Mac
or the local network, so a token never crosses the internet in the clear.

## Setting it up

1. **Make the service account.** Open **Administration › Users and access ›
   Service accounts**, choose **Add service account**, name it **Pion** and
   give it the **Viewer** role.
2. **Add a token.** Choose **Add service account token**, give it an expiry
   date, and copy it; it is shown only once.
3. **Check each data source's database user.** Every data source agents may
   query should connect as a user that can only read.
4. **Add the tool** with the token and the stack's host, or your Grafana's
   address.

Then ask an agent to run **check-access**.

## What agents can do

- `dashboards` finds dashboards by title or tag, and `dashboard` shows a
  dashboard's panels, each with its data source and the queries behind it.
- `data-sources` lists data sources with their UIDs and types, where the role
  allows it.
- `query` runs one query over a data source and a time range, in the data
  source's own language, such as PromQL or LogQL, and returns rows. It refuses
  a query that could write, and data sources of a kind it cannot check, as
  above.
- `alerts` lists the alerts Grafana is firing now, and `annotations` the
  annotations over a time range.
- `check-access` tries each read once; see below.

## When something does not work

Ask an agent to run **check-access**. It sends only reads and says, a line
each:

- whether Grafana takes the token, and which organisation it belongs to;
- whether dashboards, data sources, firing alerts and annotations can be read,
  and for each refused, the permission it takes.

It does not try a query, which needs a data source and a query of its own.

What its lines mean:

- **"did not accept the token"**: the token is wrong, expired or deleted, or
  the service account is disabled. Add a new token.
- **"may not list data sources"**: expected with Viewer; see above.
- **"may not read"** alerts or annotations: give the service account Viewer,
  or a role with `alert.instances:read` or `annotations:read`.
- **"could not reach Grafana"** or **"does not offer this at this address"**:
  check the address, with any path Grafana is served under.

## What to check on a live account

These follow Grafana's documentation, but were tested only against stand-ins:

- that Viewer is refused the list of data sources on your Grafana's version,
  and still queries a data source by its UID;
- that the current organisation reads with a service account token, as
  check-access's first line does;
- that a service account refused a data source's own settings still learns its
  kind from the settings Grafana gives its pages, and an InfluxDB data source's
  query language, InfluxQL, Flux or SQL, with it.
