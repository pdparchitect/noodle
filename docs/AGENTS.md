# Documentation

**NOTE: Everything in `docs/` is for people using Noodle.** Code is documented
only in its own comments; see the `no-code-docs` skill. Write for someone who
has never seen the code or the author's machine, conversation or work history.

- Document what people can do, how to do it, and the limits they will meet, in
  plain language.
- Do not describe how the code works: no architecture, design reasoning,
  implementation notes, formats, protocols, sandbox rules, internal limits or
  build and test commands. Put what the code needs explained in comments beside it.
- Do not name or link source files, types or functions.
- Do not add internal notes, audits, work logs, session summaries, investigation
  diaries, dated verification reports, cleanup inventories, or task checklists.
  Keep temporary findings in the task conversation and release history in the
  appropriate changelog.
- Update an existing guide before adding a file. Remove obsolete material and
  repair links when consolidating or deleting documentation.
- Message, event and command guidance lives only in the messenger documentation
  in the source. Do not copy it into a guide; point to `messenger --help`.
