# Hey Codex

**Say a phrase. Start ChatGPT Voice. Keep working in the app you are already using.**

Hey Codex is a local, open-source macOS menu-bar helper. It listens on your Mac for a wake phrase and posts one configurable global shortcut to the ChatGPT desktop app. It does not launch, focus, or automate another app’s windows.

Hey Codex is a GPL-3.0 fork of [littlemelon77/hey-claude](https://github.com/littlemelon77/hey-claude). It has been substantially adapted for ChatGPT Voice, including its menu-bar interface and local voice-activation latch. It is not affiliated with or endorsed by OpenAI.

## What it does

- Defaults to the wake phrase **“Hey Codex.”** Choose **“Hey ChatGPT,” “Hey Jarvis,”** or a custom phrase.
- Ships with a bundled **“Hey Codex”** wake phrase. Personal phrase enrollment is intentionally not part of this alpha until it has its own qualification path.
- After a wake, posts the dedicated default shortcut **Control–Option–V (`⌃⌥V`)**. This is deliberately not Command–V, so ordinary copy/paste is unaffected.
- Mirrors the hotkey rather than guessing. Hey Codex checks whether ChatGPT’s Voice panel is actually on screen, so saying **“Hey Codex”** while Voice is already open does nothing instead of closing it — including when you opened Voice yourself with the keyboard.
- End Voice however you like: close it in ChatGPT’s own panel, press the hotkey, or choose **End ChatGPT Voice & Re-arm** in the menu bar. Hey Codex notices and re-arms on its own. There is no “stop” phrase to remember.
- Detection is a bonus, never a dependency. It reads only which process owns an on-screen floating window — never window contents, position, size, or titles, and it needs no Screen Recording permission. Until Hey Codex has actually seen a Voice panel on your Mac it makes no assumptions at all, and if ChatGPT ever changes that panel it quietly falls back to simply sending the hotkey.

## Setup

1. Build or obtain `HeyCodex.app`, then move it to Applications if desired.
2. Open **ChatGPT desktop → Settings → Voice** and set its **Voice chat hotkey** to **Control–Option–V (`⌃⌥V`)**. You may choose another chord in Hey Codex Settings, but it must exactly match ChatGPT’s Voice chat hotkey. ChatGPT Voice starts from a new empty chat or task.
3. Launch Hey Codex. Its monochrome wake-signal icon appears in the menu bar. It is deliberately not a microphone, so it is distinct from macOS’s microphone-in-use indicator.
4. The focused setup window asks for **Microphone** access. Approve it to let Hey Codex listen locally for the wake phrase.
5. In that same window, choose **Enable ChatGPT Voice**. macOS asks for permission because Hey Codex must post the configured global shortcut. Choose the system prompt’s Settings option, enable **Hey Codex** in **System Settings → Privacy & Security → Accessibility**, then return to the app and run **Test ChatGPT Voice**.
6. Say your phrase. End Voice in ChatGPT’s panel, with the hotkey, or via **End ChatGPT Voice & Re-arm** in the menu — Hey Codex re-arms itself either way.

The menu bar shows the current state, Settings, the explicit **End ChatGPT Voice & Re-arm** control while Voice is active, local update status, and Quit. First-run setup controls disappear after the shortcut permission is confirmed. The current local build does not check online or install updates automatically.

### First-run permission experience

Hey Codex asks only for the two capabilities it needs:

- **Microphone** on first listening attempt, so it can process the wake phrase locally.
- **Permission to post keyboard events** during visible first-run setup. macOS displays this narrow permission in its Accessibility pane.

Both permissions are controlled and remembered by macOS for a stable, signed app. You can revoke either one later in System Settings. A local ad-hoc build that is replaced after each rebuild may be treated as a new app by macOS and prompt again; signed releases do not have that development limitation.

## Privacy and limitations

Wake-word processing happens locally on your Mac. Hey Codex does not send audio or wake-phrase recordings to a server.

Once the shortcut starts ChatGPT Voice, ChatGPT operates according to its own settings and policies. Hey Codex does not inspect its session state. Re-arm Voice is manual by design: it prevents a repeated wake phrase from posting the toggle shortcut and ending an active Voice chat.

Like all wake-word helpers, it can miss phrases or trigger falsely in noisy conditions. The bundled phrase is qualified before release; personal phrase enrollment is deferred from this alpha.

## Build from source

Requirements: macOS 14.4+, Swift 6 / Xcode command-line tools, and the local speech models.

```bash
./scripts/fetch-sherpa.sh
./scripts/fetch-models.sh
swift build --product HeyCodexApp -c release
swift run hey-codex-selftest all
./scripts/build-release.sh
```

The release bundle is written to `dist/HeyCodex.app`. It includes the models and license notices. Without `HEYCODEX_SIGN_ID` it is ad-hoc signed, **not notarized**; Gatekeeper may require Control-click → Open. A Developer ID signature improves identity stability but notarization still requires the distributor’s Apple credentials and separate notarization work.

For a local macOS permission test, use a stable Apple Development identity rather than an ad-hoc build:

```bash
HEYCODEX_SIGN_ID='Apple Development: Your Name (TEAMID)' ./scripts/build-signed-local.sh
```

The signed local-test script deliberately refuses an ad-hoc fallback. Public releases require a Developer ID Application signature and notarization.

## Reporting bugs

Please open an issue with:

- macOS version and Hey Codex version;
- the bundled wake phrase version;
- whether the menu said listening, shortcut sent, or latched;
- whether Microphone and Accessibility were enabled;
- the exact configured ChatGPT Voice shortcut (do not include private recordings).

Do not share microphone recordings or transcripts unless you are comfortable making them public.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). Hey Codex is licensed under [GPL-3.0](LICENSE). See [NOTICE](NOTICE) for upstream and dependency attribution. Distributions of modified versions must preserve the license and provide corresponding source as required by GPL-3.0.
