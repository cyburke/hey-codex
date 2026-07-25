import Foundation

/// Which terminal "launch CLI" targets.
public enum TerminalKind: String, Codable, CaseIterable, Sendable {
    case terminalApp    = "Terminal"
    case iterm2         = "iTerm2"
    case ghostty        = "Ghostty"
    case cursorTerminal = "Cursor Terminal"

    /// App bundle identifier - for availability checks and app-icon lookup.
    public var bundleID: String {
        switch self {
        case .terminalApp:    return "com.apple.Terminal"
        case .iterm2:         return "com.googlecode.iterm2"
        case .ghostty:        return "com.mitchellh.ghostty"
        case .cursorTerminal: return "com.todesktop.230313mzl4w4u92"
        }
    }

    /// Whether launching requires Accessibility permission (System Events keystrokes)
    /// rather than Automation permission (direct AppleEvents to the app).
    public var needsAccessibility: Bool {
        switch self {
        case .ghostty, .cursorTerminal: return true
        case .terminalApp, .iterm2:     return false
        }
    }
}

/// User-configurable settings. Persisted as JSON (SettingsStore).
public struct Settings: Codable, Equatable, Sendable {
    // Legacy compatibility fields. The Hey Codex menu-bar app never launches a
    // terminal, editor, or desktop app; it only posts the Voice shortcut.
    public var projectDirectory: String
    public var preferredTarget: LaunchTarget
    public var wakeKeywordsScore: Float
    public var wakeKeywordsThreshold: Float
    public var cooldownSeconds: Double            // ignore re-fires within this window
    public var maxUtteranceSeconds: Double        // safety cap on one utterance; the
                                                  // silence endpoint is the real
                                                  // terminator - this only bounds a clip
                                                  // when the VAD never detects silence
    public var endpointSilenceMs: Int             // trailing silence that marks end-of-
                                                  // speech (you stopped talking)
    public var claudeExecutable: String
    public var commands: [Command]
    public var defaultCommandID: String           // bare "hey codex"
    public var promptCommandID: String            // freeform prompt fallthrough
    public var onboardingCompleted: Bool          // first-run wake enrollment + setup done
    public var mascotID: String                    // selected mascot (MascotCatalog id)
    public var mascotColorHex: String              // mascot body color, e.g. "#D87757"
    public var mascotIdleAnimations: Bool          // ambient idle mascot motion (blink/breathe/gestures)
    public var pushToTalkEnabled: Bool             // hold-to-talk hotkey active
    public var pushToTalkKey: PushToTalkKey         // which key triggers it
    /// Displayed phrase that was locally enrolled into KeywordStore.
    public var wakePhrase: String
    /// Dedicated ChatGPT Voice shortcut posted by the helper after a wake.
    public var voiceShortcut: VoiceShortcut
    /// True only after the user has explicitly granted permission for Hey Codex
    /// to post the configured Voice shortcut. This drives the focused first-run
    /// setup window; it is separate from wake-phrase enrollment.
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
                preferredTarget: LaunchTarget = .terminal(.terminalApp),
                wakeKeywordsScore: Float = 2.0,
                wakeKeywordsThreshold: Float = 0.25,
                cooldownSeconds: Double = 2.0,
                maxUtteranceSeconds: Double = 30.0,
                endpointSilenceMs: Int = 800,
                claudeExecutable: String = "claude",
                commands: [Command] = Command.seededDefaults,
                defaultCommandID: String = "codex-voice",
                promptCommandID: String = "codex-voice",
                onboardingCompleted: Bool = false,
                mascotID: String = "classic",
                mascotColorHex: String = "#D87757",
                mascotIdleAnimations: Bool = true,
                pushToTalkEnabled: Bool = true,
                pushToTalkKey: PushToTalkKey = .rightOption,
                wakePhrase: String = "Hey Codex",
                voiceShortcut: VoiceShortcut = .default,
                voiceShortcutSetupCompleted: Bool = false,
                voicePanelDetectionProven: Bool = false,
                automaticUpdateChecks: Bool = true,
                inputDeviceUID: String? = nil,
                inputDeviceName: String? = nil,
                lastUpdateCheck: Date? = nil) {
        self.projectDirectory = projectDirectory
        self.preferredTarget = preferredTarget
        self.wakeKeywordsScore = wakeKeywordsScore
        self.wakeKeywordsThreshold = wakeKeywordsThreshold
        self.cooldownSeconds = cooldownSeconds
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.endpointSilenceMs = endpointSilenceMs
        self.claudeExecutable = claudeExecutable
        self.commands = commands
        self.defaultCommandID = defaultCommandID
        self.promptCommandID = promptCommandID
        self.onboardingCompleted = onboardingCompleted
        self.mascotID = mascotID
        self.mascotColorHex = mascotColorHex
        self.mascotIdleAnimations = mascotIdleAnimations
        self.pushToTalkEnabled = pushToTalkEnabled
        self.pushToTalkKey = pushToTalkKey
        self.wakePhrase = WakePhrase.normalize(wakePhrase) ?? "Hey Codex"
        self.voiceShortcut = voiceShortcut
        self.voiceShortcutSetupCompleted = voiceShortcutSetupCompleted
        self.voicePanelDetectionProven = voicePanelDetectionProven
        self.automaticUpdateChecks = automaticUpdateChecks
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.lastUpdateCheck = lastUpdateCheck
    }

    /// Pre-`LaunchTarget` settings stored the default destination as a bare
    /// `TerminalKind` under `preferredTerminal`. Migrated into `preferredTarget`.
    private enum LegacyKeys: String, CodingKey { case preferredTerminal }

    /// Custom decoding accepts old settings data, but all old routing is replaced
    /// with the one Hey Codex Voice-shortcut command.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectDirectory = try container.decode(String.self, forKey: .projectDirectory)

        if let t = try container.decodeIfPresent(LaunchTarget.self, forKey: .preferredTarget) {
            self.preferredTarget = t
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(TerminalKind.self, forKey: .preferredTerminal) {
            self.preferredTarget = .terminal(legacy)
        } else {
            self.preferredTarget = .terminal(.terminalApp)
        }

        self.wakeKeywordsScore = try container.decode(Float.self, forKey: .wakeKeywordsScore)
        self.wakeKeywordsThreshold = try container.decode(Float.self, forKey: .wakeKeywordsThreshold)
        self.cooldownSeconds = try container.decode(Double.self, forKey: .cooldownSeconds)
        self.maxUtteranceSeconds = try container.decodeIfPresent(Double.self, forKey: .maxUtteranceSeconds)
            ?? 30.0
        self.endpointSilenceMs = try container.decodeIfPresent(Int.self, forKey: .endpointSilenceMs)
            ?? 800
        self.claudeExecutable = try container.decode(String.self, forKey: .claudeExecutable)

        self.commands = Command.seededDefaults
        self.defaultCommandID = "codex-voice"
        self.promptCommandID = "codex-voice"
        self.onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
            ?? false
        self.mascotID = try container.decodeIfPresent(String.self, forKey: .mascotID)
            ?? "classic"
        self.mascotColorHex = try container.decodeIfPresent(String.self, forKey: .mascotColorHex)
            ?? "#D87757"
        self.mascotIdleAnimations = try container.decodeIfPresent(Bool.self, forKey: .mascotIdleAnimations)
            ?? true
        self.pushToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .pushToTalkEnabled)
            ?? true
        self.pushToTalkKey = try container.decodeIfPresent(PushToTalkKey.self, forKey: .pushToTalkKey)
            ?? .rightOption
        self.wakePhrase = WakePhrase.normalize(try container.decodeIfPresent(String.self, forKey: .wakePhrase)
            ?? "Hey Codex") ?? "Hey Codex"
        self.voiceShortcut = try container.decodeIfPresent(VoiceShortcut.self, forKey: .voiceShortcut) ?? .default
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
