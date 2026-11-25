# Microsoft Sentinel

**Microsoft Sentinel** queries the logs in the Log Analytics workspace behind
Microsoft Sentinel with KQL, such as SigninLogs, AuditLogs, OfficeActivity,
SecurityEvent and SecurityAlert, and wakes the agents it is assigned to when a
new high-severity Sentinel incident appears. Each account is one workspace. KQL
only reads.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

## How Microsoft limits what Pion can do

It signs in the way Microsoft Entra ID's tools do: in your browser, at your
tenant's own Microsoft sign-in page, through a public client app registration
you make for it. There is no client secret to make, copy or lose: Pion keeps
none and signs in with PKCE, and the sign-in renews itself. Each query runs as
the admin who signed in, with their own roles on the workspace, never an app's.

| API | Delegated permission | Admin's role on the workspace |
| --- | --- | --- |
| Log Analytics API | `Data.Read` | Log Analytics Reader, or Microsoft Sentinel Reader |

`Data.Read` adds no rights of its own: a sign-in may read exactly what the
signed-in admin's roles on the workspace allow. Pion asks for it as
`https://api.loganalytics.io/Data.Read`, with `offline_access` so the sign-in
renews itself; Microsoft never lists `offline_access` among the permissions it
granted, so Pion does not require it back, and refuses a sign-in that lacks the
other.

One sign-in gets tokens for one API. The tool uses only the Log Analytics query
API, at `api.loganalytics.azure.com`, so it needs nothing from Azure Resource
Manager; reading Sentinel's incidents, analytics rules or watchlists through
Azure Resource Manager would need a second tool with a sign-in of its own.

It reaches only `login.microsoftonline.com`, to sign in at the tenant the
account names (never `common` or `organizations`, which Pion refuses), and
`api.loganalytics.azure.com`.

## Setting it up with least access

1. **Register an app**, such as Pion Sentinel, single tenant, in the
   [Microsoft Entra admin center](https://entra.microsoft.com)'s **App
   registrations**. Under **Redirect URI**, choose **Public client/native
   (mobile & desktop)** and give `com.pdparchitect.pion:/oauth2callback` (and
   `com.pdparchitect.pion.local:/oauth2callback` for Pion Dev). Add no client
   secret or certificate.
2. **Add its one permission.** Under **API permissions › Add a permission ›
   APIs my organization uses**, search for **Log Analytics API**, choose
   **Delegated permissions** and add `Data.Read`. Remove Microsoft Graph's
   `User.Read`, which a new app is given, and choose **Grant admin consent**.
3. **Let only its admin sign in.** Under **Enterprise applications**, open the
   app, set **Assignment required?** to **Yes**, and assign only the admin who
   will sign in, such as pion-sentinel@contoso.com, kept for this tool alone.
4. **Give that admin Log Analytics Reader** on the workspace, in the
   [Azure portal](https://portal.azure.com)'s **Access control (IAM) › Add
   role assignment**, or **Microsoft Sentinel Reader**, which reads the same
   logs. Neither can change anything.
5. **Give the Directory (tenant) ID** and the app's **Application (client)
   ID**, from its **Overview**, and the **Workspace ID** from the workspace's
   **Overview**.

Then choose **Add & Connect**, sign in as that admin (Pion asks for the
password every time, so a browser signed in as someone else never answers for
them), and ask an agent to run **check-access**.

## When something does not work

Ask an agent to run **check-access**. It changes nothing, and tries one query
over the workspace and one over SecurityIncident, the table the alert watch
reads, which exists only when Microsoft Sentinel is on for the workspace. It
also names the app the sign-in went through and the permission it asked for.

A refused query says what to change: to sign in again in **Settings › Tools**
when Microsoft no longer accepts the sign-in, or to give the signed-in admin
Log Analytics Reader or Microsoft Sentinel Reader on the workspace and check
the Workspace ID.

## What to check on a live account

These have not yet been tried against a live tenant:

- **The scope's form in the token response.** Pion asks for
  `https://api.loganalytics.io/Data.Read` and checks the token response lists
  it the same way. Should Microsoft list it without the resource in front,
  every sign-in is refused as lacking it, and Pion needs a change in how it
  compares them.
- **Data.Read with workspace roles.** Sign in as an admin holding only Log
  Analytics Reader on the workspace, then only Microsoft Sentinel Reader, and
  run **check-access**: both queries should pass with either.
- **Table-level access.** A workspace that limits some tables to some people
  may leave tables out of what the admin can query, without saying so.
