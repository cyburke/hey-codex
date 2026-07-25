import AppKit
import HeyCodexKit

/// A small, local-only three-recording enrollment flow. It intentionally stops
/// the listener while the recorder owns the microphone, then hands the tuned
/// keyword lines back to AppController before listening resumes.
@MainActor
final class WakePhraseEnrollmentWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let controller: AppController
    private let finished: () -> Void
    private let phraseField: NSTextField
    private let progress = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    /// Real, honest activity feedback: spins whenever work is happening off the
    /// main thread (the fitness check, tuning) so a multi-second stage never
    /// reads as a hang. Indeterminate only - there is no percentage to compute
    /// for either stage, so this never fakes one (AUDIT-2026-07-24.md).
    private let spinner = NSProgressIndicator()
    private let startButton = NSButton(title: "Record It Three Times", target: nil, action: nil)
    private var recorder: EnrollmentRecorder?
    private var samples: [WakeEnrollment.Sample] = []
    private var didFinish = false
    /// Whether the wake listener was running when enrollment began, so it can
    /// be put back exactly as it was.
    private var resumeListening = false
    private var presetPicker: NSPopUpButton?
    private var didSucceed = false
    /// Whether the user has already been warned that this phrase looks unlikely to
    /// work and chose to record it anyway.
    private var acknowledgedRisk = false
    /// The fitness check's last verdict for the phrase being recorded, so a failed
    /// enrollment can tell an unspottable phrase apart from a mic or delivery
    /// problem. Defaults to `.good` when the check never ran (no models directory).
    private var lastFitnessVerdict: WakePhraseFitness.Verdict = .good
    private let titleLabel = NSTextField(labelWithString: "Pick your own wake phrase")

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

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "Type a phrase, then say it three times so Hey Codex learns your voice. Recordings stay on this Mac and are discarded afterward."))
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
        detail.stringValue = "Short phrases work best: “Hey Jarvis”, “Wake Up Codex”, or your own name. Two or three words beats one word, since single words fire by accident more."
        detail.maximumNumberOfLines = 0
        root.addArrangedSubview(detail)
        progress.font = .systemFont(ofSize: 14, weight: .medium)
        progress.maximumNumberOfLines = 0
        progress.preferredMaxLayoutWidth = 400
        progress.lineBreakMode = .byWordWrapping
        progress.widthAnchor.constraint(equalToConstant: 400).isActive = true
        progress.stringValue = "Ready when you are"
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let progressRow = NSStackView(views: [progress, spinner])
        progressRow.orientation = .horizontal
        progressRow.alignment = .firstBaseline
        progressRow.spacing = 8
        root.addArrangedSubview(progressRow)
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
        // A button that says Record must record. Finishing an enrollment, or
        // resetting to the bundled phrase, repoints this button at "Done"; typing
        // or picking a phrase afterwards has to point it back, or the window just
        // closes when you ask it to record.
        startButton.target = self
        startButton.action = #selector(start)
        acknowledgedRisk = false
        didSucceed = false
        startButton.title = pending ? "Record “\(typed)” Three Times" : "Record It Three Times"
        progress.textColor = pending ? .controlAccentColor : .labelColor
        progress.stringValue = pending
            ? "“\(typed)” isn’t live yet. Record it three times to switch."
            : "Ready when you are"
    }

    @objc private func start() {
        guard let phrase = WakePhrase.normalize(phraseField.stringValue) else {
            progress.stringValue = "Keep it between one and five words, up to 48 characters."
            return
        }
        if !WakePhrase.isRecommended(phrase) {
            detail.stringValue = "Single words fire by accident more often. Two or three words work better, but you can carry on."
        }
        phraseField.isEnabled = false
        startButton.isEnabled = false
        samples.removeAll()
        checkFitness(of: phrase)
    }

    /// Start/stop the spinner together with the busy state it represents, so
    /// there is exactly one place that can leave it spinning forever by mistake.
    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Try the phrase before asking anyone to say it three times, and say what
    /// happened — but never refuse.
    ///
    /// The check speaks the phrase with `say` and tests the real keyword, which
    /// catches phrases like "Hey Xena" that no amount of recording will fix. It is a
    /// synthesized voice though, not this user's: it says "hey chatgpt" in a way the
    /// model hears as "HEY CHAT GP", losing the final letter, so it condemns a
    /// perfectly sayable phrase. Its verdict is therefore a warning, and the three
    /// real recordings decide.
    private func checkFitness(of phrase: String) {
        guard let models = controller.modelsDirectory else {
            lastFitnessVerdict = .good
            beginRecording()
            return
        }
        let kwsModel = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        progress.textColor = .secondaryLabelColor
        // The negatives this check screens against are cached on disk after the
        // first run ever (see SynthesizedSpeech), so only the genuinely slow
        // first run gets told it is slow - every run after is honestly quick.
        progress.stringValue = SynthesizedSpeech.negativesCached
            ? "Checking that phrase…"
            : "Getting set up, one moment…"
        setBusy(true)

        Task.detached { [weak self] in
            let cache = WakeEngineCache(modelDir: kwsModel)
            let verdict = WakePhraseFitness.check(
                tokens: KeywordTokenizer.tokenize(phrase, modelDir: kwsModel) ?? "",
                spoken: SynthesizedSpeech.samples(of: phrase),
                negatives: SynthesizedSpeech.falseAlarmClips(),
                thresholds: KeywordTuning.fitnessCheckThresholds,
                fires: { line, threshold, audio in cache.fires(line, threshold: threshold, audio: audio) })
            await MainActor.run {
                guard let self else { return }
                self.setBusy(false)
                self.lastFitnessVerdict = verdict
                switch verdict {
                case .good:
                    self.beginRecording()
                case .cannotSpot:
                    // Name the real cause when there is one (AUDIT-2026-07-24.md):
                    // this model has no way to spell a word starting with X or Z.
                    // Still just a warning - record it and see, and a shorter
                    // spelling of the same phrase may work even when the full
                    // phrase does not.
                    let reason = WakePhraseFitness.startsWithUnspellableLetter(phrase)
                        ? " This model can’t spell words starting with X or Z."
                        : ""
                    self.warn("“\(phrase)” didn’t register in a quick test.\(reason) Your voice may still work. Record it and see.")
                case .tooCommon:
                    self.warn("“\(phrase)” sounds like ordinary conversation. It might open Voice while you’re just talking.")
                }
            }
        }
    }

    /// Warn once, then get out of the way: pressing the button again records.
    private func warn(_ message: String) {
        guard !acknowledgedRisk else { beginRecording(); return }
        acknowledgedRisk = true
        progress.attributedStringValue = hint(message + " Or press Record It Anyway.",
                                              bold: ["Record It Anyway"], color: .systemOrange)
        phraseField.isEnabled = true
        startButton.isEnabled = true
        startButton.title = "Record It Anyway"
    }

    private func beginRecording() {
        // The wake listener and the enrollment recorder cannot both own the
        // microphone. Stop listening for the duration and restore it after.
        resumeListening = controller.isListening
        controller.stopListening()
        recordNext()
    }

    /// Builds hint text with named buttons set in bold, so the reader can tell
    /// an instruction from the button name it refers to. Same pattern as
    /// `SetupWindowController.hint(_:bold:)`, with a color parameter added
    /// since this window's progress label changes color per state (warning,
    /// success, error) and an attributed string carries its own color per run,
    /// so setting `.textColor` afterward would not touch it.
    private func hint(_ text: String, bold: [String], color: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: color,
        ])
        for phrase in bold {
            var range = (text as NSString).range(of: phrase)
            while range.location != NSNotFound {
                attributed.addAttribute(.font,
                                        value: NSFont.systemFont(ofSize: 14, weight: .bold),
                                        range: range)
                let next = NSRange(location: range.location + range.length,
                                   length: (text as NSString).length - range.location - range.length)
                range = (text as NSString).range(of: phrase, options: [], range: next)
            }
        }
        return attributed
    }

    private func recordNext() {
        guard samples.count < 3 else { finishEnrollment(); return }
        guard let models = controller.modelsDirectory else {
            progress.stringValue = "The speech model is missing from this build. Close this window and reinstall Hey Codex."
            return
        }
        let kwsModel = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        // Prompt only once capture is running. Announcing "say it now" before the
        // first buffer has arrived invites the user to speak into a microphone
        // that is not listening yet, which reads as a failed capture and makes
        // them repeat themselves.
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
                    self.progress.stringValue = "Didn’t quite catch that. Say the phrase at a normal pace, then pause."
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run { self?.recordNext() }
        }
    }

    private func finishEnrollment() {
        guard let models = controller.modelsDirectory else { return }
        let kwsModel = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        let phrase = phraseField.stringValue

        progress.textColor = .labelColor
        progress.stringValue = SynthesizedSpeech.negativesCached
            ? "Tuning it to your voice…"
            : "Getting set up, one moment…"
        setBusy(true)
        let captured = samples.map(\.audio)

        Task.detached { [weak self] in
            // One engine per (line, threshold), reused across every clip tested
            // against it, instead of a fresh engine per clip - see
            // WakeEngineCache for the measurement and the reuse-safety check.
            let cache = WakeEngineCache(modelDir: kwsModel)
            let calibration = WakeCalibration(fires: { line, threshold, audio in
                cache.fires(line, threshold: threshold, audio: audio)
            })
            let tokenize: (String) -> String? = { KeywordTokenizer.tokenize($0, modelDir: kwsModel) }
            // Screened once, against every candidate: MANDATORY SAFETY per
            // AUDIT-2026-07-24.md - nothing gets armed without first proving it
            // stays quiet on ordinary speech.
            let negatives = SynthesizedSpeech.falseAlarmClips()
            let search = WakeCandidateSearch.search(
                phrase: phrase, samples: captured, negatives: negatives, tokenize: tokenize,
                calibration: calibration,
                onCandidate: { candidate in
                    Task { @MainActor [weak self] in
                        self?.progress.stringValue = "Tuning “\(candidate)”…"
                    }
                })

            // Diagnostics always have *something* to report against, even when no
            // candidate became usable: the phrase's own spelling if it tokenizes,
            // otherwise the first candidate that does. Without this, a rejected
            // enrollment of an unspellable phrase leaves no trail to explain it.
            let candidatePhrases = WakeCandidateSearch.candidatePhrases(for: phrase)
            let diagnosticTokens = search?.candidate.tokens
                ?? tokenize(phrase)
                ?? candidatePhrases.lazy.compactMap(tokenize).first
                ?? ""
            EnrollmentDiagnostics.saveAudioIfEnabled(captured)
            // Diagnosed fire count for the failure message: how well the best
            // reported spelling actually did against these takes, not a bare
            // hardcoded zero. `search` being nil does not mean nothing ever
            // fired - it means nothing fired ENOUGH (isUsable) or safely
            // (the false-alarm screen); this is still worth telling apart
            // from a phrase this model cannot spell at all.
            var failedFiredCount = 0
            if search == nil, !diagnosticTokens.isEmpty {
                let grid = EnrollmentDiagnostics.grid(
                    lines: [diagnosticTokens],
                    thresholds: KeywordTuning.calibrationThresholds,
                    samples: captured,
                    fires: { line, threshold, audio in
                        calibration.fires(WakeCalibration.keywordLine(tokens: line, threshold: threshold),
                                          threshold, audio)
                    })
                let failed = calibration.calibrate(tokens: diagnosticTokens, samples: captured)
                failedFiredCount = failed.firedCount
                EnrollmentDiagnostics.record(phrase: phrase, tokens: diagnosticTokens,
                                             sampleCounts: captured.map(\.count), grid: grid,
                                             result: failed)
            } else if let search {
                EnrollmentDiagnostics.record(phrase: phrase, tokens: search.candidate.tokens,
                                             sampleCounts: captured.map(\.count), grid: "",
                                             result: search.calibration)
            }

            await MainActor.run {
                guard let self else { return }
                self.setBusy(false)
                guard let search else {
                    self.progress.textColor = .systemOrange
                    self.progress.stringValue = diagnosticTokens.isEmpty
                        ? "This model can’t spell that phrase. Try different words."
                        : self.failureMessage(firedCount: failedFiredCount)
                    self.phraseField.isEnabled = true
                    self.startButton.isEnabled = true
                    self.restoreListening()
                    return
                }
                do {
                    try self.controller.completeEnrollment(phrase: phrase,
                                                          keywordLines: [search.calibration.keywordLine],
                                                          threshold: search.calibration.threshold)
                    self.showSuccess(phrase: phrase, candidate: search.candidate, result: search.calibration)
                } catch {
                    self.progress.textColor = .systemOrange
                    self.progress.stringValue = error.localizedDescription
                    self.phraseField.isEnabled = true
                    self.startButton.isEnabled = true
                    self.restoreListening()
                }
            }
        }
    }

    /// None of the three takes fired. Say why in a way that points at the right
    /// fix: the fitness check already told us, moments earlier, whether this
    /// phrase can be spotted at all. If it cannot, no amount of re-recording or
    /// microphone fiddling will change that. If it can, the recordings themselves
    /// are the likely problem, and mic and delivery advice are fair.
    private func failureMessage(firedCount: Int) -> String {
        guard firedCount == 0 else {
            return "Only \(firedCount) of 3 recordings triggered it.\nTry again, saying it the same way each time."
        }
        if lastFitnessVerdict == .cannotSpot {
            return "This phrase looks like the problem, not your microphone.\nTry a different phrase."
        }
        return "None of the three recordings triggered it.\nCheck your microphone, then try again."
    }

    /// Confirmation belongs in this window. An NSAlert here was the only modal in
    /// the whole app, and it read as something having gone wrong.
    ///
    /// MANDATORY HONESTY (AUDIT-2026-07-24.md): when the armed spelling is not
    /// the phrase the user typed, they are told plainly what the app is
    /// actually listening for. Never a silent substitution.
    private func showSuccess(phrase: String, candidate: WakeCandidateSearch.Candidate,
                             result: WakeCalibration.Result) {
        didSucceed = true
        titleLabel.stringValue = "“\(phrase)” is your wake phrase"
        var lines = ["Try it now: say “\(phrase)” and ChatGPT Voice should open."]
        if !candidate.isFullPhrase {
            lines.append("For reliability, Hey Codex actually listens for “\(candidate.phrase)”, not the full phrase. Say that part clearly.")
        }
        if !result.allFired {
            lines.append("Two of three takes matched. That’s enough, but re-record if it feels unreliable.")
        }
        if result.isMarginal {
            lines.append("It needed high sensitivity, so it may trigger by accident sometimes. A longer or more distinctive phrase usually works better.")
        }
        detail.stringValue = lines.joined(separator: "\n\n")
        progress.textColor = .systemGreen
        progress.stringValue = "Saved and listening."
        phraseField.isEnabled = false
        startButton.title = "Done"
        startButton.isEnabled = true
        startButton.target = self
        startButton.action = #selector(closeAfterSuccess)
        presetPicker?.isEnabled = false
        restoreListening()
    }

    @objc private func closeAfterSuccess() { complete() }

    @objc private func resetToDefault() {
        do {
            try controller.resetWakePhraseToDefault()
            phraseField.stringValue = "Hey Codex"
            titleLabel.stringValue = "Back to “Hey Codex”"
            detail.stringValue = "Your recorded phrase is gone. The built-in “Hey Codex” is listening again."
            progress.textColor = .systemGreen
            progress.stringValue = "Saved."
            didSucceed = true
            startButton.title = "Done"
            startButton.target = self
            startButton.action = #selector(closeAfterSuccess)
            startButton.isEnabled = true
        } catch {
            progress.stringValue = error.localizedDescription
        }
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
