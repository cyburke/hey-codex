# Hey Codex release-test gates

Do not ask a tester to run a Voice check until the automated gates below pass.

## Automated gates

1. `swift test` passes.
2. `swift run hey-codex-selftest all` passes, including the wake-model negative and positive controls.
3. The release app is built from a clean source state, signature verification passes, and `git diff --check` is clean.
4. A regression check confirms the one-shot latch is consumed before either a wake or the Test action sends the Voice hotkey.

## One local manual session

1. **Test action:** Voice opens and remains active.
2. **Wake action:** after ending and re-arming, one “Hey Codex” opens Voice and the menu icon locks.
3. **Safety regression:** saying “Hey Codex” while that Voice chat is active does nothing; it must not toggle Voice off.
4. **Foreground activation:** with ChatGPT itself frontmost, one “Hey Codex” opens Voice.
5. **User-opened session:** open Voice yourself with the hotkey, then say “Hey Codex”; Voice must stay open.
6. **Self re-arm:** close Voice in ChatGPT’s own panel (or with the hotkey); within about a second Hey Codex returns to armed/listening with nothing spoken.
7. **Explicit end:** choose **End ChatGPT Voice & Re-arm** from Hey Codex’s menu; Voice ends and Hey Codex returns to armed/listening.
8. **No hidden off state:** while Hey Codex is running, the menu must not offer a Stop or Pause listener action. Quitting the app is the only way to stop the listener.

Record the exact ChatGPT desktop version and the pass/fail result for each gate before any public release decision.
