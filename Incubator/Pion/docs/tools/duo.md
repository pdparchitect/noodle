---
guides: [setup]
---

# Duo

Pion has two Duo tools, each added per Duo account with keys of its own:

- **Duo Detection** reads an account the way a defender does: the
  authentication log, with where each attempt came from and the device that
  approved it; what administrators changed; the SMS and calls Duo sent; one
  user's status, devices and bypass codes; and, to audit how the account is
  set up, its users, administrators, applications, phones, policies, bypass
  codes and global settings. It wakes the agents it is assigned to when users
  report fraud, Duo denies attempts from where it should not be reached, or
  administrators open a way around Duo. It only reads.
- **Duo Containment** acts on the same account to contain an identity: it
  disables a user or restores them, takes a user out of bypass status, deletes
  their bypass codes, removes a phone, hardware token or security key from
  them, and sends a new enrollment or Duo Mobile activation link. Every one of
  these waits for your approval.

The quick steps are under **Setup Steps** in **Settings → Tools**. This guide
explains them.

The pages they use, in the Duo Admin Panel:

- **Applications › Application Catalog**, to add each tool's Admin API
  application, and **Applications**, to set its permissions.
- **Users**, **Phones** and **2FA Devices**, to see what the tools read and
  change.
- **Reports › Authentication Log** and **Reports › Administrator Actions**, to
  see the logs the tools read.

## How Duo limits what Pion can do

Duo's [Admin API](https://duo.com/docs/adminapi) has **no OAuth and no
sign-in**. Each tool uses an Admin API application you make in the Admin Panel,
which has three details: its **API hostname**, such as
`api-xxxxxxxx.duosecurity.com`, an **integration key** and a **secret key**.
The keys do not expire. Pion keeps them together in this Mac's Keychain and
never sends the secret key: it signs each request with it, as Duo asks, over
the request's time, method, address and contents, so a request cannot be
replayed for anything else. To revoke the keys, delete the application in Duo,
or choose **Reset Secret Key** on it.

What an application may do is set by the **permissions** ticked on it:

| Permission | What it lets the keys do | Duo Detection | Duo Containment |
| --- | --- | --- | --- |
| Grant read log | Read the authentication, administrator and telephony logs, and Trust Monitor | Yes | No |
| Grant resource - Read | Read users, their devices and bypass codes, phones, applications and policies | Yes | Yes |
| Grant administrators - Read | Read administrators and their roles | For `admins` | No |
| Grant read information | Read the account's edition and size | For check-access | No |
| Grant settings | Read **and change** the global settings | Only for `settings` | No |
| Grant resource - Write | Change and delete users, devices and bypass codes | No | Yes |

Duo has **no read-only form of Grant settings**: it also lets the keys change
the global settings. Duo Detection only reads them, but leave it off unless you
want the settings audited. Leave every other permission off, above all
**Grant applications**, **Grant administrators - Write** and **Grant set Admin
API permissions**, which would let the keys make new keys or change
administrators.

Only an administrator with the **Owner** role can make or change an Admin API
application.

Both tools reach only the API hostname you give, and Pion refuses one that is
not Duo's (`api-….duosecurity.com`, or `api-….duofederal.com` for Duo
Federal) before sending anything.

## Setting it up with least access

1. **Make Duo Detection's application.** Signed in as an Owner, open
   **Applications › Application Catalog**, find **Admin API** and choose
   **+ Add**. Name it **Pion Detection**, kept for this tool alone.
2. **Set its permissions.** Tick only **Grant read log** and **Grant resource -
   Read**. Add **Grant administrators - Read** to audit administrators and
   **Grant read information** for the account summary. Add **Grant settings**
   only if you want the global settings audited, knowing it can change them.
   Under **Networks for API access** you can limit the application to the
   networks this Mac uses. Save.
3. **Add the tool** with the **API hostname**, the **Integration key** and the
   **Secret key**, and choose **Add & Connect**.
4. **For Duo Containment**, make a second Admin API application, such as
   **Pion Containment**, with only **Grant resource - Read** and **Grant
   resource - Write**, and add Duo Containment with its own keys. Keeping the
   two apart keeps Duo Detection's keys read-only.

Then ask an agent to run **check-access** on each.

## Coverage you should know

- **Duo keeps logs for 180 days.** Pion refuses a search reaching further back.
- **New authentications appear about two minutes late.** Duo holds them back
  on purpose; a search ending now may not show the last two minutes yet.
- **Duo asks that each log be read at most about once a minute**, and rate
  limits more. When it does, Pion tries again after a short pause; if Duo still
  refuses, the answer says so. `auth-logs` and `telephony-logs` read one page a
  call, up to 1,000 entries, and give the offset to read on from.
- **The administrator log gives its 1,000 earliest entries from a time.**
  `admin-logs` says when more follow and from when to read on.
- **IP addresses are matched within the page read.** Duo's authentication log
  cannot be searched by IP address, so `auth-logs` matches it among the
  attempts it read and says so.
- **Device health is Premier and Advantage only.** Whether a phone is
  jailbroken, encrypted, locked or uses biometrics shows only on those
  editions, and only for activated Duo Mobile. Where and on what an attempt
  came from (the access device) shows only for applications that use Duo's
  browser prompt, also only on those editions.
- **Trust Monitor is Premier and Advantage only.** On other editions Duo
  refuses it, and the watch reads the logs without it.
- **Policies are read as they are now**, through Duo's Policies API. A custom
  policy changes only the sections it sets; the rest follow the global policy.
  If your account has no Policies API, `policies` says so, and you read them
  in the Admin Panel under **Policies**.
