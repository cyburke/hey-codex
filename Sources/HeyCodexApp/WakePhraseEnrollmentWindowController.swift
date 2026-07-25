import AppKit
import HeyCodexKit

/// A small, local-only three-recording enrollment flow. It intentionally stops
/// the listener while AVAudioEngine owns the microphone, then hands the tuned
/// keyword lines back to AppController before listening resumes.
@MainActor
final class WakePhraseEnrollmentWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let controller: AppController
    private let finished: () -> Void
    private let phraseField: NSTextField
    private let progress = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Record It Three Times", target: nil, action: nil)
    private var recorder: EnrollmentRecorder?
    private var samples: [WakeEnrollment.Sample] = []
    private var didFinish = false
    /// Whether the wake listener was running when enrollment began, so it can
    /// be put back exactly as it was.
    private var resumeListening = false
    private var presetPicker: NSPopUpButton?

    init(controller: AppController, initialPhrase: String, finished: @escaping () -> Void) {
        self.controller = controller
        self.finished = finished
        phraseField = NSTextField(string: initialPhrase)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Enroll Wake Phrase"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildView() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
        window.contentView = root

        let title = NSTextField(labelWithString: "Pick your own wake phrase")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        root.addArrangedSubview(title)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "Type anything you like, then say it three times so Hey Codex learns how you say it. Those recordings are used here on your Mac and then discarded."))
        let presets = NSPopUpButton(frame: .zero, pullsDown: false)
        presets.addItems(withTitles: WakePhrase.presets)
        presets.addItem(withTitle: "Custom…")
        let current = phraseField.stringValue
        presets.selectItem(withTitle: WakePhrase.presets.contains(current) ? current : "Custom…")
        presets.target = self
        presets.action = #selector(choosePreset(_:))
        self.presetPicker = presets
        phraseField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let phraseRow = NSStackView(views: [phraseField, presets])
        phraseRow.orientation = .horizontal
        phraseRow.spacing = 10
        root.addArrangedSubview(phraseRow)
        detail.textColor = .secondaryLabelColor
        detail.stringValue = "Truly anything: “Hey Jarvis”, “Hey Computer”, “Yo Robot”, your cat's name. Two or three words works best, since single words tend to go off by accident."
        detail.maximumNumberOfLines = 0
        root.addArrangedSubview(detail)
        progress.font = .systemFont(ofSize: 14, weight: .medium)
        progress.stringValue = "Ready when you are"
        root.addArrangedSubview(progress)
        startButton.target = self
        startButton.action = #selector(start)
        // Default button: macOS tints it with the accent colour and binds Return.
        // This is the window's only real action, so it should always read as such.
        startButton.keyEquivalent = "\r"
        phraseField.delegate = self
        let buttons = NSStackView(views: [startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        if controller.hasEnrolledWakePhrase {
            let reset = NSButton(title: "Go Back to “Hey Codex”", target: self, action: #selector(resetToDefault))
            reset.bezelStyle = .rounded
            buttons.addArrangedSubview(reset)
        }
        root.addArrangedSubview(buttons)
        refreshPendingState()
    }

    /// Suggestions only fill the field - every phrase, preset or not, still has
    /// to be recorded. The keyword comes from this user's voice, so there is no
    /// such thing as a preset that skips enrollment.
    @objc private func choosePreset(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, title != "Custom…" else { return }
        phraseField.stringValue = title
        refreshPendingState()
    }

    func controlTextDidChange(_ obj: Notification) { refreshPendingState() }

    /// Picking a suggestion changes nothing on its own - the phrase only becomes
    /// real after it is recorded. Say so the moment the field diverges from the
    /// phrase that is actually active, so nobody closes the window believing
    /// they switched.
    private func refreshPendingState() {
        let typed = phraseField.stringValue.trimmingCharacters(in: .whitespaces)
        let active = controller.settings.wakePhrase
        let pending = !typed.isEmpty
            && typed.compare(active, options: .caseInsensitive) != .orderedSame
        startButton.title = pending ? "Record “\(typed)” Three Times" : "Record It Three Times"
        progress.textColor = pending ? .controlAccentColor : .labelColor
        progress.stringValue = pending
            ? "“\(typed)” is not live yet. Record it three times to make the switch."
            : "Ready when you are"
    }

    @objc private func start() {
        guard let phrase = WakePhrase.normalize(phraseField.stringValue) else {
            progress.stringValue = "Keep it between one and five words, up to 48 characters."
            return
        }
        if !WakePhrase.isRecommended(phrase) {
            detail.stringValue = "Single words tend to fire when you did not mean them. You can carry on, but two or three words will treat you better."
        }
        phraseField.isEnabled = false
        startButton.isEnabled = false
        samples.removeAll()
        // The wake listener and the enrollment recorder cannot both own the
        // microphone. Stop listening for the duration and restore it after.
        resumeListening = controller.isListening
        controller.stopListening()
        recordNext()
    }

    private func recordNext() {
        guard samples.count < 3 else { finishEnrollment(); return }
        guard let models = controller.modelsDirectory else {
            progress.stringValue = "The speech model is missing from this build. Close this window and reinstall Hey Codex."
            return
        }
        let kwsModel = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        // Prompt only once the engine is running. Announcing "say it now" before
        // AVAudioEngine has produced a buffer invites the user to speak into a
        // microphone that is not listening yet, which reads as a failed capture
        // and makes them repeat themselves.
        progress.textColor = .secondaryLabelColor
        progress.stringValue = "Warming up the microphone…"
        let kind: WakeEnrollment.Sample.Kind = samples.count < 2 ? .isolated : .natural
        let recorder = EnrollmentRecorder(endpointSilenceMs: controller.settings.endpointSilenceMs)
        self.recorder = recorder
        do {
            try recorder.record(
                onSpeechStart: { [weak self] in
                    Task { @MainActor in self?.progress.stringValue = "Listening…" }
                },
                onClip: { [weak self] clip in
                    Task { @MainActor in self?.accept(clip, kind: kind, models: kwsModel) }
                })
            let index = samples.count + 1
            let phrase = phraseField.stringValue
            // Short settle for the first buffers to arrive before prompting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.recorder === recorder else { return }
                self.progress.textColor = .labelColor
                self.progress.stringValue = "Recording \(index) of 3, say “\(phrase)” now"
            }
        } catch {
            progress.textColor = .systemRed
            progress.stringValue = "The microphone is not available: \(error.localizedDescription)"
            startButton.isEnabled = true
        }
    }

    private func accept(_ clip: [Float], kind: WakeEnrollment.Sample.Kind, models: URL) {
        recorder?.stop()
        recorder = nil
        progress.stringValue = "Checking that one…"
        Task.detached { [weak self] in
            let tokens = KwsDebug.decodeTokens(modelDir: models, samples: clip).tokens
            let usable = WakeEnrollment.isPlausibleWake(tokens: tokens)
            await MainActor.run {
                guard let self else { return }
                if usable {
                    self.samples.append(.init(audio: clip, kind: kind))
                    self.progress.stringValue = "Got it. \(self.samples.count) of 3 recorded"
                } else {
                    self.progress.textColor = .systemOrange
                    self.progress.stringValue =
                        "Did not quite catch that. Say the whole phrase at a normal pace, then pause for a moment."
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run { self?.recordNext() }
        }
    }

    private func finishEnrollment() {
        guard let models = controller.modelsDirectory else { return }
        let kwsModel = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        progress.stringValue = "Tuning the local keyword…"
        let captured = samples
        let score = controller.settings.wakeKeywordsScore
        let phrase = phraseField.stringValue
        let fallbackLine = (try? String(contentsOf: models.appendingPathComponent("keywords.txt"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map(String.init)
        Task.detached { [weak self] in
            let enrollment = WakeEnrollment(
                decode: { KwsDebug.decodeTokens(modelDir: kwsModel, samples: $0).tokens },
                fires: { lines, threshold, audio in
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("hey-codex-enrollment-\(UUID().uuidString).txt")
                    defer { try? FileManager.default.removeItem(at: file) }
                    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                    guard let engine = try? WakeWordEngine(
                        modelDir: kwsModel,
                        keywordsFile: file,
                        keywordsThreshold: threshold,
                        keywordsScore: score)
                    else { return false }
                    return engine.detects(in: audio)
                },
                fallbackLine: fallbackLine)
            let result = enrollment.enroll(samples: captured)
            await MainActor.run {
                guard let self else { return }
                guard result.allFired else {
                    self.progress.stringValue = "Those three did not come out consistent enough to trust. Give it another go, a little slower."
                    self.phraseField.isEnabled = true
                    self.startButton.isEnabled = true
                    return
                }
                do {
                    try self.controller.completeEnrollment(phrase: phrase,
                                                          keywordLines: result.keywordLines,
                                                          threshold: result.threshold)
                    // The sweep takes the highest threshold that fires all three
                    // samples, so landing on the loosest rung means this phrase
                    // was hard to match - which is also when false wakes climb.
                    let barelyMatched = result.threshold <= 0.10
                    var body = "Hey Codex is already listening for it. Try it out, and change it whenever you like from the menu bar."
                    if barelyMatched {
                        body += "\n\nThis phrase needed maximum sensitivity to detect reliably, "
                            + "so it may occasionally wake by accident. A longer or more distinctive "
                            + "phrase usually matches more cleanly."
                    }
                    self.confirm(title: "“\(phrase)” is your wake phrase now 🎉", body: body)
                    self.complete()
                } catch {
                    self.progress.stringValue = error.localizedDescription
                    self.phraseField.isEnabled = true
                    self.startButton.isEnabled = true
                }
            }
        }
    }

    @objc private func resetToDefault() {
        do {
            try controller.resetWakePhraseToDefault()
            phraseField.stringValue = "Hey Codex"
            confirm(title: "Go Back to “Hey Codex”",
                    body: "Your recorded phrase is gone and the built in “Hey Codex” is listening again.")
            complete()
        } catch {
            progress.stringValue = error.localizedDescription
        }
    }

    /// Enrollment ends by closing the window, so a status label would only
    /// flash past. Say plainly what happened, in something the user dismisses.
    private func confirm(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    private func complete() {
        guard !didFinish else { return }
        didFinish = true
        recorder?.stop()
        restoreListening()
        close()
        finished()
    }

    /// Enrollment took the microphone away from the listener; give it back
    /// whether the user finished, cancelled, or closed the window.
    private func restoreListening() {
        guard resumeListening, !controller.isListening else { return }
        resumeListening = false
        controller.startListening()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        recorder?.stop()
        restoreListening()
        finished()
    }
}
