# Sentry

Pion has two Sentry tools, each added per Sentry organisation with a sign-in of
its own:

- **Sentry**, for Sentry's own service at `sentry.io`, in the United States or
  European Union region.
- **Self-Hosted Sentry**, for a Sentry you run, version 26.2.0 or later.

Both read the same things: the organisation's projects, its issues by search,
project and period, and an issue's latest event, with its exception, the frames
in the service's own code, the request, the user and its tags. They only read.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Sentry limits what Pion can do

There is no token to make, copy or keep. Both tools sign in as you, with a
code: Pion shows a code and opens Sentry, where you enter it, choose the
organisation and approve what Pion asks for. This is OAuth's device flow.
Pion signs in through a **public API application** you register in Sentry,
which keeps no client secret. Sentry takes only `http` and `https` redirect
addresses, which cannot send a sign-in back to a Mac app, so Pion uses the code
and no redirect at all.

The application belongs to **your own Sentry account**, not the organisation.
If your account is removed from Sentry, the application goes with it, and the
tool must be set up again by someone else.

The sign-in reaches **only the organisation you choose** when approving the
code, and only what your role and teams there may see. Pion asks for these
scopes, all of which only read, and refuses a sign-in that lacks any:

| Scope | What it is for |
| --- | --- |
| `event:read` | `issues` and `issue-event`: searching issues and reading an issue's latest event |
| `org:read` | `projects`: the organisation's project list |

Pion asks for nothing that changes Sentry. It does not read the organisation's
audit log, which Sentry gives only to `org:write`, a scope that can change the
organisation's settings.

The sign-in lasts 30 days, and Pion renews it on its own with a refresh token,
which Sentry replaces each time. Sentry documents no way to revoke a sign-in
through OAuth, so **Sign Out** in **Settings → Tools** forgets it on this Mac;
to revoke it at Sentry, open **User Settings › Authorized Applications** and
revoke the application, or delete it under **User Settings › API
Applications**.

**Where Pion goes.** Sentry signs in at `https://sentry.io`, and Pion reads
from the region's own host, `sentry.io` or `de.sentry.io`. A Self-Hosted Sentry
signs in, and is read, at the host you give, only over `https` on the default
port; a host with a port, or plain `http`, is refused. A server on another
port needs a reverse proxy that serves it over `https` on port 443.

## Setting it up

1. **Register the application.** In Sentry, open **User Settings › API
   Applications**, at `/settings/account/api/applications/`, and choose
   **Create New Application**. Name it **Pion**, kept for this tool alone.
2. **Make it public.** Choose **Public**, the type for CLIs and native apps that
   cannot keep a secret. Leave **Authorized Redirect URIs** empty, or give the
   organisation's own website if Sentry asks for one; Pion does not use it.
   Save it and copy its **Client ID**.
3. **Add the tool** with the organisation's slug, such as `kestrel-labs` from
   `kestrel-labs.sentry.io`, and its region; or, for Self-Hosted Sentry, the
   host you open it at, such as `sentry.example.com`, and the slug from any
   page's address, such as `kestrel-labs` in `/organizations/kestrel-labs/`.
   Give the **Client ID**.
4. **Sign in.** Choose **Add & Connect**, enter the code Pion shows in Sentry,
   choose this organisation and approve.

Then ask an agent to run **check-access**.

A Self-Hosted Sentry older than 26.2.0 cannot sign a public application in
with a code: upgrade it first.

## When something does not work

Ask an agent to run **check-access**. It sends only reads and says:

- which organisation it reads, and at which address;
- whether projects, issues and an issue's latest event can be read, and if not,
  which scope each takes and what to change;
- the scopes the sign-in holds, and the application they are granted to.

Any refused call says the same. Sentry does not say why it refused, so a
refusal names the scope the call takes and says the cause may instead be an
organisation other than this one chosen at sign-in, or your role or teams. A
sign-in Sentry no longer accepts, because it expired, was revoked or its
application was deleted, needs signing in again in **Settings → Tools**.

## What to check on a live account

These follow Sentry's documentation and source, but were tested only against
stand-ins:

- that a public application signs in with a code on `sentry.io`, and on a
  Self-Hosted Sentry 26.2.0 or later, at `/oauth/device/code/` and
  `/oauth/token/`, and that the page Sentry gives for entering the code is
  `https`;
- whether the token answer lists the scopes granted, and in what form: Pion
  takes a missing list as the scopes it asked for;
- that the sign-in renews after 30 days with the refresh token, and that the
  replaced refresh token is kept;
- that a sign-in from `sentry.io` reads an organisation in the European Union
  region at `de.sentry.io`;
- what Sentry answers for an organisation other than the one chosen at
  sign-in.
