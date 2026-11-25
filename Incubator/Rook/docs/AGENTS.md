# Documentation

**NOTE: Everything in `docs/` is for people using Rook.** Code is documented only
in its own comments; see the `no-code-docs` skill. Write for someone who has never
seen the code or the author's machine, conversation or work history.

- Document what people can do, how to do it, the access to give and the limits
  they will meet, in plain language.
- Do not describe how the code works, and do not name or link source files,
  types or functions.
- Do not narrate history: describe what is true now. Release history belongs in
  the changelog.
- Update an existing page before adding a file.
- Each release turns these pages into two PDFs: the Setup Guide, for whoever
  prepares Rook for a team, and the User Guide, for the people using it. A page
  joins one or both through front matter at its top, `guides: [setup]`,
  `guides: [user]` or `guides: [setup, user]`, and may set `order:` (100 when not
  given; pages then go by title). Its first heading is its chapter title. A page
  without `guides` stays out of both.
