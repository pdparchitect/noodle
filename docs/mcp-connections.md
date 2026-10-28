# Connect tools

1. Open **Settings → Tools → Add Tools**.
2. Choose a service, or **Custom MCP…** to enter the web address of a service
   not in the list.
3. Complete sign-in in your browser.
4. Add the connection under **Tools** when creating or editing a bot, then save.

**New** in the bot's tool picker opens the same flow. Connections are saved
separately; cancelling the bot editor leaves the connection unassigned.

## Accounts and permissions

Add separate, clearly named connections for different accounts. Each has its own
sign-in. Reconnecting can change the account while keeping bot assignments.
Editing a connection's instructions affects every bot assigned to it.

Assigned bots can use the permissions you approved at sign-in without asking you
again for each use. Noodle must remain open. Removing an assignment stops future
access; removing a connection deletes its sign-in from this Mac. Revoke access at
the provider too when needed. If a change timed out, check whether it happened
before trying again.

## Supported services

Custom connections must be services that sign you in through your browser.
A service that asks you to paste an API key into the address is not supported.
Providers may restrict accounts or plans.

## A program on this Mac

Settings → Tools → Program on this Mac starts a program for you and talks to it
over its standard input and output. You enter the executable and each argument
in its own field. Noodle does not run a shell command, and it does not download
or start anything while you are only adding or looking at the program.

Before it runs, Noodle shows the program's full path, its arguments, the folder
it runs in, and the macOS account that Noodle itself is using. That program runs
as that account, outside any agent's sandbox, and it can read that account's
files. The app does not start it in the app sandbox. A helper that accepts only this app starts it. Tool output it returns reaches the agents you assign. If the command can
download code, such as `npx -y`, the approval says so. Prefer a pinned version.

Environment values, such as `OPENAPI_MCP_HEADERS` for Anytype, are stored in
the macOS login keychain. Noodle gives them only to that program. They are not
written into the program record, the approval, a log, or a bot's instructions.
Anytype's own API address is the program's setting, not an MCP address Noodle
connects to. A server you already run on this Mac is a different connection,
and this change does not add it.

Noodle starts the program the first time an assigned agent uses it, stops it
after 15 minutes without use, when you remove it, and when Noodle quits. If it
crashes, Noodle starts it again up to three times, waiting longer each time,
and then leaves it stopped. Only agents you assign can call it. An agent on
another computer uses it through Noodle on this Mac.

Some connections, such as Pipedream, give access to several services at once.
Assigning one to a bot grants access to all of them; check the intended service
and account before acting. For Pipedream, choose its entry in the list and
complete any extra account steps in your browser. Zapier is not in the list and
cannot be added.

### Google Workspace (Experimental)

Each service is a separate connection, and you can connect several accounts:

| Service | What bots can do |
| --- | --- |
| Gmail | Read mail, create drafts, manage labels. Bots cannot send mail. |
| Google Docs | Read and edit documents; use Drive to find or create them. |
| Google Drive | Find, read, download, create and copy files. |
| Google Calendar | Find availability and manage events and invitations. |

The preview works only for accounts that have been added as testers. Sign-ins
expire after seven days, and you must reconnect after permissions change.
Revoking Noodle's Google access may affect that account's other Google
connections in Noodle. Drive can change only files made available to Noodle, and Google's
[file eligibility rules](https://developers.google.com/workspace/drive/api/guides/drive-mcp-server-file-eligibility)
may restrict access further.

[Agent access](security.md) · [Documentation](README.md)
