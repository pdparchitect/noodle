# Chat effects

Agents can trigger a brief visual celebration in a direct or group conversation they belong to:

```sh
./.agents/skills/messenger/messenger --list-effects
./.agents/skills/messenger/messenger --effect confetti --conversation <conversation-uuid>
```

`--list-effects` returns `["confetti"]`. The effect command returns a JSON receipt with `status` and `effect` (including its ID, sender, conversation, creation time, and expiry). A successful receipt means **queued**, not necessarily displayed. Retry with the same optional `--request-id <uuid>` to avoid duplicate effects while that ID remains in the bounded queue.

## Playback

- Plays only in the selected, foreground chat, without opening or switching conversations. Settings windows and sheets do not trigger playback in a chat behind them.
- Expires after 30 seconds. Reopening a conversation does not replay consumed effects. Several pending effects coalesce into the newest one.
- Confetti lasts four seconds, stays inside the chat, and never intercepts clicks or changes transcript layout. Reduce Motion uses a still celebration badge instead.
- Effects are independent of messages and emoji reactions: no transcript entry, unread marker, sidebar reorder, or agent wake-up.
- Send at most one effect per conversation every two seconds. Use sparingly for meaningful results.

## Storage and extension points

Each conversation has an optional, versioned `effects.json` queue with a separate `.effects.lock`. Cross-process locking and atomic writes protect producers and consumers. The queue retains at most 32 events for up to five minutes; retry IDs are not permanent deduplication keys. Claiming happens before rendering, so a crash or focus change can drop a claimed effect rather than replay it.

To add an effect, add its stable name to `ConversationEffectKind` and a renderer to `ConversationEffectsView`, including a reduced-motion alternative. The CLI catalogue updates automatically. Effect names are data, never executable code; unknown future kinds are skipped by older readers. No new entitlements, network service, or external dependency is required.

## Verification

The isolated implementation build passes 95 core tests, including 11 effect tests, and the signed bundle passes strict signature, updater, and Agent Host verification. Its executable links only Apple libraries/frameworks and bundle-relative Sparkle. The [existing security boundary](security.md#security-boundary) is unchanged: App Sandbox, selected-file read access, outgoing network, the `S8VNVK39LH.com.pdparchitect.noodle.sharing` group, the `/.codex/` home-relative exception, and exactly the `com.pdparchitect.noodle-spks` / `com.pdparchitect.noodle-spki` IPC exceptions. Messenger remains separately signed; the previously approved Agent Host and Sparkle installer boundaries are unchanged. No installed app was replaced for this verification.

[Storage and Messenger](storage-and-messenger.md) · [Documentation](README.md)
