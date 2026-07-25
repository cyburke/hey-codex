# Changelog

## 0.1.2

Setup and audio, both rebuilt after a full walkthrough on a clean machine found
real defects in each.

### Fixed

- **Capture no longer disturbs audio output.** `AudioCapture` used `AVAudioEngine`,
  which on macOS spans the default input *and* output and makes CoreAudio build a
  running aggregate device over both. On hardware where one device serves both
  directions, listening for a wake word activated the user's speakers. Rebuilt on
  `AVCaptureSession`, input only. Measured: devices 5 -> 6 before, 5 -> 5 after.
  Guarded by a new `audio-footprint` selftest.
- **Voice now opens when ChatGPT is the frontmost app.** Events were routed to
  ChatGPT's pid when it was in front, but Carbon hot keys are dispatched by the
  window server and `postToPid` bypasses it, so the hot key never fired. Always
  posts to the system HID tap now.
- **The lock icon no longer lies.** A posted event was treated as a started Voice
  session. It is now confirmed against ChatGPT's own Voice panel.
- **Relaunching releases the microphone first.** The post-permission relaunch
  started its replacement before letting go of the mic, so two instances briefly
  held the same input device.
- Menu rebuilds can no longer recurse into themselves, which crashed the app with
  a stack overflow when setup completed.
- Removed `com.apple.security.get-task-allow` from release builds. It allowed any
  process to attach a debugger to an always-listening app.
- The setup window no longer disappears behind other windows, which it did every
  time a macOS permission dialog took focus, with no Dock icon to get back to it.

### Added

- **A real setup window**, three steps: what the app does, both permissions with
  live state, then one test that confirms the hotkey matches ChatGPT. Reopenable
  from the menu as Setup & Diagnostics, because permissions get revoked.
- **Custom wake phrases.** Enrollment existed but was never wired up; the window
  it needed called a method that had never been implemented. Record a phrase three
  times and the keyword is derived from how the model hears your voice.
- Update checking against GitHub releases, once a day, switchable off in Settings.
  It is the only network request the app makes.
- Detection and a clear message when the ChatGPT desktop app is not installed.
- Structured GitHub issue template.

### Changed

- **No more close phrase.** Voice ends in ChatGPT's own panel and Hey Codex
  notices and re-arms. This deleted the second wake engine, the close keyword
  model, and the launch-versus-close arbitration entirely.
- **674 MB -> 30 MB.** The bundle shipped a 631 MB speech-to-text model nothing
  loads, plus unused model variants and an unstripped binary.
- Source tree renamed off the upstream Hey Claude names, except the deliberate
  migration path that reads an existing Hey Claude install's settings.
- Deleted dead code inherited from upstream that shipped in no target.


## 0.1.0

- First Hey Codex release: local wake-word helper for the ChatGPT desktop Voice shortcut.
- Menu-bar-only interface with settings and explicit Re-arm Voice. Personal phrase enrollment is deferred pending separate qualification.
- Default wake phrase is `Hey Codex`; `Hey ChatGPT` and `Hey Jarvis` are optional presets alongside custom phrases.
- Dedicated default shortcut `⌃⌥V`; no Command–V injection.
- Conservative local activation latch prevents repeated wake phrases from toggling an active Voice chat.
- GPL-3.0 fork attribution retained for littlemelon77/hey-claude.
