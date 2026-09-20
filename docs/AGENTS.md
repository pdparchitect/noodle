# Documentation

**NOTE: Everything in `docs/` must be public-facing documentation for Noodle
users, integrators, or contributors.** Write for someone who has no access to
the author's machine, conversation, or work history.

- Document current behavior, practical instructions, supported interfaces, and
  relevant limitations. Keep contributor guides reusable and reproducible.
- Do not add internal notes, audits, work logs, session summaries, investigation
  diaries, dated verification reports, cleanup inventories, or task checklists.
  Keep temporary findings in the task conversation and release history in the
  appropriate changelog.
- Keep user guides focused on using Noodle. Put necessary implementation and
  test commands in the existing developer references; omit debugging narratives,
  test-run transcripts, personal paths, and machine-specific state.
- Update an existing guide before adding a file. Remove obsolete material and
  repair links when consolidating or deleting documentation.
- Message, event and command guidance lives only in
  `Sources/NoodleCore/MessengerDocumentation.swift`. Do not copy it into a guide;
  link to the source or to `messenger --help`.
