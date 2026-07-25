# Contributing to Hey Codex

Thanks for helping. Hey Codex is a GPL-3.0, local-first macOS menu-bar helper for the ChatGPT desktop Voice shortcut.

## Development setup

```bash
./scripts/fetch-sherpa.sh
./scripts/fetch-models.sh
swift build --product HeyCodexApp -c debug
swift run hey-codex-selftest all
```

Use `./scripts/build-release.sh` to make a self-contained `dist/HeyCodex.app`. It embeds the models; do not distribute a bundle containing a source-checkout model symlink.

## Product invariants

- All wake-word processing and enrollment remain local.
- Never inject Command–V. The release default is `⌃⌥V`, and the user-configured chord must match ChatGPT desktop’s Voice shortcut.
- Do not launch or focus ChatGPT. The helper only posts the configured global shortcut.
- Preserve the one-shot activation latch. Repeated wake phrases must never toggle an open Voice session off.
- Capture input only. `AudioCapture` is built on `AVCaptureSession`, not `AVAudioEngine`, because AVAudioEngine on macOS spans the default input *and* output and makes CoreAudio build a running aggregate device over both. On hardware where one device serves both directions that disturbed the user's audio output. `swift run hey-codex-selftest audio-footprint` fails if capture creates any device; do not regress it.
- Never claim a Voice session started because an event was posted. `VoicePanelObserver` confirms against ChatGPT's own panel, and `VoiceDetectionTrust` keeps that strictly additive so an install that cannot observe the panel behaves exactly as it did before detection existed.
- Preserve GPL-3.0 and clear attribution to the upstream Hey Claude project.

## Tests

`swift test` retains the XCTest suite for CI/Xcode, but a Command Line Tools installation may not provide XCTest. In that environment run the checked-in harness instead:

```bash
swift run hey-codex-selftest all
```

Checks that need real hardware are opt-in and not part of `all`:

```bash
swift run hey-codex-selftest audio-footprint          # capture must not create audio devices
swift run hey-codex-selftest voice-panel              # Voice panel detection against a live ChatGPT
swift run hey-codex-selftest bundle-models dist/HeyCodex.app
```

Do not delete tests solely to obtain a green run. Add a focused test when changing wake enrollment, shortcut configuration, or the activation latch.

## Pull requests

Keep changes focused, explain privacy/permission implications, and avoid committing recordings, models, signing credentials, or notarization secrets. Contributions are licensed under GPL-3.0.
