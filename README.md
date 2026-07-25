<div align="center">

<img src="Resources/hero.png" alt="Hey Codex: ChatGPT Voice, hands free, from anywhere on your Mac" width="820">

# Hey Codex

**Say "Hey Codex." ChatGPT Voice opens. Keep your hands where they are.**

[![Release](https://img.shields.io/github/v/release/cyburke/hey-codex?label=release&style=flat-square)](https://github.com/cyburke/hey-codex/releases/latest)
[![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-black?style=flat-square)](https://github.com/cyburke/hey-codex/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![Size](https://img.shields.io/badge/app-30%20MB-green?style=flat-square)](https://github.com/cyburke/hey-codex/releases/latest)

</div>

---

OpenAI shipped Voice mode in the ChatGPT desktop app. It is genuinely good, and it opens with a keyboard shortcut.

Hey Codex removes the keyboard. It sits in your menu bar, listens for a wake phrase, and presses that same shortcut for you. That is the entire tool.

Nothing is recorded. Nothing is uploaded. No account, no signup, no config file.

## Install

```bash
brew install --cask cyburke/tap/hey-codex
```

That is the whole thing. Open it from Applications and it launches straight away, with no security warning to click through.

No Homebrew? [Install it first](https://brew.sh), or [build Hey Codex from source](#build-it-yourself) if you would rather read the code before running it.

## Set it up

Launch Hey Codex and a setup window walks you through it in three steps. It takes about a minute.

1. **What it does** and why an always-listening app is safe here.
2. **Two permissions**, both on one page, each ticking green as you grant it. **Microphone** so it can hear the phrase, **Accessibility** so it can press the hotkey. After Accessibility the app restarts itself, because macOS only hands a fresh permission to a fresh process. The window comes back on its own.
3. **One test**, which confirms the hotkey in ChatGPT actually matches. Then you are done.

The only thing to know: Hey Codex presses ChatGPT's **Voice chat hotkey**, so it needs to know which one that is. Step 3 asks you, and defaults to `⌃⌥V`. Already using a different chord? Type that one instead. Nothing in ChatGPT needs changing.

Everything after this lives in the menu bar icon. Click it to change your phrase, adjust sensitivity, or reopen this window from **Setup & Diagnostics**, which is also the quickest way to spot a permission that got switched off later.

To end a Voice session, close it in ChatGPT however you normally would. Hey Codex notices and starts listening again by itself. There is no second phrase to memorize.

## What makes it not annoying

Most wake-word tools get one thing wrong: they fire the shortcut and assume it worked. Since the ChatGPT hotkey is a toggle, that means saying your phrase while Voice is already open hangs up on you.

Hey Codex checks whether ChatGPT's Voice panel is actually on screen before it does anything.

| Situation | What happens |
| --- | --- |
| You say the phrase | Voice opens |
| You say it again while Voice is open | Nothing. It will not hang up on you |
| You opened Voice with the keyboard yourself | It knows, and stays quiet |
| Voice ends, any way at all | It starts listening again on its own |
| ChatGPT is the frontmost app | Still works |

While a Voice session is open it stops listening entirely, so your conversation cannot set it off.

## Use any phrase you like

"Hey Codex" is just the default. Pick **Use My Own Wake Phrase** from the menu, type whatever you want, and say it three times.

Genuinely anything. "Hey Jarvis" if you have always wanted to. "Hey Computer" if you grew up on Star Trek. Your dog's name. Whatever makes you smile when it works.

Those three recordings never leave your Mac. They are there so the keyword can be built from how the speech model actually hears *your* voice, then the detector is tuned until all three of your takes fire. That is why recording beats picking from a list: a keyword guessed from spelling matches a generic speaker, not you.

Two or three words works best, since single words tend to go off when you did not mean them. Changing your mind is one button.

## Earbuds and other microphones

Hey Codex uses whichever microphone your Mac is set to. Switch input in **System Settings → Sound** and it follows along, so there is nothing to configure here.

Worth knowing: macOS does not switch to Bluetooth earbuds by itself when they connect. You choose that in Sound settings, the same as you already do for output. Hey Codex just goes wherever you point your Mac.

If you would rather pin it to one specific microphone regardless of what your Mac is doing, Settings has a picker. A pinned device that gets unplugged falls back to another one so the app keeps working, and resumes the moment it reconnects.

## Privacy

Wake-word detection runs on your Mac with a bundled offline model. No audio, no transcripts, no wake events, ever, to anyone. No analytics. No telemetry.

There is exactly one network request in the whole app: once a day it asks GitHub whether a newer release exists. It sends nothing about you, and you can switch it off in Settings, at which point Hey Codex makes no network requests at all.

Two permissions, both doing the obvious thing:

- **Microphone**, to hear the phrase.
- **Accessibility**, to press the hotkey.

Revoke either in System Settings whenever you like.

## Why macOS warns you

Hey Codex is not notarized. Notarization requires a paid Apple Developer account, and this is free software.

Gatekeeper reads "not notarized" as "unknown," so macOS quarantines the download. That is a statement about Apple's paperwork, not about the app. Every line of source is in this repo, and you can build it yourself in about a minute if you would rather not take my word for it.

The Homebrew cask clears that quarantine flag during install, which is why the app opens without a prompt. If you would rather macOS kept its guard up, build from source instead: a binary you compiled yourself is never quarantined, because it was never downloaded.

If you hold an Apple Developer ID and want to contribute a notarized build, please open an issue. That would be a genuinely useful contribution.

## Why not just use macOS Voice Control?

You can. Voice Control has custom commands, and one of the available actions is [pressing a keyboard shortcut](https://support.apple.com/guide/mac-help/customize-voice-control-mchl9899c8a5/mac), so a spoken phrase really can trigger ChatGPT Voice with nothing installed.

The catch is what else comes along. Voice Control is a system-wide accessibility layer: switch it on and it listens for every command it knows, everywhere, and dictates unmatched speech into whatever field has focus. If you already use a dictation tool, the two compete for the same words. There is a sleep command to park it, but you will be using it constantly.

Hey Codex listens for one phrase and does one thing. It never inserts text, never interprets anything else you say, and needs nothing switched on system-wide.

## Known limits

- Updates are not automatic. Hey Codex tells you when a release exists, you install it.
- The app is signed but not notarized. Homebrew handles that for you. A zip downloaded straight from the releases page will be blocked by macOS until you approve it in System Settings, which is why Homebrew is the recommended route.
- Upgrading can re-prompt for Microphone and Accessibility, because a rebuilt app can look like a new app to macOS.
- It is a wake-word tool, so it will occasionally miss you or trip on something that sounds close. Sensitivity is adjustable.

## How it works

Four moving parts, none of them clever:

| Part | What it does |
| --- | --- |
| **Wake word** | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) keyword spotting against a 13 MB offline zipformer model. Runs on CPU, never contacts a network. |
| **Capture** | `AVCaptureSession` delivering 16 kHz mono audio. Input only, deliberately — see the note below. |
| **The press** | One `CGEvent` sequence posted to the system HID tap, which is what ChatGPT's Carbon hotkey listens on. |
| **State** | Reads whether ChatGPT's own Voice panel is on screen, so the app knows whether a session is actually open instead of guessing. |

**Why capture is input-only.** `AVAudioEngine` looks like the obvious choice, and it is wrong for this. On macOS it runs a single I/O unit spanning the default input *and* output, and simply installing an input tap makes CoreAudio fabricate a running aggregate device across both. Measured on a Mac whose monitor carries audio in and out over one USB connection:

```
AVAudioEngine      devices 5 -> 6    NEW: CADefaultDeviceAggregate in:2 out:2 IO-RUNNING
AVCaptureSession   devices 5 -> 5    the microphone only,          in:2 out:0 IO-RUNNING
```

An app that listens for a wake word has no business activating your speakers. `swift run hey-codex-selftest audio-footprint` fails if capture ever creates a device again.

**Why it does not just assume the hotkey worked.** The ChatGPT hotkey is a toggle, so a helper that fires and hopes will hang up on you the second time you speak. Hey Codex checks ChatGPT's Voice panel first. That check reads only which process owns an on-screen floating window, never window contents, titles, position, or size, and needs no Screen Recording permission. It is also strictly optional: until the app has actually seen a Voice panel on your Mac it assumes nothing, and if OpenAI ever restructures that panel it falls back to simply sending the hotkey.

## Build it yourself

Reasonable thing to want with an app that listens to your microphone. Needs macOS 14.4 or later and Swift 6.

```bash
git clone https://github.com/cyburke/hey-codex.git
cd hey-codex
./scripts/fetch-sherpa.sh
./scripts/fetch-models.sh
swift test
./scripts/build-release.sh
```

The bundle lands in `dist/HeyCodex.app`.

## Something broken?

[Open an issue.](https://github.com/cyburke/hey-codex/issues/new/choose) The template asks for the handful of details that make a report actionable. Please skip recordings and transcripts unless you are happy for them to be public.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the build steps and the handful of invariants worth not breaking, including why capture must stay input-only and why the app must never claim a Voice session started just because it posted an event.

Especially useful: a **notarized build** from anyone holding an Apple Developer ID, which would remove the Gatekeeper step for everyone.

## Credit

Hey Codex is a fork of **[littlemelon77/hey-claude](https://github.com/littlemelon77/hey-claude)**. The wake-word listener and the audio capture pipeline are that project's work, and this would not exist without it. Hey Codex rebuilds the activation logic, the setup flow, and the interface around ChatGPT Voice.

Wake-word detection uses [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) by Xiaomi Corporation, Apache-2.0. The bundled keyword-spotting model comes from the sherpa-onnx model releases under its own upstream licence. Full third-party attribution is in [NOTICE](NOTICE).

## Licence

**[GPL-3.0](LICENSE)**, inherited from the upstream project. In practice:

- You can use it, read it, modify it, and share it, commercially or not.
- If you distribute a modified version, it has to stay GPL-3.0 and you have to make your source available.
- There is no warranty. It presses a hotkey; if that goes wrong, that is on you.

Copyright for the modifications is Eliott Burke's; copyright for the original work remains littlemelon77's. Both are recorded in [NOTICE](NOTICE).

---

Not affiliated with, endorsed by, or connected to OpenAI. "ChatGPT" and the ChatGPT logo are trademarks of OpenAI, used here only to identify the application this tool works with.
