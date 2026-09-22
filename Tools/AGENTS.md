# Tools

The tools Noodle gives its bots. Each folder here is one bundled ExtensionKit
extension that Noodle discovers at launch; nothing in the app names them.

`Tools/Calendar` is the exception: it has no extension. macOS grants calendar access
to the app a person sees and never to a background extension, which was measured
before the tool was written, so its provider is `ToolProviderKind.builtIn` and runs
inside Noodle. Build a tool this way only when a permission makes an extension
impossible; the extension is the default, and the provider contract is the same.

`Tools/Browser` and `Tools/Computer` are the bot-facing tools. The apps they
drive live in `/Browser` and `/Computer` and are separate products with their
own versions and changelogs. A change here ships with Noodle and goes in the
root `CHANGELOG.md`.

## Layout

```
Tools/NAME/
  Sources/NoodleNAMETools/            the provider: tools, schemas, guidance
  Sources/NoodleNAMEToolsExtension/   the .appex shell, a few lines
  Tests/NoodleNAMEToolsTests/
  Info.plist                          the .appex Info.plist
  Extension.entitlements              what the .appex is signed with; App Sandbox alone unless there is a reason
```

A built-in tool has only `Sources/NoodleNAMETools` and `Tests/NoodleNAMEToolsTests`,
registered with `builtInTool("NAME")` in `Package.swift`. Its EventKit-style access to
the Mac, and the entitlement and usage string that go with it, belong to the app, and
its controller lives in `Sources/Noodle` like the other assignment controllers.

## Where the framework is

The contract and the host are in `Sources/NoodleCore`, not here:

- `ToolProviders.swift`: `ToolProvider`, `ToolProviderManifest`, `ToolActivation` and the schema conventions below. Read its doc comments first.
- `ToolExtension.swift`: `ToolExtensionService`, which an extension hands its provider to.
- `ToolBroker.swift`: every check made around a call.
- `ToolProviderSkills.swift`: writes each bot's skill from the manifest and the tool list.
- `Sources/Noodle/ToolExtensionDiscovery.swift`: finds the bundled extensions.

Bots reach every tool through `messenger tool PROVIDER TOOL`. There is no per-tool CLI and there must not be one.

## Rules

- A provider returns MCP-shaped JSON: a `tools/list` result and `tools/call` results.
- The provider never authorizes. It declares, the broker enforces:
  - `"format": "noodle-resource"` with `"noodle/kind"` on a parameter that names a browser, computer or other assigned thing. The broker refuses values the bot was not assigned.
  - `"format": "noodle-file"` with `"noodle/access"` `read` or `write` for a workspace path. The provider gets an open handle, never a path.
  - `"format": "noodle-conversation"` for a conversation the bot must belong to.
  - `_meta["noodle/resource-list"]` on a tool whose result lists resources, so the broker can remove unassigned ones.
  - `_meta["noodle/post"]` in a result to post into the verified conversation.
  - List every parameter a check depends on in the schema's `required`.
- Before an action that cannot be undone, call `context.authorize`. It fails if the assignment was removed while the call was running.
- Activation is `.always`, or `.whenAssigned(KIND)` when the tool only makes sense with an assigned resource.
- Everything a bot reads about a tool comes from the extension: `manifest.summary`, `manifest.instructions` and the tool descriptions. Do not add tool text to `MessengerDocumentation`, `WorkspaceRepository.swift` or `docs/`.
- An extension gets the App Sandbox only. Browser and Computer also hold their companion's app group, and only that. `scripts/verify-tool-extensions.sh` pins this; a new entitlement needs a change there and a reason.
- Bundled extensions only. Do not add loading of third-party extensions.
- Extensions are background processes: keep `LSBackgroundOnly` in `Info.plist`.

## Adding a tool

1. Create `Tools/NAME` in the layout above. Copy `Tools/Vision`; it is the smallest.
2. Add `tool("NAME")` at the end of `Package.swift`.
3. In `scripts/build-app.sh`, add the block that assembles `NoodleNAMETools.appex` and the line that signs it, next to the existing three. The bundle identifier is `<noodle id>.tools.NAME`.
4. `scripts/verify-tool-extensions.sh` checks every bundled extension and needs no change for a tool whose `Extension.entitlements` holds the sandbox alone. Anything more needs a case there.
5. If it follows an assignment, publish that assignment from `NoodleStore` with `toolAssignments.replace(KIND, with:)`.

For a built-in tool, replace steps 2–4 with `builtInTool("NAME")` in `Package.swift`, a
dependency on the provider from the `Noodle` target, `toolProviders.register(...)` in
`NoodleStore`, and whatever entitlement and `Info.plist` usage string the access needs in
`Support/`.

## Tests

- Provider tests run without the extension, a companion app, a network or an account. They must pass in CI.
- Write the test first and see it fail.
- Before calling a change done, run all of `swift test`, then `scripts/build-app.sh` and `scripts/verify-tool-extensions.sh` on the bundle.
