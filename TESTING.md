# Hey Codex release-test gates

Do not ask a tester to run a Voice check until the automated gates below pass.

## Automated gates

1. `swift test` passes.
2. `swift run hey-codex-selftest all` passes, including the wake-model negative and positive controls.
3. The release app is built from a clean source state, signature verification passes, and `git diff --check` is clean.
4. A regression check confirms the one-shot latch is consumed before either a wake or the Test action sends the Voice hotkey.

## One local manual session

Reset first, or none of this proves anything:

```bash
tccutil reset Microphone com.heycodex.app
tccutil reset Accessibility com.heycodex.app
mv ~/Library/Application\ Support/HeyCodex ~/Library/Application\ Support/HeyCodex.bak
```

1. **Discovery:** after launch the menu bar reads an orange `<Set up Hey Codex: step 1 of 2>`. Text, not a bare symbol.
2. **Microphone:** clicking it prompts, and afterwards the label advances to `step 2 of 2`. A label that does not change reads as failure.
3. **Accessibility:** clicking it prompts, then opens System Settings. Toggling Hey Codex on makes the app restart itself within a few seconds with no further clicks.
4. **Test:** the label sits on `<Ready: click to test>` indefinitely and does not expire. Choosing **Try It: Test ChatGPT Voice** opens Voice.
5. **Completion:** after that first verified launch the label turns green, names the phrase, and clears after about twenty seconds.
6. **Wake:** one spoken phrase opens Voice, on the first attempt.
7. **Foreground:** the same with ChatGPT itself frontmost.
8. **Repeat wake:** saying it again while Voice is open does nothing and must not hang up.
9. **Self re-arm:** closing Voice in ChatGPT returns the helper to listening within about a second, with nothing spoken.
10. **User-opened session:** open Voice with the hotkey, then say the phrase. Voice must stay open.
11. **Custom phrase:** enrol a multi-word phrase, confirm it wakes and the old one no longer does, then **Back to "Hey Codex"** and confirm the default works again.
12. **Enrollment returns the microphone:** after enrolling, and after cancelling mid-enrolment by closing the window, listening resumes without relaunching.
13. **No hidden off state:** the menu never offers a Stop or Pause listener action. Quitting is the only way to stop it.
14. **No crash reports:** `ls ~/Library/Logs/DiagnosticReports/HeyCodex*` is empty afterwards.

Record the exact ChatGPT desktop version and the pass/fail result for each gate before any public release decision.
