# Harness setup

A harness is the agent program Noodle runs for each bot. Noodle supports Codex,
Claude Code, Vercel FX, Grok Build, and Muse Code, using your existing account,
plus the experimental bundled Apple Intelligence harness running on device.

For an external harness:

1. Open **Settings → Harness**.
2. Choose **Install…** beside your provider and run the displayed command in Terminal.
3. Return to Noodle and choose **Check Installation**.
4. Sign in using the option below, then choose **Check Again**.

| Harness | Sign in |
| --- | --- |
| Codex | **Sign In…** in Noodle, or `codex login` in Terminal |
| Claude Code | **Sign In…** in Noodle, or `claude auth login` in Terminal |
| FX | **Sign In…** in Noodle, or `fx login` in Terminal |
| Grok Build | `grok login` in Terminal |
| Muse Code | `muse login` in Terminal |
| Apple Intelligence | Bundled with Noodle; enable Apple Intelligence in System Settings on a supported Mac running macOS 26 or later. No separate install or sign-in. |

Once a harness is detected, create a bot and select its model and, where available,
reasoning effort. Codex, FX, Grok Build, Muse Code, and Apple Intelligence support restricted
access. Claude Code requires [autonomous access](security.md).

## If setup fails

- **Not installed:** use the installer shown in Noodle. Noodle checks supported native installations; an arbitrary shell wrapper may not work.
- **Codex browser sign-in fails:** run `codex login` in Terminal if your account does not allow device-code login.
- **Sign-in status unknown:** check the harness in Terminal, then choose **Check Again**. Unknown does not mean signed out.
- **Update required:** follow the update instructions in Settings and recheck. Noodle does not install harness updates itself.
- **Bot fails to start:** resolve the reported installation, account, or service error, then choose **Kick** for that bot in **Settings → Harness**. Kick is also available from the bot's sidebar menu. Review any recovery confirmation before proceeding.

Provider usage limits still apply in either access mode. If a provider reports a
rate limit, wait for it to clear before retrying. Apple Intelligence is experimental;
its on-device model can respond slowly, miss earlier details, or fail tool tasks.

## Apple Intelligence and local models

On macOS 27, a build made with the macOS 27 SDK shows the installed Apple model
variant, context capacity, and supported capabilities in the bot model picker.
Apple selects and updates the system model. Noodle does not force a particular
Apple variant. On macOS 26, the existing on-device text harness remains available.

Apple models with image support receive current image attachments directly.
Each turn accepts up to four images, 20 MiB per image and 40 MiB total. Older
systems and text-only local models report that image input is unsupported.
The helper decodes images locally at up to 2,048 pixels on the longest side,
preserving orientation and the original attachments. Saved model context keeps
text references to images alongside the reply; original images remain in Noodle.
macOS 27 workspace turns require an initial tool call, then allow the model to
finish its response. Tool success still depends on the model and the request.

### Import a local model

1. Open **Settings → Harness → Apple Intelligence → Local Models**.
2. Choose **Import Model** and select an already downloaded MLX Qwen2, Qwen3, or
   Llama text chat/instruct model folder. It must contain regular files, including
   `config.json`, `tokenizer.json`, `tokenizer_config.json`, and `.safetensors`
   weights, plus a chat template. Linked Hugging Face cache snapshots must first
   be copied into a folder with real files.
3. Edit a bot, choose Apple Intelligence, and select the imported model.

Noodle copies model resources into its private `AppleModels` directory. In
restricted mode the helper can read the selected model but cannot modify the
model library or make network requests. Models load on first use and remain
cached in that bot's helper; switching models or stopping the helper releases
the cached weights. Importing does not enable Apple Intelligence and local models
do not depend on its availability. Change bots using a model before removing it.
Different bots can load separate copies, so account for their combined memory.
Specialized MLX shaders compile in the helper's own Metal cache. The compiler
receives scoped access to that cache and read-only bundled resources; model
weights, bot workspaces, and other applications' caches are not delegated.
Local models currently accept text and tools; use a capable Apple model for images.
Noodle caps local model context at 32,768 tokens, even if the model supports more.

### Context limits

On macOS 27, Noodle budgets input before each model generation, including the
continuations after tool calls. It keeps the current request, instructions,
tool definitions and completed calls, then removes old complete turns or
shortens large tool results as needed. The full text transcript remains saved;
compaction does not rerun completed tools. Older information outside the input
window remains available through conversation history and workspace files.

The budget reserves space for the reply and model overhead. Apple text and
schemas use the system token counter. Because the current macOS 27 counter
rejects image attachments, images use a conservative size-based allowance;
Noodle can reduce their input resolution down to a 512-pixel longest edge.
Original attachments stay unchanged. Local models use their own tokenizer with
conservative allowances for serialized schemas and chat framing.

If a chat still exceeds the limit, Noodle makes one smaller, tool-free attempt,
retaining its current images. Workspace actions are never automatically replayed
by this recovery. Requests that cannot fit after compaction ask for smaller input
or a model with a larger context window. macOS 26 retains the earlier history
trimming and text-chat recovery behavior.

Private Cloud Compute is not enabled. Apple's managed entitlement and supported
distribution requirements need to be resolved before it can be shipped here.

### Building and testing

The MLX Foundation Models adapter is pinned to an upstream revision because its
macOS 27 integration is not yet tagged. See `Package.swift` and `Package.resolved`.
The new APIs are guarded by the Foundation Models module version and runtime OS
availability, preserving builds with the older SDK. Use Xcode 27 and install its
Metal Toolchain component for a build with local model support. Model resources
and their licenses are supplied by the person importing them; weights are not
distributed with Noodle. `scripts/build-app.sh` uses `scripts/swift-apple.sh`,
which can select the installed macOS 27 Command Line Tools when Xcode's SDK is
older. It does not change `xcode-select`. Use the same wrapper for `build`, `test`,
and `run`, or override `NOODLE_SWIFT` and `NOODLE_MACOS_SDK` explicitly.
With mixed installations, the wrapper builds and tests the Apple helper and core
targets; app packaging separately builds SwiftUI with the matching full Xcode SDK.
The newer helper uses `.build/apple27` so ordinary app builds cannot replace it.
For local-model tests against an unbundled helper, run
`zsh scripts/build-mlx-metal.sh "$(zsh scripts/swift-apple.sh build --show-bin-path)"`
first. App packaging builds and includes these shaders automatically.

Ordinary tests use synthetic model folders. Set `NOODLE_TEST_APPLE_MODEL=1` to
run the live Apple tests. Set `NOODLE_TEST_MLX_MODEL` to an existing model folder
to run the sandboxed local-model test. `NOODLE_APPLE_TEST_HELPER` selects a bundled
helper for testing its packaged resources. These tests use disposable bot storage.

CI keeps the normal suites on `macos-26` and probes `macos-latest` for optional
macOS 27 harness tests. `scripts/detect-apple27.py` checks the OS, Apple Silicon,
and an installed SDK/compiler with full Xcode's XCTest support. When prerequisites
are missing, the job summary reports a skip before any model build or Metal
download. When they are present, CI builds the isolated helper and Metal shaders,
asserts that local-model support was compiled in, and runs the regression suite.
Build or test failures block Noodle release preparation; missing prerequisites do
not. Live inference remains opt-in because hosted runners need not have Apple
Intelligence enabled or model weights installed. This optional test job does not
change the SDK used to package releases.

[Documentation](README.md)
