# Foundation Models Utilities history helpers

Source: [apple/foundation-models-utilities](https://github.com/apple/foundation-models-utilities/tree/1.0.0-beta5)

Version: `1.0.0-beta5`, commit `2aa12937e30d310687f40fc470ea35495816c9a4`.

The three files in `Sources/NoodleAppleRuntime/FoundationModelsUtilities` come
from upstream's `Sources/FoundationModelsUtilities/History` directory:
`DropCompletedToolCalls.swift`, `SummarizeHistory.swift`, and
`TranscriptRendering.swift`. They are licensed under Apache 2.0; see LICENSE.txt.
This directory is copied into the app's Resources/ThirdParty directory when packaging.

We vendor this focused subset because the upstream package's macOS 27 minimum
would raise Noodle's deployment target. These helpers compile only with the
Foundation Models 2 SDK and run only on macOS 27. macOS 26 retains the existing
history fallback. The code runs inside the existing Apple helper, with no new
processes, network access, or entitlements.

Local changes to preserve when updating:

- SDK and runtime availability guards, ordinary imports, internal visibility,
  and documentation matching this subset.
- Summaries use greedy generation with a 256-token output limit.
- Completed-tool trimming preserves every exchange for the current prompt,
  including earlier results in a multi-step task.
- A context-limit failure during summarization retains recent complete turns
  using the existing executor trimming helper. This bounds saved history while
  preserving the current request. Cancellation and other errors propagate.

The production profile supplies the selected model (including Noodle's executor
token budget), an eight-entry summary threshold, and concise instructions that
preserve completed actions. Entry count is not a token budget. Noodle still
checks every model generation, including tool continuations, for token, image,
and tool-result limits. The raw-entry rolling-window helper is deliberately not
included: its suffix can split a tool exchange or drop the current prompt.

To update, compare these files with the corresponding upstream revision,
preserve the listed adaptations, update this version and licence, and run
`zsh scripts/swift-apple.sh test --disable-sandbox --filter NoodleAppleRuntimeTests`.

These are Swift library utilities, independent of the `fm` command-line tool.
