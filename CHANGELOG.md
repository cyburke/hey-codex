# Changelog

## 0.1.7

### Fixed

- **Hey Codex now starts when you log in.** It had no launch-at-login support at
  all, so a reboot left it silently absent until you noticed the menu bar icon was
  gone and opened it by hand. An app that listens for a wake phrase does nothing
  while it is not running. It registers once, after setup is complete, and appears
  in System Settings under General, Login Items.

### Added

- **Start at Login** in the menu, showing and controlling the same setting. If
  macOS refuses the registration the item greys out and says why, rather than
  showing a checkmark that is not true.

## 0.1.6

### Changed

- The setup page's permission guidance is short bullets instead of a paragraph,
  and it says why macOS is behaving oddly rather than only what to click. The
  Accessibility step in particular shows no dialog, which reads as nothing
  happening, so the page now says so.

## 0.1.5

Permissions now survive updates, and setup says which one is blocking it.

### Fixed

- **Microphone and Accessibility no longer break on every update.** An ad-hoc
  signature's designated requirement is the exact binary hash, so macOS treated
  each new build as a different app and silently voided both permissions while
  leaving the row visible and switched on in System Settings. Builds are now signed
  with a fixed self-signed certificate, whose requirement names the bundle and the
  certificate instead of the binary. Upgrading to this version costs one last
  re-grant; after that they stick. Nothing about Gatekeeper changes: the app is
  still unnotarized and Homebrew still clears the quarantine flag.
- **Setup cannot dead-end on Accessibility.** Requesting access does nothing at
  all once macOS holds any decision for the app, including a row switched off, so
  the Allow button was silently inert and the page waited forever. It now
  recognises that state and says to remove the entry and grant it again.
- **The permissions page names the permission that is blocking Continue.** With
  the microphone outstanding it gave no indication that the microphone, not
  Accessibility, was the gate.

## 0.1.4

Setup could strand you on the permissions step with Accessibility switched on.

### Fixed

- **Setup no longer dead-ends when macOS has a stale Accessibility grant.** The
  app is listed and switched on, but macOS binds that authorization to a specific
  build, so replacing the app can leave a row that looks enabled and no longer
  applies. Setup showed the row as granted, kept Continue disabled, and relied on
  a single automatic relaunch that cannot fix this. It now says what happened and
  sends you to the right pane to remove the entry and grant it again.
- A permission row no longer reads as granted while the button it gates is
  disabled.

### Changed

- The README says how to end a Voice session by asking ChatGPT Voice to close it.

## 0.1.3

Setup copy, after watching a first run on a clean machine.

### Fixed

- The welcome page named whichever phrase you had enrolled, so someone who had
  switched to "Hey Jarvis" was told it listens for "Hey Jarvis" on the same page
  that offers "Hey Jarvis" as the example of a custom phrase. It names the
  default now.
- Setup body text had no line spacing, so a list of four points ran together.

### Changed

- Plainer opening line on the welcome page, and the custom-phrase point says
  where to change it.

## 0.1.2

Setup and audio, both rebuilt after a full walkthrough on a clean machine found
real defects in each.

### Fixed

- **Enrollment no longer looks frozen.** Calibration used to build a fresh
  detector per clip per threshold; it now reuses one per (keyword, threshold)
  pair, and the window shows what it is doing (recording, checking, tuning)
  instead of sitting blank.
- **Quiet microphones no longer silently fail enrollment.** A recording well
  below the model's reference level is boosted toward it before calibration,
  capped short of clipping, rather than being sent through unchanged and
  coming back as an unexplained rejection.
- **Wake word fires with less delay.** A measured tuning pass found the
  keyword score and trailing-blank settings had been over-corrected; lowering
  both keeps the same zero-false-alarm result with less latency.
- **Capture no longer disturbs your audio output.** On some hardware, listening for
  a wake word could activate the speakers. Capture now touches the microphone and
  nothing else, guarded by a test.
- **Voice now opens when ChatGPT is the frontmost app.**
- **The lock icon no longer lies.** A posted event was treated as a started Voice
  session. It is now confirmed against ChatGPT's own Voice panel.
- **Relaunching releases the microphone first**, so two instances never hold the
  input device at once.
- Menu rebuilds can no longer recurse into themselves, which crashed the app with
  a stack overflow when setup completed.
- Removed `com.apple.security.get-task-allow` from release builds. It allowed any
  process to attach a debugger to an always-listening app.
- The setup window no longer disappears behind other windows, which it did every
  time a macOS permission dialog took focus, with no Dock icon to get back to it.

### Added

- **A custom phrase that does not fire tries alternatives automatically.**
  If the exact spelling never fires cleanly against your recordings, Hey
  Codex tries a couple of related spellings, such as the phrase with a
  leading "hey" dropped, before giving up. It tells you when it has armed
  something other than what you typed.
- **Microphone selection.** Settings lists every connected input, with Automatic
  following whatever the Mac is set to. Automatic watches
  `kAudioHardwarePropertyDefaultInputDevice`, since connect and disconnect
  notifications alone miss the common case of switching input while both devices
  are attached. A pinned device that gets unplugged falls back so the app keeps
  working, keeps the preference, and resumes when it returns.
- **Starts ChatGPT when it is closed.** ChatGPT registers its Voice hotkey with
  Carbon at launch, so with the app closed a press reaches nothing at all. Hey
  Codex now launches it, waits for it to finish starting, and then presses.
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

- Enrollment diagnostics (a log of tokens, timings, and per-threshold
  results) remain off by default. Nothing is written unless a marker file is
  created by hand; there is still no UI path to it.
- **Homebrew is the install path.** The cask clears the quarantine flag, so the
  app opens with no security prompt. Downloading the zip by hand still works but
  is no longer documented as a route, since macOS blocks it until the user
  approves the app in System Settings and there is nothing an unnotarized build
  can do about that. Building from source is offered instead, for anyone who
  would rather read the code first.
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
