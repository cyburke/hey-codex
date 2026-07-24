import AppKit
import AVFoundation
import Foundation
import HeyCodexKit

/// Owns the local wake-word listener. The production path is deliberately
/// small: bundled Hey Codex detects locally, then posts one configured Voice
/// shortcut. It never transcribes recordings.
///
/// It does read one fact about ChatGPT: whether ChatGPT's own process currently
/// owns a floating window that is on screen — i.e. whether the Voice panel is
/// up. That single bit is what lets the helper mirror the keyboard shortcut
/// honestly: don't toggle Voice off when the user opened it themselves, re-arm
/// when Voice ends by any means, and never show a locked icon for a Voice
/// session that never started. See `VoicePanelObserver` for what is and is not
/// read, and `VoiceDetectionTrust` for the fallback when the signal is absent.
@MainActor
final class AppController {
    enum Status: Equatable {
        case stopped, starting, listening, activating, latched, failed(String)

        var menuText: String {
            switch self {
            case .stopped: return "Listening is off"
            case .starting: return "Starting local listener…"
            case .listening: return "Listening locally"
            case .activating: return "Sending Voice shortcut…"
            case .latched: return "Voice active — close it in ChatGPT when finished"
            case .failed(let message): return message
            }
        }
    }

    private(set) var settings: Settings
    private(set) var status: Status = .stopped { didSet { onStatusChange?() } }
    var onStatusChange: (() -> Void)?

    private let activation = VoiceActivationController()
    private let panel = VoicePanelObserver()
    private let keywords = KeywordStore()
    private let trust: VoiceDetectionTrust
    private var panelWatch: Timer?
    private var audio: AudioCapture?
    private var wake: WakeWordEngineHolder?

    /// How long to wait for the Voice panel after posting the shortcut. ChatGPT
    /// shows it well inside this; the cap only bounds a launch that never lands.
    private static let panelConfirmationTimeout: TimeInterval = 2.0

    init() {
        let loaded = SettingsStore().load()
        settings = loaded
        trust = VoiceDetectionTrust(isProven: loaded.voicePanelDetectionProven)
    }

