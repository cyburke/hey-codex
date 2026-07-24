# Hey Codex

**Say “Hey Codex.” ChatGPT Voice opens. That's the whole tool.**

Hey Codex is a small, open-source macOS menu-bar app. It listens on your Mac for a wake phrase and presses the same ChatGPT Voice hotkey you'd press yourself — so Voice becomes hands-free without you touching the keyboard.

It does not record you, does not send audio anywhere, and does not automate or drive the ChatGPT app. It presses one hotkey.

Not affiliated with or endorsed by OpenAI.

## Install

### Homebrew

```bash
brew install --cask --no-quarantine cyburke/tap/hey-codex
```

The `--no-quarantine` flag is required because this app is not notarized — see [Why the security warning](#why-the-security-warning) below.

### Direct download

1. Download `HeyCodex.app.zip` from the [latest release](https://github.com/cyburke/hey-codex/releases/latest) (about 18 MB).
2. Unzip it and drag **HeyCodex.app** to your Applications folder.
3. Open it. macOS will refuse the first time.
4. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Hey Codex message. Confirm.

You only do step 4 once.

## Setup

1. In **ChatGPT → Settings → Voice**, note or set the **Voice chat hotkey**. The default Hey Codex expects is **⌃⌥V** (Control-Option-V). If you use a different chord, set the same one in Hey Codex's Settings — they must match, because Hey Codex is simply pressing that hotkey for you.
2. Launch Hey Codex. A small wake-signal icon appears in your menu bar. It is deliberately not a microphone icon, so you can tell it apart from macOS's own mic-in-use indicator.
3. Approve **Microphone** access when the setup window asks. This is what lets Hey Codex hear the wake phrase locally.
4. Choose **Enable ChatGPT Voice** in the same window. macOS asks for Accessibility permission — that's what allows Hey Codex to press a hotkey. Enable **Hey Codex** in **System Settings → Privacy & Security → Accessibility**, come back, and run **Test ChatGPT Voice**.
5. Say **“Hey Codex.”**

To end a Voice session, just close it in ChatGPT like you normally would — click away, press the hotkey, or tell it you're done. Hey Codex notices and starts listening again on its own. There's no "stop" phrase to remember.

## How it behaves

- **Saying the phrase while Voice is already open does nothing.** It won't hang up on you — including when you opened Voice yourself with the keyboard.
- **It re-arms by itself** when Voice ends, however it ended.
- **It works whether or not ChatGPT is the frontmost app.**
- **It listens for one phrase and nothing else.** While a Voice session is open it isn't even listening, so your conversation can't trigger it.

### Your own wake phrase

“Hey Codex” works out of the box. To use something else, choose **Use My Own Wake Phrase…** from the menu bar, type a phrase, and say it three times.

Those three recordings never leave your Mac. They're used to derive the keyword from the tokens the speech model *actually emits for your voice*, then the detection threshold is tuned down until all three of your recordings fire. That's why enrollment beats picking from a list: a keyword guessed from spelling matches a generic speaker, not you.

Multi-word phrases are strongly recommended — single words trigger accidentally. **Back to “Hey Codex”** in the same window undoes it at any time.

### How it knows

ChatGPT has no API for "is Voice open," so Hey Codex checks whether ChatGPT's own process currently owns a floating window that's on screen. That's all it reads — not the window's contents, title, position, or size — and it needs no Screen Recording permission.

This is treated as a bonus, never a dependency. Until Hey Codex has actually seen a Voice panel on your Mac, it assumes nothing. If OpenAI ever restructures that panel, Hey Codex quietly falls back to just sending the hotkey, the way it worked before. It degrades; it doesn't break.

## Privacy

Wake-word detection runs entirely on your Mac using a bundled offline model. No audio, no transcripts, and no wake events ever leave your machine. There is no analytics and no telemetry.

Hey Codex makes exactly one kind of network request: a once-a-day check with GitHub asking whether a newer release exists. It sends nothing about you. Turn off **Check for updates automatically** in Settings and the app makes no network requests at all.

The two permissions it asks for are the two it needs: **Microphone**, to hear the phrase, and **Accessibility**, to press the hotkey. You can revoke either in System Settings at any time.

Once Voice starts, ChatGPT does whatever ChatGPT does, under its own settings and privacy policy. That part is between you and OpenAI.

## Why the security warning

Hey Codex is not notarized by Apple. Notarization requires a paid Apple Developer account, and this is a free tool.

That means macOS Gatekeeper flags it on first launch. It's not a claim that the app is unsafe — it's a claim that Apple hasn't been paid to vouch for it. The source is all here; you can read it or build it yourself.

If someone with an Apple Developer ID wants to contribute a notarized build, open an issue.

## Known limitations

- **Updates are not automatic.** Hey Codex tells you when a new release exists, but you install it yourself by re-downloading or running `brew upgrade hey-codex`.
- **Upgrading may re-prompt for permissions.** Because the app isn't signed with a stable Apple identity, macOS can see a new build as a new app and ask for Microphone and Accessibility again. Annoying, not broken.
- Like every wake-word tool, it can occasionally miss the phrase or fire on something that sounds close.

## Build from source

Requirements: macOS 14.4 or later, and Swift 6 (Xcode or the Command Line Tools).

```bash
./scripts/fetch-sherpa.sh
./scripts/fetch-models.sh
swift build --product HeyCodexApp -c release
swift test
./scripts/build-release.sh
```

The bundle is written to `dist/HeyCodex.app` (~30 MB) with an ad-hoc signature. To build with a stable Apple Development identity for permission testing:

```bash
HEYCODEX_SIGN_ID='Apple Development: Your Name (TEAMID)' ./scripts/build-signed-local.sh
```

`scripts/fetch-models.sh` skips a large optional speech model that only the developer decode probes use. Set `HEYCODEX_FETCH_ASR=1` if you need it.

## Reporting bugs

Open an issue with your macOS version, the Hey Codex version, what the menu-bar item said at the time, whether Microphone and Accessibility were enabled, and the exact hotkey configured in both apps.

Please don't attach recordings or transcripts unless you're comfortable making them public.

## Credit and license

Hey Codex is a GPL-3.0 fork of **[littlemelon77/hey-claude](https://github.com/littlemelon77/hey-claude)** — the original wake-word listener, audio capture pipeline, and app skeleton are that project's work. Hey Codex rebuilds the activation logic and interface around ChatGPT Voice, but it stands on that foundation.

Licensed under [GPL-3.0](LICENSE). See [NOTICE](NOTICE) for full upstream and dependency attribution. Modified versions must stay GPL-3.0 and provide corresponding source.
