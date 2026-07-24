import Foundation

/// The dedicated global shortcut posted after a wake activation. The default is
/// Control-Option-V, chosen specifically so Hey Codex never
/// commandeers normal copy/paste. Configure the same chord in ChatGPT desktop's
/// Voice shortcut setting.
public struct VoiceShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var control: Bool
    public var option: Bool
    public var command: Bool

    public init(key: String = "v", control: Bool = true, option: Bool = true, command: Bool = false) {
        self.key = Self.normalizedKey(key) ?? "v"
        self.control = control
        self.option = option
        self.command = command
    }

    public static let `default` = VoiceShortcut()

    public static func normalizedKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 1,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII })
        else { return nil }
        return trimmed
    }

    /// `CGEvent` virtual key mapping for printable US-layout shortcut keys.
    /// The menu accepts only keys in this map so injection is deterministic.
    public var virtualKeyCode: UInt16? {
        Self.keyCodes[key]
    }

    public var displayString: String {
        let prefix = (control ? "⌃" : "") + (option ? "⌥" : "") + (command ? "⌘" : "")
        return prefix + key.uppercased()
    }

    public var isUsable: Bool {
        virtualKeyCode != nil && (control || option || command)
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50
    ]
}
