# Maintaining Apple's history utilities

These Swift files are adapted copies from
[apple/foundation-models-utilities](https://github.com/apple/foundation-models-utilities),
under `Sources/FoundationModelsUtilities/History`. They do not receive OS or
Swift Package updates automatically.

Before changing these Swift files, revising Apple context management, or upgrading
the Apple SDK/toolchain, check upstream for relevant updates:

1. Read the [provenance and adaptations](../../../Support/ThirdParty/FoundationModelsUtilities/README.md).
   It records the currently incorporated tag and exact commit; use that as the
   comparison baseline.
2. Check upstream releases/tags and changes to the corresponding history files
   since that commit. Review bug fixes and API/deployment requirements before
   importing changes. Mention the revision checked and any deferred relevant
   updates in the task summary.
3. Preserve the documented compatibility guards, bounded summaries, cancellation
   behavior, overflow fallback, and all tool exchanges for the current prompt.
   Remove a local adaptation when upstream provides equivalent tested behavior.
   Keep Noodle's per-generation token/image/tool-result budget.
4. After an update, revise the recorded tag/commit and adaptation notes, retain
   Apple's copyright and licence, and add an Unreleased changelog entry for any
   user-visible behavior change. Keep the imported subset small. Reconsider a
   direct upstream package dependency when its deployment requirements allow
   Noodle to retain its supported macOS versions.
5. Run `swift test --disable-sandbox --filter NoodleAppleRuntimeTests`.
   For model-facing changes, also run
   `NOODLE_TEST_APPLE_MODEL=1 swift test --disable-sandbox --filter Apple27LiveTests`
   on a compatible Mac with Apple Intelligence available. Report skipped checks.

Documentation-only edits do not require an upstream refresh or model tests.
