# Privacy

Noodle keeps your chats and bot workspaces on your Mac. What leaves it depends
mostly on the model each bot uses: everything a bot works with is sent to that
model's provider. For what a bot can reach on your Mac, see
[Agent access and privacy](security.md).

## What a provider sees

A bot sends its model what it needs to answer, including:

- your messages, and in a group everyone else's messages too
- the bot's backstory and memory
- attachments, screenshots and voice messages you send it
- files it reads in its workspace and shared folders
- what its tools, computers and browsers return, such as web pages, screenshots
  and command output

The provider handles this under the account the harness signed in with, and
under that account's terms and privacy settings. Noodle cannot limit what the
provider keeps or how it uses it.

## Personal subscriptions

Signing a harness in with a personal subscription, such as ChatGPT, Claude,
Grok or Google, puts your bots' work under that subscription's consumer terms.
Several providers' consumer terms let them keep conversations and use them to
train their models unless you turn this off in the account's privacy settings,
and some keep flagged conversations for review even then.

Before giving a bot private or confidential material:

- Check the training and data-retention settings of the account the harness
  uses, and turn training off where you can.
- Prefer a business, team or API account. These usually exclude training by
  default and keep data for less time.
- Check that you may share it at all. A client's or employer's data may not be
  allowed in a personal account.

## Keep work private

When a provider's terms do not suit the work, use a model that keeps it away
from third parties:

- **On your Mac.** [Apple Intelligence and local models](harness-setup.md#apple-intelligence-and-local-models)
  run entirely on your Mac; Private Cloud Compute is not used. An Ollama
  account uses models running in Ollama on this Mac. Local models are smaller
  than hosted ones and less reliable on long tasks.
- **On your own server.** A Custom account under
  [remote models](harness-setup.md#use-a-remote-model) works with any server
  that offers an OpenAI-compatible Chat Completions API, such as vLLM, LM
  Studio, LiteLLM or llama.cpp, on a machine you control.
- **With a provider you trust.** A Custom account also works with hosted
  providers that offer that API. Choose one whose terms say it does not train
  on your prompts or outputs, keeps them briefly or not at all, processes them
  where you need, and offers a data processing agreement if the work is for a
  business. OpenRouter accounts follow the privacy settings in your OpenRouter
  account, which can exclude providers that train on or keep your data.

A private model keeps the conversation private, not everything the bot does.
Connected tools, browsers and computers you assign still send what the bot
gives them to their own services.

## Groups and Noodle Hubs

- In a group, every bot sends the conversation to its own provider. Adding a
  bot on another provider shares the group's messages with that provider too.
- On a Noodle Hub, conversations, bot files and memory are kept on the Hub's
  Mac, within reach of whoever runs it.
- Hub bots use the sign-ins the Hub lends, so the lender's account and its
  privacy settings apply, not yours.
- A bot shared with other people can tell them what it remembers from your
  conversations with it.
- The picture you choose on a Hub is kept on the Hub, and everyone on it can
  see it.

## Noodle itself

Noodle collects no analytics or usage data. It checks for updates, and
downloads harnesses and models from their publishers when you ask. Voice
messages are transcribed on your Mac.

[Documentation](README.md)
