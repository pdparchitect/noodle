# Noodle Computer release notes

Keep Computer app changes in Computer/CHANGELOG.md and image changes in
Computer/Images/CHANGELOG.md. Noodle-side integration changes belong in the
main CHANGELOG.md; preserve unrelated entries. Public releases require explicit
user approval and the checks in Computer/RELEASING.md.

## Independent versioning

Computer shares Noodle's repository but releases independently: use
`Computer/VERSION`, `Computer/CHANGELOG.md` and `computer-vX.Y.Z` tags, with its
own update feed. A mainline Noodle release does not release Computer. Integration
compatibility depends on protocol capabilities, not matching app versions;
coordinate releases when a change requires both apps. See `Computer/RELEASING.md`.
