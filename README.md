<div align="center">

<img src="Resources/hero.png" alt="Hey Codex: ChatGPT Voice, hands free, from anywhere on your Mac" width="820">

# Hey Codex

**Say "Hey Codex." ChatGPT Voice opens. Keep your hands where they are.**

[![Release](https://img.shields.io/github/v/release/cyburke/hey-codex?label=release&style=flat-square)](https://github.com/cyburke/hey-codex/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

</div>

---

ChatGPT's desktop app opens Voice mode with a keyboard shortcut. Hey Codex sits in your menu bar, listens for a wake phrase, and presses that shortcut for you. That is the entire tool.

Nothing you say is recorded. Nothing leaves your Mac. No account, no signup.

ChatGPT's desktop app has to be installed, but it does not have to be running or in front. If it is closed, Hey Codex opens it in the background for you. Not having to go find the window is the point.

## Install

```bash
brew install --cask cyburke/tap/hey-codex
```

Requires macOS 14.4 or later. Open it from Applications. No Homebrew? [Install it first](https://brew.sh), or [build it yourself](#build-it-yourself).

To remove it, `brew uninstall --zap --cask hey-codex`, which also clears your settings and enrolled phrase from `~/Library/Application Support/HeyCodex`.

## Setup

It needs two permissions: Microphone, so it can hear you, and Accessibility, so it can press the hotkey. Grant Accessibility and the app restarts itself to pick it up.

The hotkey it presses is ChatGPT's own Voice shortcut, `⌃⌥V` by default, and nothing in ChatGPT needs changing.

Everything else lives in the menu bar icon: change your phrase, adjust sensitivity, or reopen setup from **Setup & Diagnostics**.

To end a Voice session, just tell ChatGPT Voice directly with anything like "Close this voice session" and it will do it. Hey Codex will notice and start listening again on its own. While an active Voice session is open, this tool stops listening, so your wake phrase does nothing.

It uses whichever microphone your Mac is set to, and follows along if you change it in **System Settings → Sound**. Settings has a picker if you'd rather pin one device.

## Your own wake phrase

"Hey Codex" is just the default. Pick **Use My Own Wake Phrase**, type what you want, and say it three times.

One and two syllable ordinary words work best. Invented names and acronyms are hit and miss. Two or three words beats one, since single words go off when you did not mean them. Hey Codex tests your phrase before you record and tells you if it looks unlikely to work.

If your recordings do not clearly contain the whole phrase, Hey Codex arms a shorter part of it instead of failing, and tells you what it settled on.

## Privacy

Wake-word detection runs on your Mac against a bundled offline model. No audio, no transcripts, no wake events leave it. No analytics.

There is one network request in the whole app: once a day it asks GitHub whether a newer release exists. It sends nothing about you, and Settings can switch it off.

## Known limits

- Not notarized: this is free software with no paid Apple Developer account behind it. Homebrew clears the quarantine flag during install. A zip from the releases page will be blocked until you approve it in System Settings.
- Updates are not automatic. Hey Codex tells you when a release exists and you install it.
- Upgrading can re-prompt for Microphone and Accessibility.
- It is a wake-word tool, so it will occasionally miss you or trip on something that sounds close. Sensitivity is adjustable.

## Build it yourself

Needs macOS 14.4 or later and Swift 6.

```bash
git clone https://github.com/cyburke/hey-codex.git
cd hey-codex
./scripts/fetch-sherpa.sh
./scripts/fetch-models.sh
swift test
./scripts/build-release.sh
```

The bundle lands in `dist/HeyCodex.app`. [CONTRIBUTING.md](CONTRIBUTING.md) has the invariants worth not breaking.

## Something broken?

[Open an issue.](https://github.com/cyburke/hey-codex/issues/new/choose) Please skip recordings and transcripts unless you are happy for them to be public.

## Credit

Hey Codex is a fork of **[littlemelon77/hey-claude](https://github.com/littlemelon77/hey-claude)**. The wake-word listener and the audio capture pipeline are that project's work. Hey Codex rebuilds the activation logic, the setup flow, and the interface around ChatGPT Voice.

Wake-word detection uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) by Xiaomi Corporation, Apache-2.0, against a keyword-spotting model from its own model releases. Full third-party attribution is in [NOTICE](NOTICE).

## Licence

**[GPL-3.0](LICENSE)**, inherited from the upstream project. You can use it, read it, modify it, and share it, commercially or not. A modified version you distribute has to stay GPL-3.0 with its source available. There is no warranty.

---

Not affiliated with, endorsed by, or connected to OpenAI. "ChatGPT" and the ChatGPT logo are trademarks of OpenAI, used here only to identify the application this tool works with.
