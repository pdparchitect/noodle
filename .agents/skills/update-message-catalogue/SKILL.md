---
name: update-message-catalogue
description: Procedure for changing Noodle's message/event catalogue or messaging contract. Use when adding or editing a message or event case, its handling guidance, recipients, payload fields or CLI command usage in MessengerDocumentation.swift.
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

1. Run the catalogue tests:

   ```sh
   swift test --disable-sandbox --filter MessengerDocumentationTests
   ```

2. Update encoding-coverage tests when payload fields change.

There is no generated copy of the catalogue to regenerate. Do not paste its text
into a guide; link to the source or to `messenger --help`.
