---
name: update-message-catalogue
description: Procedure for changing Noodle's message/event catalogue or messaging contract. Use when adding or editing a message or event case, its handling guidance, recipients, payload fields or CLI command usage in MessengerDocumentation.swift, or when docs/message-reference.md drifts and a build or test fails on it.
---

# Message and event documentation

Keep message/event guidance in `Sources/NoodleCore/MessengerDocumentation.swift`.
Runtime enums, group notices, and CLI dispatch use the catalogue. Agent runtime
instructions, the Messenger skill, and CLI help are generated from this source.

## Adding or changing a case

New cases must include:

- handling guidance
- recipients
- relevant payload fields or command usage

## After changing the catalogue or messaging contract

1. Regenerate the reference:

   ```sh
   swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md
   ```

2. Include the generated `docs/message-reference.md` in the same change. Do not
   edit that reference by hand.
3. Update encoding-coverage tests when payload fields change.

Builds and tests check for drift.
