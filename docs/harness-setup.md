# Harness setup

A harness is the agent program Noodle runs for each bot. Noodle supports Codex,
Claude Code, Vercel FX, Grok Build, Muse Code, and OpenCode v2, using your existing account,
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
| OpenCode v2 | `opencode auth login` in Terminal |
| Apple Intelligence | Bundled with Noodle; enable Apple Intelligence in System Settings on a supported Mac running macOS 26 or later. No separate install or sign-in. |

Once a harness is detected, create a bot and select its model and, where available,
reasoning effort. All harnesses support restricted access, with optional
[unrestricted access](security.md) in Settings → Sandbox. Restricted Claude uses
the Claude.ai sign-in from its standard native installation.

Apps connected to ChatGPT or Claude.ai are off by default for Noodle bots. Enable
**Apps** beside that bot in **Settings → Sandbox** to allow them. This preference
is separate for each bot and harness; [account apps](security.md#account-apps)
explains the scope and how it differs from Noodle's assigned tools.

## OpenCode v2

Install the native CLI using [OpenCode’s v2 installer](https://opencode.ai/v2/docs):

```sh
curl -fsSL https://opencode.ai/v2/install | bash
opencode auth login
```

Noodle verifies the vendor-signed binary at `~/.opencode/bin/opencode`. Version 1,
package-manager wrappers, and redirected installations are unsupported. Use
**Check Again** after installing or signing in. Models and reasoning variants
come from the v2 model catalogue. Select a model as `provider/model`.

Restricted bots use their own OpenCode database, configuration, cache, and temporary
files. Noodle imports saved API-key and OAuth credentials from the standard v2
credential database. Global provider configuration, plugins, MCP servers, and
standalone conversations are not imported. Custom provider definitions can be
configured in the bot workspace's `opencode.json`. Environment-only credentials and custom global
storage paths are not used for restricted bots. Models that do not require a
provider login can also be used.

## If setup fails

- **Not installed:** use the installer shown in Noodle. Noodle checks supported native installations; an arbitrary shell wrapper may not work.
- **Codex browser sign-in fails:** run `codex login` in Terminal if your account does not allow device-code login.
- **Sign-in status unknown:** check the harness in Terminal, then choose **Check Again**. Unknown does not mean signed out.
- **Update required:** follow the update instructions in Settings and recheck. Noodle does not install harness updates itself.
- **Update check failed:** choose **Check Again** to retry the release check. The installed version remains visible while the latest version is unavailable.
- **Bot fails to start:** resolve the reported installation, account, or service error, then choose **Kick** for that bot in **Settings → Harness**. Kick is also available from the bot's sidebar menu. Review any recovery confirmation before proceeding.

Codex connection retries appear as amber **Reconnecting…** with elapsed time under
each affected bot in **Settings → Harness → Codex**. You can wait or choose **Kick**.
After ten minutes of connection retries without progress, Noodle stops the old
process before restarting it with the saved session and unfinished work. Noodle
allows two automatic restarts for the unfinished turn; another connection timeout
pauses recovery until you choose **Kick**. Sign-in failures, usage limits, and ordinary long-running
work do not trigger this connection-recovery timeout.

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
Every turn provides `bash`, `read`, and `write`. Use Bash for the shared
workspace CLIs, including Messenger history and assigned integrations. The model
chooses when to use tools; no request classifier restricts their availability.
Tool success still depends on the model and the request.

### Import a local model

1. Open **Settings → Harness → Apple Intelligence → Local Models**.
2. Choose **Download** beside a recommended model to download and import it.
   The list shows each download size and links to its model details and license.
   Downloads use pinned Hugging Face revisions, verify each file, and publish the
   model only after import validation succeeds. **Cancel** removes partial files;
   retry a failed or cancelled download with **Download**.
3. Alternatively, choose **Import Model** and select an already downloaded MLX Qwen2, Qwen3, or
   Llama text chat/instruct model folder. It must contain regular files, including
   `config.json`, `tokenizer.json`, `tokenizer_config.json`, and `.safetensors`
   weights, plus a chat template. Linked Hugging Face cache snapshots must first
   be copied into a folder with real files.
4. Edit a bot, choose Apple Intelligence, and select the imported model.

The recommended list is available before downloading any weights. It starts with
Qwen3 4B Instruct (2507, 4-bit) and Qwen3 8B (4-bit); both accept text and tools.
Downloads run in the app using its existing outbound network access and private
storage. The restricted bot helper remains offline. Allow space for both the
download and the imported copy during installation.

Noodle copies model resources into its private `AppleModels` directory. In
restricted mode the helper can read the selected model but cannot modify the
model library or make network requests. Models load on first use and remain
cached in that bot's helper; switching models or stopping the helper releases
the cached weights. Importing does not enable Apple Intelligence and local models
do not depend on its availability. Change bots using a model before removing it.
**Remove** deletes Noodle's copy of the weights; a folder you imported from is
left in place. Partial files from a download or import interrupted by a crash or
force quit are deleted at the next launch and before the next download or import.
A model whose stored information is damaged is listed as **Unreadable Model** so
it can still be removed.
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

All conversation turns resume their saved native session, with fresh instructions
and tools. On macOS 27, Noodle summarizes older history; macOS 26 retains bounded
complete turns. If input still cannot fit, the turn reports an error and preserves
unfinished work. It does not start a tool-free chat retry or replay actions.
On macOS 27, failed generations retain completed command results in the saved
session. Native Apple budgets include extra space for tool-continuation framing.
When a tool sequence fills the budget, the next generation finishes from its
existing results with further tool calls disabled, using the same session.
Older messages remain accessible through the Messenger CLI.

Private Cloud Compute is not available in Noodle.

For SDK requirements, packaging, and model test commands, see
[Build and test local models](development.md#build-and-test-local-models).

[Documentation](README.md)
