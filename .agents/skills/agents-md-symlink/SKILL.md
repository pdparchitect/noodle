---
name: agents-md-symlink
description: Every AGENTS.md must have a sibling CLAUDE.md symlink pointing to it. Use when creating, moving, renaming or deleting an AGENTS.md or CLAUDE.md file in any directory, or when auditing agent instruction files.
---

# AGENTS.md with a CLAUDE.md symlink

`AGENTS.md` is the single source of agent instructions. Claude Code reads only
`CLAUDE.md`, so every directory that has an `AGENTS.md` also needs a `CLAUDE.md`
that is a relative symbolic link to it. Never keep a second copy of the text, and
never write an import stub instead of a link.

## Create

Run from the directory that holds the `AGENTS.md`:

```sh
ln -s AGENTS.md CLAUDE.md
```

The target must be the bare filename. Git stores the target verbatim, so an
absolute path breaks on every other checkout.

If a regular `CLAUDE.md` already exists, read it first. Merge anything that is not
already in `AGENTS.md`, then replace the file with the link.

## Keep in step

- Edit `AGENTS.md` only. Writing through `CLAUDE.md` works, but replacing it with
  a regular file silently breaks the link.
- When an `AGENTS.md` is moved, renamed or deleted, do the same to its link.
- When the directory is a build-system source folder, give `CLAUDE.md` the same
  exclusion `AGENTS.md` has, so it is not treated as a source or resource file.

## Verify

List every `AGENTS.md` whose sibling link is missing or wrong:

```sh
find . -name AGENTS.md -not -path './.git/*' -not -path './.build/*' | while read -r f; do
  d=$(dirname "$f")
  [ "$(readlink "$d/CLAUDE.md")" = "AGENTS.md" ] || echo "missing or wrong: $d/CLAUDE.md"
done
```

Git must record the link as a symlink, mode `120000`:

```sh
git ls-files -s -- '*CLAUDE.md'
```
