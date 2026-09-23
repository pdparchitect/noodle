# Noodle Hub

Keep the Hub application, its core and its tests in this folder. The Hub runs bots
with Noodle's own runtime (the `NoodleCore` and `NoodleRuntime` products of the root
package); change that code in the root package, not here. Keep Hub release notes in
CHANGELOG.md here and Noodle integration notes in the root changelog.
Do not publish releases without the user's explicit request.

The Hub lives in the menu bar only: `LSUIElement` in its bundle and the `.accessory`
activation policy. Its data stays apart from Noodle's.
