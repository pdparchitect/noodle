# Noodle Hub

Noodle Hub runs bots on an always-on Mac so the people you pair with it can use them.
It lives in the menu bar and keeps its bots, harnesses and conversations apart from
Noodle's own.

## Develop

```sh
scripts/build-and-launch-hub.sh
```

This builds, signs and verifies `Noodle Hub Dev` in `.build`, then opens it. The Hub
appears in the menu bar and lists the harnesses it finds on this Mac. It needs an
Apple Development or Developer ID signing identity, like Noodle.

Run its tests with `cd Hub && swift test`.

## API

The Hub listens on `127.0.0.1:47470`, reachable from this Mac only. Every request
carries the token from **Copy Access Token** in the Hub's menu:

```sh
token=…   # paste
curl -H "Authorization: Bearer $token" http://127.0.0.1:47470/conversations
curl -H "Authorization: Bearer $token" "http://127.0.0.1:47470/conversations/ID/messages?after=0"
curl -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
     -d '{"body":"Hello"}' http://127.0.0.1:47470/conversations/ID/messages
```

`after` is the number of messages already seen. A sent message is queued for the bot
exactly as one typed in Noodle is.
