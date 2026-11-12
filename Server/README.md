# Noodle Server

[![Linux arm64](https://img.shields.io/badge/Linux-arm64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-arm64.tar.gz) [![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-x86_64.tar.gz)

A Noodle Hub for Linux. It runs bots for the people you list in one file, on the Claude Code
and Codex you install, with your sign-ins kept on the server. Each bot works in a sandbox of its
own, and sees nothing of the server, of you or of anyone else's bots.

The people you invite chat with their bots from Noodle on a Mac, Noodle Mobile and Noodle
Terminal, as they would with a Noodle Hub. Computers, browsers, noodlets and calls stay with
Noodle Hub on a Mac. Devices away from home are not told about new replies yet.

## Quick setup

Noodle Server needs a Linux machine or virtual machine with systemd, on arm64 or x86_64. It
cannot run its bots inside an ordinary container.

Download Noodle Server for
[arm64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-arm64.tar.gz)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-x86_64.tar.gz),
then let it set itself up:

```
tar xzf Noodle-Server-linux-*.tar.gz
sudo noodled/noodled setup
```

Setup checks the machine and offers to install what is missing: bubblewrap, msquic, and Claude
Code or Codex. It asks what to call the server, how devices away from home reach it, and your
name; writes the configuration; installs the service; signs the server in to each harness; starts
it; and prints a link and QR code that pair your first device. It asks before every change. Run
it again on a server already set up and it keeps your configuration, or moves it aside with the
date in its name if you choose to start over.

The rest of this page is what setup does, for doing it by hand, and how to run the server after.

## Installing by hand

These steps are for Ubuntu 24.04; elsewhere, install the same packages.

Install the packages it needs, and msquic from Microsoft's packages:

```
sudo apt install bubblewrap curl libcurl4t64 libxml2 libsqlite3-0
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/microsoft.deb
sudo dpkg -i /tmp/microsoft.deb && sudo apt update && sudo apt install libmsquic
```

Download Noodle Server for
[arm64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-arm64.tar.gz)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-x86_64.tar.gz),
then give it an account of its own and put it in place:

```
tar xzf Noodle-Server-linux-*.tar.gz
cd noodled
sudo useradd --system --no-create-home --shell /usr/sbin/nologin noodled
sudo install -d -m 700 -o noodled -g noodled /var/lib/noodled
sudo install -m 755 noodled /usr/local/bin/
sudo install -D -m 644 noodled.yaml /etc/noodled/noodled.yaml
sudo install -m 644 noodled.service /etc/systemd/system/
```

To update, download it again, replace `/usr/local/bin/noodled` and restart the service.

## Harnesses

Install Claude Code, Codex or both where the `noodled` account can run them, for example:

```
sudo npm install -g @anthropic-ai/claude-code @openai/codex
```

Noodle Server never installs or updates them; you do, as you would on your own machine.

## Setting it up

Everything is in `/etc/noodled/noodled.yaml`, which explains each setting:

- the harnesses, by where their program is, each with any profiles: logins of their own, such
  as for another account;
- plans, saying which harnesses and profiles their people may use, which models, and how many
  tokens;
- the people the server runs bots for, by name, each with their plan.

Check it after every change:

```
noodled check
```

It lists every mistake with where it is in the file, and the logins nobody has signed in to yet.

## Signing in

Sign the server in to each harness, and to each profile, as the `noodled` account:

```
sudo -u noodled noodled login claude-code
sudo -u noodled noodled login codex --profile Work
```

Each runs the harness's own sign-in. Bots use the login from their next start.

## Starting

```
sudo systemctl enable --now noodled
journalctl -u noodled -f
```

After changing the file, run `noodled check`, then `sudo systemctl restart noodled`. Someone you
take out of the file keeps their bots and conversations, but can no longer use the server.

## Inviting people

```
sudo -u noodled noodled invite Ada --qr
```

This prints a link that pairs one device for Ada and works for 15 minutes. With `--qr` it also
draws the link's QR code, which Noodle on a phone can scan; `--png ada.png` saves it as a picture
to send. On a Mac, Ada chooses **Join** under Noodle Hubs in **Settings → Hub** and pastes the link.

Devices on the server's network find it by themselves. For devices away from it, forward UDP
port 38415 to the server and set `address` in the file to the name or address they can reach.