    var isListening: Bool { audio != nil }
    var isArmed: Bool { activation.isArmed }
    /// Whether Hey Codex can actually see ChatGPT's Voice panel on this Mac.
    /// The menu uses this to avoid offering a manual recovery that only makes
    /// sense when the helper is flying blind.
    var isVoiceStateVerified: Bool { trust.isProven }
    var isMicrophoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var needsMicrophoneSettings: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        case .authorized, .notDetermined: return false
        @unknown default: return true
        }
    }
    var needsFirstRunSetup: Bool { !isMicrophoneAuthorized || !settings.voiceShortcutSetupCompleted }

    func requestMicrophoneAccess(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default: completion(false)
        }
    }

    var modelsDirectory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models")
        return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
    }

    func startListening() {
        guard audio == nil else { return }
        guard let modelsDirectory else {
            status = .failed("Models are missing. Rebuild the app with the models installed.")
            return
        }
        status = .starting
        let wakeModel = modelsDirectory.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        let launchSettings = settings
        let activation = activation
        do {
            // An enrolled phrase wins over the bundled one. Enrollment derives
            // its keyword from the tokens the model actually emits for this
            // user's voice, so it is strictly better calibrated than the
            // spelling-derived default when present.
            let wake = WakeWordEngineHolder(try WakeWordEngine(
                modelDir: wakeModel,
                keywordsFile: keywords.urlIfPresent
                    ?? modelsDirectory.appendingPathComponent("keywords.txt"),
                keywordsThreshold: launchSettings.wakeKeywordsThreshold,
                keywordsScore: launchSettings.wakeKeywordsScore))
            let mic = try AudioCapture(onFrame: { [weak self] frame in
                // Only one phrase exists. Ending a Voice session is ChatGPT's
                // own job — its panel closes itself, and the panel watch re-arms
                // this helper when it does. A wake heard while Voice is already
                // up is deliberately ignored rather than toggled.
                guard activation.isArmed, wake.feed(frame), activation.beginLaunch() else { return }
                Task { @MainActor [weak self] in self?.sendLaunchShortcut() }
            })
            self.wake = wake
            self.audio = mic
            try mic.start()
            status = activation.isArmed ? .listening : .latched
        } catch {
            stopPipeline()
            status = .failed("Could not start local listening: \(error.localizedDescription)")
        }
    }

    func stopListening() { stopPipeline(); status = .stopped }

    func rearmVoice() {
        stopPanelWatch()
        activation.rearm()
        rearmWakeEngine()
        status = isListening ? .listening : .stopped
    }

    /// The wake engine is not fed while latched, so its streaming decoder holds
    /// state from just before Voice opened — often the tail of the very "Hey
    /// Codex" that opened it. Clear it on every re-arm so a stale buffer cannot
    /// fire the moment listening resumes.
    private func rearmWakeEngine() { wake?.reset() }

    @discardableResult
    func requestVoiceShortcutPermission() -> Bool {
        if refreshVoiceShortcutPermission() { return true }
        let granted = CGRequestPostEventAccess()
        if granted || refreshVoiceShortcutPermission() { return true }
        status = .failed("Allow Hey Codex to send keyboard shortcuts in Accessibility, then choose Test ChatGPT Voice Shortcut.")
        return false
    }

    @discardableResult
    func refreshVoiceShortcutPermission() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        markVoiceShortcutSetupCompleted()
        status = isListening ? (activation.isArmed ? .listening : .latched) : .stopped
        return true
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openVoiceShortcutSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func testVoiceShortcut(completion: @escaping @MainActor @Sendable (Result<Void, LaunchFailure>) -> Void = { _ in }) {
        guard activation.beginLaunch() else {
            status = .latched
            completion(.failure(.shellFailed("Voice is already active. End it first, then choose Re-arm Voice before testing again.")))
            return
        }
        // Already open: posting the toggle here would close Voice and read as a
        // failed test. Report the truth instead.
        if trust.isProven, panel.isPanelVisible() {
            activation.completeLaunch(success: true)
            status = .latched
            startPanelWatch()
            completion(.success(()))
            return
        }
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            guard result.isSuccess else {
                self.activation.completeLaunch(success: false)
                self.status = .failed(result.failureDescription)
                completion(result)
                return
            }
            // The setup test is the natural place to learn that this machine's
            // ChatGPT does expose a detectable Voice panel.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let appeared = await self.waitForPanel(visible: true,
                                                       timeout: Self.panelConfirmationTimeout)
                self.resolveLaunch(confirmed: appeared)
                completion(result)
            }
        }
    }

    /// The menu-bar escape hatch. Voice normally ends in ChatGPT's own panel,
    /// but this stays as the manual way out — it is the only recovery when panel
    /// detection is unproven and the helper is holding a latch it cannot verify.
    func endVoiceSession() {
        guard activation.beginClose() else { return }
        // The shortcut is a toggle, so closing a session that already ended
        // would *open* Voice instead. Re-arm without posting anything.
        if trust.isProven, !panel.isPanelVisible() {
            activation.completeClose(success: true)
            stopPanelWatch()
            rearmWakeEngine()
            status = isListening ? .listening : .stopped
            return
        }
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.activation.completeClose(success: result.isSuccess)
            if result.isSuccess {
                self.stopPanelWatch()
                self.rearmWakeEngine()
            }
            self.status = result.isSuccess ? (self.isListening ? .listening : .stopped)
                                           : .failed(result.failureDescription)
        }
    }

    func updateShortcut(key: String, control: Bool, option: Bool, command: Bool) throws {
        guard let normalized = VoiceShortcut.normalizedKey(key) else {
            throw ValidationError("Use one supported printable key, such as ;, /, or V.")
        }
        let shortcut = VoiceShortcut(key: normalized, control: control, option: option, command: command)
        guard shortcut.isUsable else { throw ValidationError("Choose at least one modifier and a supported key.") }
        var updated = settings
        updated.voiceShortcut = shortcut
        try SettingsStore().save(updated)
        settings = updated
        if isListening { stopPipeline(); startListening() }
    }

    /// Applies a bounded wake sensitivity immediately. Lower KWS thresholds are
    /// more eager, but are deliberately capped to avoid turning ordinary speech
    /// into a wake phrase.
    func updateWakeSensitivity(threshold: Float) throws {
        guard (0.08...0.30).contains(threshold) else {
            throw ValidationError("Wake sensitivity must stay within the supported range.")
        }
        var updated = settings
        updated.wakeKeywordsThreshold = threshold
        try SettingsStore().save(updated)
        settings = updated
        if isListening { stopPipeline(); startListening() }
    }

    /// Whether the user has enrolled their own wake phrase on this Mac.
    var hasEnrolledWakePhrase: Bool { keywords.exists }

    /// Persist a completed enrollment and restart listening on it.
    ///
    /// The keyword lines and threshold come from `WakeEnrollment`, which tuned
    /// them until every one of the user's own recordings fired. Saving the
    /// threshold alongside the lines matters: a keyword derived from one voice
    /// is not necessarily detectable at the default threshold.
    func completeEnrollment(phrase: String, keywordLines: [String], threshold: Float) throws {
        guard let normalized = WakePhrase.normalize(phrase) else {
            throw ValidationError("Enter a wake phrase of a few plain words.")
        }
        guard !keywordLines.isEmpty else {
            throw ValidationError("Enrollment produced no usable keyword.")
        }
        try keywords.save(lines: keywordLines)
        var updated = settings
        updated.wakePhrase = normalized
        updated.wakeKeywordsThreshold = threshold
        try SettingsStore().save(updated)
        settings = updated
        if isListening { stopPipeline(); startListening() }
    }

    /// Discard an enrollment and return to the bundled "Hey Codex" phrase.
    func resetWakePhraseToDefault() throws {
        try keywords.removeIfPresent()
        var updated = settings
        updated.wakePhrase = "Hey Codex"
        updated.wakeKeywordsThreshold = Settings.default.wakeKeywordsThreshold
        try SettingsStore().save(updated)
        settings = updated
        if isListening { stopPipeline(); startListening() }
    }

    private func sendLaunchShortcut() {
        // The user may have opened Voice themselves with the keyboard shortcut.
        // The shortcut is a toggle, so posting it again would close the session
        // they just started. Hold the latch and do nothing.
        if trust.isProven, panel.isPanelVisible() {
            activation.completeLaunch(success: true)
            status = .latched
            startPanelWatch()
            return
        }
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            guard result.isSuccess else {
                self.activation.completeLaunch(success: false)
                self.status = .failed(result.failureDescription)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let appeared = await self.waitForPanel(visible: true,
                                                       timeout: Self.panelConfirmationTimeout)
                self.resolveLaunch(confirmed: appeared)
            }
        }
    }

    /// Decides what a launch *meant*. Posting the shortcut only proves macOS
    /// accepted an event; it never proves Voice started. This is the one place
    /// that difference is resolved.
    private func resolveLaunch(confirmed: Bool) {
        if confirmed {
            if trust.observedPanel() { persistDetectionProven(true) }
            activation.completeLaunch(success: true)
            status = .latched
            startPanelWatch()
            return
        }
        // Never having seen a panel here means absence proves nothing — this
        // ChatGPT build may not expose the signal at all. Behave exactly as the
        // helper did before detection existed: assume the post landed.
        guard trust.isProven else {
            activation.completeLaunch(success: true)
            status = .latched
            return
        }
        // A detector that worked and now keeps missing is more likely stale than
        // right. Give up the signal rather than block the user with it.
        if trust.launchWentUnconfirmed() {
            persistDetectionProven(false)
            activation.completeLaunch(success: true)
            status = .latched
            return
        }
        activation.completeLaunch(success: false)
        rearmWakeEngine()
        status = .failed("Voice did not open. Check that \(settings.voiceShortcut.displayString) opens Voice in ChatGPT, then say Hey Codex again.")
    }

    /// Polls for the panel to reach `visible`. Returns false on timeout.
    private func waitForPanel(visible: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if panel.isPanelVisible() == visible { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return panel.isPanelVisible() == visible
    }

    /// Watches for Voice ending by any means — the keyboard shortcut, clicking
    /// away, or ChatGPT closing it — and re-arms the wake phrase. Without this
    /// the helper stays latched with no spoken way out, which is exactly the
    /// state where "Hey Codex" appears to do nothing.
    private func startPanelWatch() {
        guard trust.isProven else { return }
        panelWatch?.invalidate()
        panelWatch = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.panelWatchTick() }
        }
    }

    private func panelWatchTick() {
        guard isListening, !activation.isArmed, trust.isProven else {
            stopPanelWatch()
            return
        }
        guard !panel.isPanelVisible() else { return }
        stopPanelWatch()
        activation.rearm()
        rearmWakeEngine()
        status = .listening
    }

    private func stopPanelWatch() {
        panelWatch?.invalidate()
        panelWatch = nil
    }

    private func persistDetectionProven(_ proven: Bool) {
        guard settings.voicePanelDetectionProven != proven else { return }
        var updated = settings
        updated.voicePanelDetectionProven = proven
        try? SettingsStore().save(updated)
        settings = updated
    }

    private func postVoiceShortcut(completion: @escaping @MainActor (Result<Void, LaunchFailure>) -> Void) {
        status = .activating
        let executor = CommandExecutor(settings: settings, launcherFor: { _ in TerminalAppLauncher() })
        executor.execute(Command.seededDefaults[0], prompt: nil) { result in
            Task { @MainActor in completion(result) }
        }
    }

    private func stopPipeline() {
        stopPanelWatch()
        audio?.stop()
        audio = nil
        wake = nil
    }

    private func markVoiceShortcutSetupCompleted() {
        guard !settings.voiceShortcutSetupCompleted else { return }
        var updated = settings
        updated.voiceShortcutSetupCompleted = true
        try? SettingsStore().save(updated)
        settings = updated
    }

    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private extension Result where Success == Void, Failure == LaunchFailure {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var failureDescription: String {
        if case .failure(let error) = self { return error.localizedDescription }
        return ""
    }
}