- **Administrators**: Duo does not offer its Administrators API to accounts set
  up through Cisco Security Cloud Control after May 11, 2026; `admins` then
  says Duo refused it.
- **Listings read up to ten pages**, such as 3,000 users or 5,000 phones, and
  say when more remain.
- **Bypass codes are never shown.** Duo's API gives only when each was made, by
  whom, when it expires and how often it may be used; Pion counts and dates
  them. Applications' secret keys are never shown either.

## What agents can do

- `auth-logs`: the authentication log, newest first, by user, result
  (success, denied or fraud), reason, factor, application and time, with each
  attempt's IP address, location, operating system and browser, and the device
  that approved it.
- `admin-logs`: what administrators and the Admin API changed, by action,
  administrator and the user or object changed, with Duo's description.
- `telephony-logs`: SMS and calls Duo sent, with the number, why, and credits
  used. A burst to one number can mean someone is pushing a user to approve.
- `user`: one user's status (and why locked out), whether enrolled, last login,
  phones with their health, hardware tokens, security keys, groups, and bypass
  codes counted and dated.
- `users`: every user, led by those in bypass status, not enrolled, locked out
  or disabled, then those who never logged in.
- `admins`: every administrator, owners first, flagging those who sign in to
  the Admin Panel without a hardware token or security key.
- `integrations`: every application Duo protects, who may use it and its
  policy, led by Admin API applications that can change Duo, their permissions
  and the networks they may be used from.
- `phones`: every phone, led by those jailbroken or rooted, unencrypted,
  without a screen lock or biometrics, or never activated, and phones that only
  take calls or SMS.
- `policies`: the global and custom policies and the applications each covers,
  led by SMS or phone calls allowed, bypass codes accepted, Duo Push without
  Verified Push, new users let in without a second factor, everyone bypassed,
  networks that skip Duo, browsers remembered for more than a week, jailbroken
  phones or phones without a screen lock allowed, and anonymous networks not
  acted on.
- `bypass-codes`: who holds bypass codes, led by codes that never expire or can
  be used without limit.
- `settings`: the global settings, led by gaps such as a high lockout threshold
  or automatic unlock, no fraud alert email, Help Desk or User Manager
  administrators able to bypass users, users not told when a device is added,
  and users who never enroll never locked out.
- `security-events`: what the alert watch wakes for, for a window. When no
  window is given, the last 24 hours.
- **check-access**: see [When something does not work](#when-something-does-not-work).

## The alert watch

Every five minutes, Duo Detection reads:

- the **authentication log**, for fraud a user reported, and attempts Duo denied
  from an anonymous network, a restricted location or a denied network, for too
  many attempts, or from a jailbroken or rooted phone;
- the **administrator log**, for bypass codes made or viewed, users or groups
  set to bypass status, administrators added or changed, how administrators
  sign in changed, Admin API applications made or their permissions changed,
  any application's secret key viewed, policies and global settings changed,
  phones added to users by administrators, Admin API requests from networks not
  allowed, and administrators locked out;
- **Trust Monitor**, where the edition has it, for what it surfaced.

It wakes the agents with a note naming `security-events`. A log it cannot read,
such as one refused for want of a permission, is told once, and
`security-events` says why. When Duo rate limits it, the next check reads the
same again.

Not watched: successful logins, even with a bypass code or from somewhere new,
which `auth-logs` finds; denials for other reasons, such as a wrong passcode
or a push not answered; users and devices added or removed; and calls and SMS,
which `telephony-logs` reads.

## When something does not work

Ask an agent to run **check-access**. It tries each thing the tool reads once
and says, for each that fails, which permission to tick; says whether the
edition has Trust Monitor; and lists the Admin API applications that can change
Duo, so you can see whether this tool's own is among them. Pion cannot tell
which application its keys belong to. Duo Containment's check-access also tests
whether its keys may change users, by sending a change to a user that does not
exist, which Duo can only refuse.

- **"Duo did not accept the request's signature"**: the integration key or
  secret key is wrong or was reset, the application was deleted or is not an
  Admin API application, or this Mac's clock is more than a few minutes off.
- **"the Admin API application lacks …"**: tick that permission on the
  application, as an Owner. If it is ticked, check **Networks for API access**.
- **"is not one of Duo's"**: the API hostname is mistyped; it looks like
  `api-xxxxxxxx.duosecurity.com`.

## Containing an incident

Read the user with `user` first, and record it as evidence. Give each user by
their exact Duo username or user ID; Pion does not act on an alias.

- `disable-user` makes Duo deny every login of the user, whatever their devices
  or bypass codes. `enable-user` sets a disabled or locked-out user active again.
- `clear-bypass` takes a user out of bypass status, so Duo asks for their
  second factor again. A group in bypass status still overrides it; the result
  names such groups.
- `delete-bypass-codes` deletes every bypass code the user holds.
- `remove-phone`, `remove-token` and `remove-security-key` take one device away
  from the user, by the ID `user` lists. A removed phone stays in Duo and can be
  given back; a removed security key must be registered again.
- `send-enrollment` emails a user with no devices left a single-use enrollment
  link, and `send-activation` texts one of their phones a new Duo Mobile
  activation link. Whoever opens the link enrolls, so send them only once the
  mailbox or phone is known to be the user's.

**Duo cannot end sessions** the applications it protects already hold, and its
Admin API has no way to log a user out: end those in each application.
**Duo refuses to disable a user a directory sync manages**, such as from Active
Directory or Entra ID; disable them in the directory instead.

Each result says what changed, what did not and how to undo it. Duo takes no
condition on a change, so the result also says when the user was read: another
administrator may have changed them in between.
