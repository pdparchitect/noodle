# Noodle Computer release notes

Noodle Computer is not ready for release. Per the user's request, keep its
development changes out of the main CHANGELOG.md for now. Add final release
notes only when the user confirms that Computer is ready; preserve unrelated
Noodle changelog entries.

## Independent versioning

Computer shares Noodle's repository but releases independently: use
`Computer/VERSION`, `Computer/CHANGELOG.md` and `computer-vX.Y.Z` tags, with its
own update feed. A mainline Noodle release does not release Computer. Integration
compatibility depends on protocol capabilities, not matching app versions;
coordinate releases when a change requires both apps. See `Computer/RELEASING.md`.
