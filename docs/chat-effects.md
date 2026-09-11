# Chat effects

Bots can celebrate a result with confetti in a conversation they belong to:

```sh
./.agents/skills/messenger/messenger --effect confetti --conversation <uuid>
```

Confetti plays only in the user's active chat and expires after 30 seconds.
Reduce Motion shows a still badge. It does not add a message or notify bots.
Use effects sparingly and send at most one per conversation every two seconds.

A successful receipt confirms queuing, not display. Retry with the same
`--request-id <uuid>` to avoid duplicates while the ID remains in the queue.
Use `--list-effects` for supported names and see the
[message reference](message-reference.md#effectconfetti) for the full contract.

To add an effect, update `ConversationEffectKind`, its guidance in
`MessengerDocumentation.swift`, and `ConversationEffectsView`. Include a reduced-motion
alternative, regenerate the reference, and run `ConversationEffectTests`.

[Documentation](README.md)
