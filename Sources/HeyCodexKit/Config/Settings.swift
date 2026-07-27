import Foundation

/// User-configurable settings. Persisted as JSON (SettingsStore).
public struct Settings: Codable, Equatable, Sendable {
    public var projectDirectory: String
    public var wakeKeywordsScore: Float
    public var wakeKeywordsThreshold: Float
    public var cooldownSeconds: Double            // ignore re-fires within this window
    public var maxUtteranceSeconds: Double        // safety cap on one utterance; the
                                                  // silence endpoint is the real
                                                  // terminator - this only bounds a clip
                                                  // when the VAD never detects silence
    public var endpointSilenceMs: Int             // trailing silence that marks end-of-
                                                  // speech (you stopped talking)
    public var commands: [Command]
    public var defaultCommandID: String           // bare "hey codex"
    public var promptCommandID: String            // freeform prompt fallthrough
    /// Displayed phrase that was locally enrolled into KeywordStore.
    public var wakePhrase: String
    /// Dedicated ChatGPT Voice shortcut posted by the helper after a wake.
    public var voiceShortcut: VoiceShortcut
    /// True only after the user has explicitly granted permission for Hey Codex
    /// to post the configured Voice shortcut. This drives the focused first-run
    /// setup window; it is separate from wake-phrase enrollment.
    /// Whether the app has already made its one-time attempt to start at login.
    /// Without this it would either miss everyone who finished setup before the
    /// feature existed, or re-enable itself every launch against the user's wish.
    public var loginItemConfigured: Bool
    public var voiceShortcutSetupCompleted: Bool
    /// True once a ChatGPT Voice panel has actually been observed on this
    /// machine. Until then the helper cannot tell "Voice is closed" from
    /// "this ChatGPT build does not expose the signal", so it does not try.
    public var voicePanelDetectionProven: Bool
    /// Whether Hey Codex may ask GitHub for the latest release version. This is
    /// the only network request the app ever makes, and it is the only setting
    /// that turns any network access on or off.
    public var automaticUpdateChecks: Bool
    /// Chosen microphone, by AVFoundation unique ID. Nil follows the system
    /// default, which is what most people want.
    public var inputDeviceUID: String?
    /// Its name when it was chosen. Persisted so a disconnected device can be
    /// named in the UI; an ID alone leaves the user staring at "Not connected"
    /// with no idea what is missing.
    public var inputDeviceName: String?
    public var lastUpdateCheck: Date?

    public init(projectDirectory: String = NSHomeDirectory(),
                wakeKeywordsScore: Float = KeywordTuning.score,
                wakeKeywordsThreshold: Float = 0.25,
                cooldownSeconds: Double = 2.0,
                maxUtteranceSeconds: Double = 30.0,
                endpointSilenceMs: Int = 800,
                commands: [Command] = Command.seededDefaults,
                defaultCommandID: String = "codex-voice",
                promptCommandID: String = "codex-voice",
                wakePhrase: String = "Hey Codex",
                voiceShortcut: VoiceShortcut = .default,
                loginItemConfigured: Bool = false,
                voiceShortcutSetupCompleted: Bool = false,
                voicePanelDetectionProven: Bool = false,
                automaticUpdateChecks: Bool = true,
                inputDeviceUID: String? = nil,
                inputDeviceName: String? = nil,
                lastUpdateCheck: Date? = nil) {
        self.projectDirectory = projectDirectory
        self.wakeKeywordsScore = wakeKeywordsScore
        self.wakeKeywordsThreshold = wakeKeywordsThreshold
        self.cooldownSeconds = cooldownSeconds
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.endpointSilenceMs = endpointSilenceMs
        self.commands = commands
        self.defaultCommandID = defaultCommandID
        self.promptCommandID = promptCommandID
        self.wakePhrase = WakePhrase.normalize(wakePhrase) ?? "Hey Codex"
        self.voiceShortcut = voiceShortcut
        self.loginItemConfigured = loginItemConfigured
        self.voiceShortcutSetupCompleted = voiceShortcutSetupCompleted
        self.voicePanelDetectionProven = voicePanelDetectionProven
        self.automaticUpdateChecks = automaticUpdateChecks
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.lastUpdateCheck = lastUpdateCheck
    }

    /// Custom decoding accepts old settings data, but all old routing is replaced
    /// with the one Hey Codex Voice-shortcut command. Fields that no longer exist
    /// (`preferredTarget`, `claudeExecutable`, `pushToTalkEnabled`, `pushToTalkKey`,
    /// `mascotID`, `mascotColorHex`, `mascotIdleAnimations`, `onboardingCompleted`)
    /// have no case in `CodingKeys` below, so a stray key for one of them in an
    /// existing settings.json is simply ignored, not an error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectDirectory = try container.decode(String.self, forKey: .projectDirectory)
        self.wakeKeywordsScore = try container.decode(Float.self, forKey: .wakeKeywordsScore)
        self.wakeKeywordsThreshold = try container.decode(Float.self, forKey: .wakeKeywordsThreshold)
        self.cooldownSeconds = try container.decode(Double.self, forKey: .cooldownSeconds)
        self.maxUtteranceSeconds = try container.decodeIfPresent(Double.self, forKey: .maxUtteranceSeconds)
            ?? 30.0
        self.endpointSilenceMs = try container.decodeIfPresent(Int.self, forKey: .endpointSilenceMs)
            ?? 800

        self.commands = Command.seededDefaults
        self.defaultCommandID = "codex-voice"
        self.promptCommandID = "codex-voice"
        self.wakePhrase = WakePhrase.normalize(try container.decodeIfPresent(String.self, forKey: .wakePhrase)
            ?? "Hey Codex") ?? "Hey Codex"
        self.voiceShortcut = try container.decodeIfPresent(VoiceShortcut.self, forKey: .voiceShortcut) ?? .default
        self.loginItemConfigured = try container.decodeIfPresent(Bool.self, forKey: .loginItemConfigured)
            ?? false
        self.voiceShortcutSetupCompleted = try container.decodeIfPresent(Bool.self, forKey: .voiceShortcutSetupCompleted)
            ?? false
        self.voicePanelDetectionProven = try container.decodeIfPresent(Bool.self, forKey: .voicePanelDetectionProven)
            ?? false
        self.automaticUpdateChecks = try container.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks)
            ?? true
        self.inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        self.inputDeviceName = try container.decodeIfPresent(String.self, forKey: .inputDeviceName)
        self.lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }

    public static let `default` = Settings()
}
