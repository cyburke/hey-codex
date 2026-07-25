import AppKit
import AVFoundation
import Foundation
import HeyCodexKit

/// Owns the local wake-word listener. The production path is deliberately
/// small: bundled Hey Codex detects locally, then posts one configured Voice
/// shortcut. It never transcribes recordings.
///
/// It does read one fact about ChatGPT: whether ChatGPT's own process currently
/// owns a floating window that is on screen - i.e. whether the Voice panel is
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
            case .stopped: return "Not listening right now"
            case .starting: return "Warming up…"
            case .listening: return "Listening"
            case .activating: return "Opening ChatGPT Voice…"
            case .latched: return "Voice is open. Close it in ChatGPT when you are done"
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
    private(set) var availableUpdate: (version: String, url: URL)?
    var onUpdateStatus: ((UpdateStatus) -> Void)?
    private var audio: AudioCapture?
    private var wake: WakeWordEngineHolder?

    /// How long to wait for the Voice panel after posting the shortcut. ChatGPT
    /// shows it well inside this; the cap only bounds a launch that never lands.
    private static let panelConfirmationTimeout: TimeInterval = 2.0

    init() {
        let loaded = SettingsStore().load()
        settings = loaded
        trust = VoiceDetectionTrust(isProven: loaded.voicePanelDetectionProven)
        observeDeviceChanges()
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
    /// Where the user is in setup, as one value the menu renders directly.
    var setupState: SetupState {
        SetupStateResolver.state(microphone: microphoneAuthorization,
                                 accessibilityTrusted: AXIsProcessTrusted(),
                                 canPostEvents: CGPreflightPostEventAccess())
    }

    /// Setup is finished when both permissions exist AND a launch has actually
    /// been seen to work. Permissions alone is not enough: they survive a
    /// reinstall, so an upgrade would look configured while never having proved
    /// the hotkey matches.
    var needsFirstRunSetup: Bool { !setupState.isComplete || !isVoiceStateVerified }

    private var microphoneAuthorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// ChatGPT registers its Voice hotkey with Carbon when it launches, so a
    /// hotkey press does nothing at all while the app is not running. Nothing to
    /// post to, no error, no clue.
    var availableInputDevices: [AudioInputDevice] { AudioCapture.availableInputDevices() }

    /// The microphone actually in use, which is not always the one chosen: a
    /// headset that has been unplugged falls back to another device.
    private(set) var activeInputName: String?

    var chosenInputUnavailable: Bool {
        AudioInputSelection.isPreferenceUnavailable(preferredUID: settings.inputDeviceUID,
                                                    available: availableInputDevices)
    }

    func selectInputDevice(uid: String?) throws {
        var updated = settings
        updated.inputDeviceUID = uid
        updated.inputDeviceName = uid.flatMap { chosen in
            availableInputDevices.first(where: { $0.uid == chosen })?.name
        }
        try SettingsStore().save(updated)
        settings = updated
        if isListening { stopPipeline(); startListening() }
    }

    /// Microphones appear and disappear while the app runs. Without this a
    /// headset plugged in later is ignored, and a headset unplugged leaves the
    /// app silently deaf while still reporting that it is listening.
    private func observeDeviceChanges() {
        let names: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.stopPipeline()
                    self.startListening()
                }
            }
        }
    }

    var isChatGPTRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: VoicePanelObserver.chatGPTBundleIdentifier).isEmpty
    }

    /// Launch ChatGPT if needed and wait until it can actually receive a hotkey.
    /// Completion carries false when it could not be started at all.
    func ensureChatGPTRunning(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if isChatGPTRunning { completion(true); return }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: VoicePanelObserver.chatGPTBundleIdentifier) else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Bring it up quietly. The user asked for Voice, not for a window.
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Registering the Carbon hot key happens during startup, so a
                // press sent too early lands nowhere. Wait for the app to say it
                // finished launching, then give it a beat.
                for _ in 0..<40 {
                    if NSRunningApplication.runningApplications(
                        withBundleIdentifier: VoicePanelObserver.chatGPTBundleIdentifier)
                        .contains(where: { $0.isFinishedLaunching }) { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .milliseconds(1200))
                completion(self.isChatGPTRunning)
            }
        }
    }

    /// Hey Codex presses a hotkey in another app, so that app has to exist.
    /// Without this check a user finishes setup, says the phrase, and nothing
    /// happens forever with nothing to explain why.
    var isChatGPTInstalled: Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: VoicePanelObserver.chatGPTBundleIdentifier) != nil
    }

    /// Relaunch so a freshly granted Accessibility permission takes effect. The
    /// replacement is started before this instance exits so the menu bar icon
    /// does not disappear on the user mid-setup.
    func relaunch(reason: String? = nil) {
        // Release the microphone BEFORE the replacement launches. Starting the
        // new instance first left two processes holding the same input device at
        // once, and on hardware that does input and output through one device
        // (USB monitors, docks, interfaces) that contention can wedge CoreAudio
        // and take the machine's sound out with it.
        stopPipeline()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        if let reason { configuration.arguments = [reason] }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Ask macOS for permission to post the shortcut. Returns false when the
    /// user has to finish the job in System Settings.
    @discardableResult
    func requestAccessibility() -> Bool {
        if CGPreflightPostEventAccess() {
            markVoiceShortcutSetupCompleted()
            return true
        }
        CGRequestPostEventAccess()
        return CGPreflightPostEventAccess()
    }

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
            status = .failed("The speech model is missing from this build. Reinstalling Hey Codex should fix it.")
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
            let mic = try AudioCapture(preferredUID: launchSettings.inputDeviceUID,
                                       onFrame: { [weak self] frame in
                // Only one phrase exists. Ending a Voice session is ChatGPT's
                // own job - its panel closes itself, and the panel watch re-arms
                // this helper when it does. A wake heard while Voice is already
                // up is deliberately ignored rather than toggled.
                guard activation.isArmed, wake.feed(frame), activation.beginLaunch() else { return }
                Task { @MainActor [weak self] in self?.sendLaunchShortcut() }
            })
            self.wake = wake
            self.audio = mic
            self.activeInputName = mic.deviceName
            try mic.start()
            status = activation.isArmed ? .listening : .latched
        } catch {
            stopPipeline()
            status = .failed("Could not start listening: \(error.localizedDescription)")
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
    /// state from just before Voice opened - often the tail of the very "Hey
    /// Codex" that opened it. Clear it on every re-arm so a stale buffer cannot
    /// fire the moment listening resumes.
    private func rearmWakeEngine() { wake?.reset() }

    @discardableResult
    func requestVoiceShortcutPermission() -> Bool {
        if refreshVoiceShortcutPermission() { return true }
        let granted = CGRequestPostEventAccess()
        if granted || refreshVoiceShortcutPermission() { return true }
        status = .failed("Allow Hey Codex under Accessibility, then run the test again.")
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
        // A test is an explicit user action, so it starts from a clean slate. It
        // used to refuse with "Voice is already active" whenever an earlier failed
        // attempt had left the latch consumed, which is precisely when someone
        // needs to run a test.
        activation.rearm()
        rearmWakeEngine()
        guard activation.beginLaunch() else {
            completion(.failure(.shellFailed("Could not start a test just now. Give it a second and try again.")))
            return
        }
        guard isChatGPTRunning else {
            activation.completeLaunch(success: false)
            rearmWakeEngine()
            ensureChatGPTRunning { [weak self] started in
                guard let self else { return }
                guard started else {
                    self.status = .failed("ChatGPT would not start. Try opening it yourself, then test again.")
                    completion(.failure(.shellFailed("ChatGPT is not running, and Hey Codex could not start it. Open it yourself and try again.")))
                    return
                }
                self.testVoiceShortcut(completion: completion)
            }
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
    /// but this stays as the manual way out - it is the only recovery when panel
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
            throw ValidationError("Pick one printable key, like V, ; or /.")
        }
        let shortcut = VoiceShortcut(key: normalized, control: control, option: option, command: command)
        guard shortcut.isUsable else { throw ValidationError("A hotkey needs at least one modifier plus a key.") }
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
            throw ValidationError("That sensitivity is outside the supported range.")
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
            throw ValidationError("Type a wake phrase of a few plain words.")
        }
        guard !keywordLines.isEmpty else {
            throw ValidationError("Those recordings did not produce anything usable. Try recording again.")
        }
        try keywords.save(lines: keywordLines)
        var updated = settings
        updated.wakePhrase = normalized
        updated.wakeKeywordsThreshold = threshold
        try SettingsStore().save(updated)
        settings = updated
        restartListeningAfterPhraseChange()
    }

    /// Discard an enrollment and return to the bundled "Hey Codex" phrase.
    func resetWakePhraseToDefault() throws {
        try keywords.removeIfPresent()
        var updated = settings
        updated.wakePhrase = "Hey Codex"
        updated.wakeKeywordsThreshold = Settings.default.wakeKeywordsThreshold
        try SettingsStore().save(updated)
        settings = updated
        restartListeningAfterPhraseChange()
    }

    /// Bring the listener up on the new phrase, whether or not it was running.
    ///
    /// Unlike the other settings paths, this one is reached *from enrollment*,
    /// which deliberately stopped the listener to take the microphone. A plain
    /// `if isListening` check is therefore always false here, so the listener
    /// would stay down until the enrollment window finished closing - leaving
    /// the app deaf across the confirmation dialog and for the engine's warmup
    /// after it. Starting here instead means the new engine builds while the
    /// user is still reading the confirmation.
    private func restartListeningAfterPhraseChange() {
        stopPipeline()
        guard isMicrophoneAuthorized else { return }
        startListening()
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development build"
    }

    /// Ask GitHub for the latest release tag. This is the only network request
    /// the app makes. An automatic check is skipped entirely when the user has
    /// turned it off, so "off" means no request rather than a silent one.
    func checkForUpdates(userInitiated: Bool) {
        if !userInitiated {
            guard settings.automaticUpdateChecks,
                  UpdateCheck.isDue(lastCheck: settings.lastUpdateCheck, now: Date())
            else { return }
        }
        var stamped = settings
        stamped.lastUpdateCheck = Date()
        try? SettingsStore().save(stamped)
        settings = stamped

        let current = appVersion
        var request = URLRequest(url: UpdateCheck.releasesAPI)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let status: UpdateStatus
            if let error {
                status = .failed(error.localizedDescription)
            } else if let data {
                let parsed = UpdateCheck.parse(data)
                status = UpdateCheck.status(currentVersion: current,
                                            latestTag: parsed.tag,
                                            releaseURL: parsed.url)
            } else {
                status = .failed("No response from GitHub.")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .available(let version, let url) = status {
                    self.availableUpdate = (version, url)
                } else {
                    self.availableUpdate = nil
                }
                self.onStatusChange?()
                self.onUpdateStatus?(status)
            }
        }.resume()
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) throws {
        var updated = settings
        updated.automaticUpdateChecks = enabled
        try SettingsStore().save(updated)
        settings = updated
    }

    private func sendLaunchShortcut() {
        // No running ChatGPT means no registered hot key, so the press would go
        // nowhere. Start it, then send.
        guard isChatGPTRunning else {
            status = .activating
            ensureChatGPTRunning { [weak self] started in
                guard let self else { return }
                guard started else {
                    self.activation.completeLaunch(success: false)
                    self.rearmWakeEngine()
                    self.status = .failed("ChatGPT would not start. Try opening it yourself, then test again.")
                    return
                }
                self.postAndConfirmLaunch()
            }
            return
        }
        // The user may have opened Voice themselves with the keyboard shortcut.
        // The shortcut is a toggle, so posting it again would close the session
        // they just started. Hold the latch and do nothing.
        if trust.isProven, panel.isPanelVisible() {
            activation.completeLaunch(success: true)
            status = .latched
            startPanelWatch()
            return
        }
        postAndConfirmLaunch()
    }

    private func postAndConfirmLaunch() {
        postVoiceShortcut { [weak self] result in
            guard let self else { return }
            guard result.isSuccess else {
                self.activation.completeLaunch(success: false)
                self.rearmWakeEngine()
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
        // If ChatGPT is running and its windows are enumerable, a missing panel is
        // real evidence even on a first attempt, and latching would strand the
        // user believing a session is open. Only an unproven detector with no
        // running ChatGPT justifies assuming the post landed.
        if isChatGPTRunning {
            activation.completeLaunch(success: false)
            rearmWakeEngine()
            status = .failed("Voice did not open. Check that \(settings.voiceShortcut.displayString) is set as the Voice chat hotkey in ChatGPT.")
            return
        }
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
        status = .failed("Voice did not open. Make sure \(settings.voiceShortcut.displayString) is the Voice chat hotkey in ChatGPT, then try again.")
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

    /// Watches for Voice ending by any means - the keyboard shortcut, clicking
    /// away, or ChatGPT closing it - and re-arms the wake phrase. Without this
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
