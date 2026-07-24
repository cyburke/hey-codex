import AppKit
import AVFoundation
import Foundation
import HeyClaudeKit

/// Owns the local wake-word listener. The production path is deliberately
/// small: bundled Hey Codex detects locally, then posts one configured Voice
/// shortcut. It never transcribes recordings or infers ChatGPT's window state.
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
            case .latched: return "Voice active — say Close Codex when finished"
            case .failed(let message): return message
            }
        }
    }

    private(set) var settings: Settings
    private(set) var status: Status = .stopped { didSet { onStatusChange?() } }
    var onStatusChange: (() -> Void)?

    private let activation = VoiceActivationController()
    private let closeArbiter = ClosePhraseArbiter()
    private var audio: AudioCapture?
    private var wake: WakeWordEngineHolder?
    private var closeWake: WakeWordEngineHolder?

    init() { settings = SettingsStore().load() }

    var isListening: Bool { audio != nil }
    var isArmed: Bool { activation.isArmed }
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
        let closeArbiter = closeArbiter
        do {
            // Personal calibration is quarantined from the production listener
            // until it has its own qualified release path.
            let wake = WakeWordEngineHolder(try WakeWordEngine(
                modelDir: wakeModel,
                keywordsFile: modelsDirectory.appendingPathComponent("keywords.txt"),
                keywordsThreshold: launchSettings.wakeKeywordsThreshold,
                keywordsScore: launchSettings.wakeKeywordsScore))
            let closeWake = WakeWordEngineHolder(try WakeWordEngine(
                modelDir: wakeModel,
                keywordsFile: modelsDirectory.appendingPathComponent("close-keywords.txt"),
                keywordsThreshold: VoiceClosePhrase.keywordsThreshold,
                keywordsScore: launchSettings.wakeKeywordsScore))
            let mic = try AudioCapture(onFrame: { [weak self] frame in
                if activation.isArmed {
                    guard wake.feed(frame), activation.beginLaunch() else { return }
                    Task { @MainActor [weak self] in self?.sendLaunchShortcut() }
                } else {
                    // Keep watching for Hey Codex after Voice starts. A repeated
                    // launch phrase is explicitly harmless and takes priority
                    // over Close Codex, including any delayed KWS result from
                    // the same utterance.
                    if wake.feed(frame) {
                        closeWake.reset()
                        closeArbiter.cancelPendingCloseForRepeatedLaunch()
                        return
                    }
                    guard closeWake.feed(frame),
                          let ticket = closeArbiter.beginCloseCandidate() else { return }
                    // Do not toggle immediately. The launch and close KWS
                    // decoders can finish on adjacent frames for one spoken
                    // phrase; a delayed Hey Codex result cancels this ticket.
                    Task { @MainActor [weak self, closeArbiter] in
                        do { try await Task.sleep(for: .milliseconds(1500)) }
                        catch { return }
                        guard closeArbiter.claimClose(ticket) else { return }
                        self?.endVoiceSession()
                    }
                }
            })
            self.wake = wake
            self.closeWake = closeWake
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
        activation.rearm()
        status = isListening ? .listening : .stopped
    }

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
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.activation.completeLaunch(success: result.isSuccess)
            self.status = result.isSuccess ? .latched : .failed(result.failureDescription)
            completion(result)
        }
    }

    /// Explicit menu or spoken Close Codex. The activation controller provides
    /// the exactly-once guard around this toggle shortcut.
    func endVoiceSession() {
        guard activation.beginClose() else { return }
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.activation.completeClose(success: result.isSuccess)
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

    private func sendLaunchShortcut() {
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.activation.completeLaunch(success: result.isSuccess)
            self.status = result.isSuccess ? .latched : .failed(result.failureDescription)
        }
    }

    private func postVoiceShortcut(completion: @escaping @MainActor (Result<Void, LaunchFailure>) -> Void) {
        status = .activating
        let executor = CommandExecutor(settings: settings, launcherFor: { _ in TerminalAppLauncher() })
        executor.execute(Command.seededDefaults[0], prompt: nil) { result in
            Task { @MainActor in completion(result) }
        }
    }

    private func stopPipeline() {
        audio?.stop()
        audio = nil
        wake = nil
        closeWake = nil
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
