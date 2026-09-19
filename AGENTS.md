# Concurrent edits

Assume that multiple ai agents are editing this project. Don't get surprised.

# Project instructions

Task-specific procedures are skills in [`.agents/skills/`](.agents/skills/). Use the
ones that match the work.

## Behaviour changes are test-first

Never change behaviour without a test that fails first, and report both runs.

## Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

Do not publish a release unless the user explicitly asks.
