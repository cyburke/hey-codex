import Foundation

/// How a command performs its action.
public enum CommandKind: Codable, Equatable, Sendable {
    /// Run an arbitrary shell command (no terminal window).
    case runShell(script: String)
    /// Send the configured ChatGPT Voice shortcut through the HID event stream.
    /// This deliberately leaves the frontmost application alone.
    case sendCodexVoiceShortcut
}

/// A voice-triggerable command. Stored as data in Settings - adding a tool
/// is a new Command, not new code.
public struct Command: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String              // human-facing command label
    public var triggers: [String]         // spoken phrases that select it (lowercased). [] = eligible only as a default.
    public var kind: CommandKind
    public var acceptsPrompt: Bool        // whether trailing speech is passed as {prompt}

    public init(id: String, label: String, triggers: [String], kind: CommandKind,
                acceptsPrompt: Bool = false) {
        self.id = id; self.label = label
        self.triggers = triggers.map { $0.lowercased() }
        self.kind = kind; self.acceptsPrompt = acceptsPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, triggers, kind, acceptsPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.triggers = (try c.decodeIfPresent([String].self, forKey: .triggers) ?? [])
            .map { $0.lowercased() }
        self.kind = try c.decode(CommandKind.self, forKey: .kind)
        self.acceptsPrompt = try c.decodeIfPresent(Bool.self, forKey: .acceptsPrompt) ?? false
    }

    /// The seeded out-of-box command: a bare "Hey Codex" sends the user's
    /// configured global ChatGPT Voice shortcut without changing focus.
    public static let seededDefaults: [Command] = [
        Command(id: "codex-voice", label: "Codex Voice", triggers: [],
                kind: .sendCodexVoiceShortcut,
                acceptsPrompt: false),
    ]
}
