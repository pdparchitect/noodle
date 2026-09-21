# Harness setup

A harness is the agent program Noodle runs for each bot. Noodle supports Codex,
Claude Code, Vercel FX, Grok Build, Muse Code, OpenCode v2, and Google Antigravity, using your existing account,
plus the experimental bundled Apple Intelligence harness running on device.

The first time you open Noodle with no bots, **Set Up Your First Bot** lists the
harnesses with their state on this Mac. Choose one and **Continue**: Noodle
installs it if needed, signs you in, and asks for the bot's name. **Not Now**
closes it; the empty window keeps a **Set Up Your First Bot** button, and
**Help → Set Up a Bot…** opens it at any time. Everything
it does is also available below, in Settings.

When you have not installed the harness yourself:

1. Open **Settings → Harness**.
2. Choose **Install** beside your provider. Noodle downloads the provider's current
   macOS release from the provider's own servers into Noodle's storage.
3. Sign in using the option below.

The row then reads **Installed by Noodle**. See [Harnesses installed by Noodle](#harnesses-installed-by-noodle).

To install a harness yourself:

1. Open **Settings → Harness**.
2. Choose **Install Manually…** beside your provider and run the displayed command in Terminal.
3. Return to Noodle and choose **Check Installation**.
4. Sign in using the option below, then choose **Check Again**.

| Harness | Sign in |
| --- | --- |
| Codex | **Sign In…** in Noodle, or `codex login` in Terminal |
| Claude Code | **Sign In…** in Noodle, or `claude auth login` in Terminal |
| FX | **Sign In…** in Noodle, or `fx login` in Terminal |
| Grok Build | **Sign In…** in Noodle, or `grok login` in Terminal |
| Muse Code | **Sign In…** in Noodle, or `muse login` in Terminal |
| OpenCode v2 | Works without an account on OpenCode's free models. For your own providers run `opencode auth login` in Terminal; for a copy Noodle installed, **Sign In…** shows the full command to paste. |
| Antigravity | Run `agy` in Terminal and follow its Google sign-in. For a copy Noodle installed, **Sign In…** shows the full command to paste. |
| Apple Intelligence | Bundled with Noodle; enable Apple Intelligence in System Settings on a supported Mac running macOS 26 or later. No separate install or sign-in. |

Once a harness is detected, create a bot and select its model and, where available,
reasoning effort. All harnesses support restricted access, with optional
[unrestricted access](security.md) in Settings → Sandbox. Restricted Claude uses
the Claude.ai sign-in from its standard native installation.

Apps connected to ChatGPT or Claude.ai are off by default for Noodle bots. Enable
**Apps** beside that bot in **Settings → Sandbox** to allow them. This preference
is separate for each bot and harness; [account apps](security.md#account-apps)
explains the scope and how it differs from Noodle's assigned tools.

## Profiles

Codex, Grok Build, Muse Code, and Antigravity can each be signed in to several accounts at
once. Under the harness in **Settings → Harness**, choose **Profiles…**, then
**Add Profile…**, name it, and choose **Sign In…** beside it. Noodle shows the
harness's device code and a button for its sign-in page. Antigravity has no
device code: Noodle shows a command to paste into Terminal, which signs that
profile in; then choose **Check Again**. Choose the profile for a
bot in **Edit Bot → Harness → Profile**; the row appears once that harness has a
profile. **System** is the default and is the harness login already on this Mac,
shared with its CLI and other apps.

Every profile runs the same harness installation. A profile holds only its own
configuration folder inside Noodle's storage, with the login kept in a file
there, not in the Keychain:

| Harness | Profile folder is passed as | Notes |
| --- | --- | --- |
| Codex | `CODEX_HOME` | |
| Grok Build | `GROK_HOME` | Grok sign-ins expire after seven days; sign the profile in again from **Profiles…**. |
| Muse Code | `XDG_CONFIG_HOME`, with `TBH_CREDENTIAL_BACKEND=file` | A Muse version that still saves the sign-in to its shared Keychain item is reported as an error, because that login would not be separate. |
| Antigravity | `HOME` | Antigravity has no setting for its folder, so the profile is a whole separate home. An unrestricted bot on a profile therefore does not see files in your own home folder by their usual `~` paths, such as `~/.gitconfig` or `~/.ssh`. |

A restricted bot receives a copy of its profile's login, as it does from System,
and never the System Keychain login. An unrestricted bot on a profile uses the
profile's folder for the harness's configuration, so settings in `~/.codex`,
`~/.grok`, `~/.config/muse`, or `~/.gemini` do not apply to it, and a Codex thread starts
again when the profile changes. The model list in the bot editor comes from the
System login. Deleting a profile removes its login from Noodle and returns its
bots to System. Claude Code, FX, OpenCode, and Apple Intelligence use the System
login only.

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

## Antigravity

Install the native CLI using [Google's installer](https://antigravity.google/docs/cli/install):

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy
```

Noodle verifies the Google-signed binary at `~/.local/bin/agy`. Models come from
`agy models`; reasoning effort is part of each model's name, so there is no
separate effort setting.

Antigravity cannot ask for tool approvals when it runs without a terminal, so
Noodle starts it with approvals off. A restricted bot is still confined by macOS
to its workspace. Antigravity also cannot be interrupted mid-turn: an urgent
message is handled as soon as the current turn ends.

## Harnesses installed by Noodle

Noodle installs a harness only when this Mac does not already have it, and keeps
it in its own storage, outside your home folder and your shell's `PATH`.

- **Your own installation always wins.** If you later install the harness
  yourself, Noodle uses yours from then on and deletes its copy the next time it
  starts. It never runs two copies against one account.
- **Your sign-in is shared.** Noodle's copy uses the harness's normal account
  folder or Keychain item, so switching between the two copies does not sign you out.
- **Updates.** Noodle checks every six hours and installs a newer release by
  itself. **Update harnesses installed by Noodle automatically** in Settings →
  Harness turns that off, and the row then offers **Update**. A harness you
  installed yourself is never updated by Noodle. Running bots keep their current
  version until restarted; Noodle keeps the previous version, and any older one a
  bot is still running from. If a new release fails Noodle's compatibility check,
  Noodle goes back to the previous version and does not fetch that release again.
- **Remove…** deletes Noodle's copy. Bots on that harness stop working until it
  is installed again, by Noodle or by you.
- **Verification.** Claude Code, Codex and Muse Code downloads are checked against
  the provider's published SHA-256, and OpenCode's and Antigravity's against the
  SHA-512 published by the npm registry and by Google. Vercel and xAI publish none for FX and Grok Build. Every download must carry the provider's Apple code
  signature before it can run; see [Architecture](architecture.md#installed-harnesses).

Muse Code's own installer adds a shell launcher that updates itself. Noodle
installs the native executable alone, which is the only part it ever runs.

## If setup fails

- **Not installed:** use the installer shown in Noodle. Noodle checks supported native installations; an arbitrary shell wrapper may not work.
- **Codex browser sign-in fails:** run `codex login` in Terminal if your account does not allow device-code login.
- **Sign-in status unknown:** check the harness in Terminal, then choose **Check Again**. Unknown does not mean signed out.
- **Update required:** for a harness installed by Noodle, choose **Update**. Otherwise follow the update instructions in Settings and recheck; Noodle does not update a harness you installed yourself.
- **Install failed:** the row shows the reason. A failed signature or checksum check discards the download; choose **Install** to retry, or **Install Manually…**.
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
2. Choose **Download** beside a model under **Available** to download and import it.
   The model tagged **Recommended** is the best fit for this Mac's memory.
   The list shows each download size and links to its model details and license.
   Downloads use pinned Hugging Face revisions, verify each file, and publish the
   model only after import validation succeeds. **Cancel** removes partial files;
   retry a failed or cancelled download with **Download**.
3. Alternatively, choose **Import Model** and select an already downloaded MLX Qwen2, Qwen3,
   Llama, or Gemma 4 chat/instruct model folder. Gemma 4 checkpoints include image and audio
   weights; Noodle copies them but loads the text model only. The folder must contain
   regular files, including `config.json`, `tokenizer.json`, `tokenizer_config.json`,
   and `.safetensors` weights, plus a chat template. Linked Hugging Face cache snapshots must first
   be copied into a folder with real files.
4. Edit a bot, choose Apple Intelligence, and select the imported model.

The Available list is shown before downloading any weights. It runs from
smallest to largest: Qwen3 1.7B, Qwen3 4B Instruct (2507), Qwen3 8B, Gemma 4 E4B and
Qwen3 14B, all 4-bit. Gemma 4 is offered under Google's Gemma terms, linked from
**Details**. Each entry says what the model suits and the memory it wants; all accept
text and tools. A downloaded model moves from Available to **Installed**, where it
keeps the same description, size and details link.
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
