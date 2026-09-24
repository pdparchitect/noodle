# Connect tools

1. Open **Settings → Tools → Add Tools**.
2. Choose a service, or **Custom MCP…** to enter the web address of a service
   not in the list.
3. Complete sign-in in your browser.
4. Add the connection under **Tools** when creating or editing a bot, then save.

**New Tool…** in the bot's tool picker opens the same flow. Connections are saved
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
Services that ask you to paste an API key, token or client secret, or that run
as a program on your Mac, are not supported. Providers may restrict accounts or
plans.

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
