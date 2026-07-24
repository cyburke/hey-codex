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
- Preserve the local one-shot activation latch. ChatGPT has no supported Voice-session API; repeated wake phrases must remain harmless until the user explicitly chooses Re-arm Voice.
- Preserve GPL-3.0 and clear attribution to the upstream Hey Claude project.

## Tests

`swift test` retains the XCTest suite for CI/Xcode, but a Command Line Tools installation may not provide XCTest. In that environment run the checked-in harness instead:

```bash
swift run hey-codex-selftest all
```

Do not delete tests solely to obtain a green run. Add a focused test when changing wake enrollment, shortcut configuration, or the activation latch.

## Pull requests

Keep changes focused, explain privacy/permission implications, and avoid committing recordings, models, signing credentials, or notarization secrets. Contributions are licensed under GPL-3.0.
