# Harness setup

A harness is the agent program behind each bot. Noodle supports Codex, Claude
Code, Vercel FX, Grok Build, Muse Code, OpenCode v2, and Google Antigravity,
using your existing account, plus the experimental Apple Intelligence harness,
which comes with Noodle and runs on your Mac.

The first time you open Noodle with no bots, **Set Up Your First Bot** offers
OpenAI, Anthropic, Meta and xAI, each with its harness and its state on this Mac;
**Other** lists the rest. Choose one and **Continue**: Noodle installs it if
needed, signs you in, and asks for the bot's name. **Not Now** closes it; the
empty window keeps a **Set Up Your First Bot** button, and **Help → Set Up a
Bot…** opens it at any time. Everything it does is also available in Settings,
as described below.

To let Noodle install a harness:

1. Open **Settings → Harness**.
2. Choose **Install** beside your provider. Noodle downloads the provider's
   current release from the provider's own servers.
3. Sign in using the option below.

The row then reads **Installed by Noodle**. See
[Harnesses installed by Noodle](#harnesses-installed-by-noodle).

To install a harness yourself:

1. Open **Settings → Harness**.
2. Choose **Install Manually…** beside your provider and run the displayed
   command in Terminal.
3. Return to Noodle and choose **Check Installation**.
4. Sign in using the option below, then choose **Check Again**.

| Harness | Sign in |
| --- | --- |
| Codex | **Sign In** in Noodle, or `codex login` in Terminal |
| Claude Code | **Sign In** in Noodle, or `claude auth login` in Terminal |
| FX | **Sign In** in Noodle, or `fx login` in Terminal |
| Grok Build | **Sign In** in Noodle, or `grok login` in Terminal |
| Muse Code | **Sign In** in Noodle, or `muse login` in Terminal |
| OpenCode v2 | Works without an account on OpenCode's free models. For your own providers run `opencode auth login` in Terminal; for a copy Noodle installed, **Sign In** shows the full command to paste. |
| Antigravity | Run `agy` in Terminal and follow its Google sign-in. For a copy Noodle installed, **Sign In** shows the full command to paste. |
| Apple Intelligence | Turn on Apple Intelligence in System Settings on a supported Mac running macOS 26 or later. No separate install or sign-in. |

Once a harness is found, create a bot and choose its model and, where available,
reasoning effort. Every bot starts with restricted access; you can give a bot
[unrestricted access](security.md) in **Settings → Sandbox**. A restricted Claude
bot uses the Claude.ai sign-in from Claude Code's standard installation.

Apps connected to ChatGPT or Claude.ai are off by default for Noodle bots. Turn
on **Apps** beside a bot in **Settings → Sandbox** to allow them. This setting is
separate for each bot and harness; [account apps](security.md#account-apps)
explains what it covers.

## Profiles

Codex, Grok Build, Muse Code, and Antigravity can each be signed in to several
accounts at once. Under the harness in **Settings → Harness**, choose
**Profiles**, then **Add Profile…**, name it, and choose **Sign In…** beside it.
Noodle shows a sign-in code and a button for the sign-in page. For Antigravity,
Noodle instead shows a command to paste into Terminal; run it, then choose
**Check Again**.

Choose the profile for a bot in **Edit Bot → Harness → Profile**; the row appears
once that harness has a profile. **System** is the default: the harness sign-in
already on this Mac, shared with Terminal and other apps.

- Grok Build sign-ins expire after seven days; sign the profile in again from
  **Profiles**.
- An unrestricted bot on a profile does not use your usual settings for that
  harness (in `~/.codex`, `~/.grok`, `~/.config/muse` or `~/.gemini`).
  An unrestricted Antigravity bot on a profile also does not see files in your
  home folder by their usual `~` paths, such as `~/.gitconfig` or `~/.ssh`.
- A Codex conversation starts again when you change the bot's profile.
- The model list in the bot editor comes from the System sign-in.
- Deleting a profile signs it out of Noodle and moves its bots back to System.
- Claude Code, FX, OpenCode, and Apple Intelligence use the System sign-in only.

## OpenCode v2

Install OpenCode with [OpenCode's v2 installer](https://opencode.ai/v2/docs):

```sh
curl -fsSL https://opencode.ai/v2/install | bash
opencode auth login
```

Choose **Check Again** after installing or signing in. Version 1 and copies
installed through package managers are not supported. Choose a model as
`provider/model`.

A restricted OpenCode bot uses the API keys and accounts you signed in with, but
not your global OpenCode settings, plugins, MCP servers or conversations. Put
custom provider settings in `opencode.json` in the bot's workspace. Keys set only
in your shell environment are not available to restricted bots. Models that need
no provider sign-in also work.

## Antigravity

Install Antigravity with [Google's installer](https://antigravity.google/docs/cli/install):

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy
```

Reasoning effort is part of each Antigravity model's name, so there is no
separate effort setting. Antigravity runs without asking for tool approvals; a
restricted bot is still limited to its workspace. It cannot be interrupted
mid-turn: an urgent message is handled as soon as the current turn ends.

## Harnesses installed by Noodle

Noodle installs a harness only when this Mac does not already have it, and keeps
its copy out of your home folder and Terminal.

- **Your own installation always wins.** If you later install the harness
  yourself, Noodle uses yours and deletes its copy the next time it starts.
- **Your sign-in is shared.** Switching between Noodle's copy and yours does not
  sign you out.
- **Updates.** Noodle checks every six hours and installs newer releases itself.
  Turn off **Update harnesses installed by Noodle automatically** in
  **Settings → Harness** to update by hand with **Update**. Noodle never updates
  a harness you installed yourself. Running bots keep their version until
  restarted. If a new release does not work with Noodle, Noodle goes back to the
  previous version and skips that release.
- **Remove** deletes Noodle's copy. Bots on that harness stop working until it
  is installed again, by Noodle or by you.
- **Verification.** Noodle checks every download is genuine before running it
  and discards any that fails.

## If setup fails

- **Not installed:** use the installer shown in Noodle. Other ways of installing
  may not be detected.
- **Codex browser sign-in fails:** run `codex login` in Terminal if your account
  does not allow sign-in with a code.
- **Sign-in status unknown:** check the harness in Terminal, then choose
  **Check Again**. Unknown does not mean signed out.
- **Update required:** for a harness installed by Noodle, choose **Update**.
  Otherwise follow the update instructions in Settings and check again.
- **Install failed:** the row shows the reason. Choose **Install** to retry, or
  **Install Manually…**.
- **Update check failed:** choose **Check Again** to retry. The installed version
  stays visible while the latest version is unavailable.
- **Bot fails to start:** fix the reported installation, account, or service
  error, then choose **Kick** for that bot in **Settings → Harness** or from the
  bot's sidebar menu. Review any recovery confirmation before proceeding.

When Codex has trouble connecting, affected bots show an amber **Reconnecting…**
with the elapsed time in **Settings → Harness → Codex**. You can wait or choose
**Kick**. After ten minutes without progress Noodle restarts the bot and carries
on with its unfinished work, up to twice; after that it waits for you to choose
**Kick**.

Provider usage limits apply in either access mode. If a provider reports a rate
limit, wait for it to clear before retrying.

## Apple Intelligence and local models

Apple Intelligence is experimental. Its on-device model can respond slowly, miss
earlier details, or fail tool tasks. Apple chooses and updates the model; on
macOS 27 the model picker shows the installed model and what it can do.
Private Cloud Compute is not available in Noodle.

Apple models that support images receive image attachments, up to four images
per message, 20 MiB each and 40 MiB in total. Local models accept text only.

### Import a local model

1. Open **Settings → Harness → Apple Intelligence → Local Models**.
2. Choose **Download** beside a model under **Available**. The model tagged
   **Recommended** suits this Mac's memory best. The list shows each download
   size and links to the model's details and license. **Cancel** removes partial
   files; choose **Download** again to retry.
3. Or choose **Import Model** and select an MLX Qwen2, Qwen3, Llama, or Gemma 4
   chat or instruct model folder you have already downloaded. The folder must
   contain real files, not links, so copy a Hugging Face cache snapshot into a
   folder first. Gemma 4 is used for text only.
4. Edit a bot, choose Apple Intelligence, and select the model.

The Available list offers, smallest first: Qwen3 1.7B, Qwen3 4B Instruct (2507),
Qwen3 8B, Gemma 4 E4B and Qwen3 14B. Each says what it suits and how much memory
it needs. Gemma 4 is offered under Google's Gemma terms, linked from **Details**.
Downloaded models move to **Installed**.

- Allow disk space for both the download and Noodle's copy while installing.
- Local models do not need Apple Intelligence to be turned on.
- Each bot using a model loads its own copy, so plan for their combined memory.
- Noodle limits local models to 32,768 tokens of context.
- Move bots off a model before removing it. **Remove** deletes Noodle's copy; a
  folder you imported from is left in place.
- A damaged model is listed as **Unreadable Model** so you can remove it.

### Long conversations

When a conversation grows too long for the model, Noodle leaves out or
summarizes older turns and shortens large tool results. The full conversation
stays saved, and bots can still look up older messages. If a request still does
not fit, the turn reports an error and keeps unfinished work.

[Documentation](README.md)
