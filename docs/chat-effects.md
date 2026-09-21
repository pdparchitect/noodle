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
Use `--list-effects` for supported names; `messenger --help` has the full contract.

To add an effect, add its kind, its guidance in the message catalogue, and its
animation in the conversation effects view. Include a reduced-motion alternative
and run `ConversationEffectTests`.

[Documentation](README.md)
