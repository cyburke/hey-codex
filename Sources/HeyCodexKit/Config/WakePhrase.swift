import Foundation

/// The spoken phrase enrolled into the local keyword spotter.
public enum WakePhrase: Equatable, Sendable {
    public static let presets = ["Hey Codex", "Hey ChatGPT", "Hey Jarvis"]

    /// Normalizes the phrase accepted by the settings UI. A short, multiword
    /// phrase has substantially lower accidental-trigger risk than a single word.
    public static func normalize(_ phrase: String) -> String? {
        let words = phrase
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        let normalized = words.joined(separator: " ")
        guard normalized.count <= 48,
              normalized.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" || $0 == "-" })
        else { return nil }
        return normalized
    }

    public static func isRecommended(_ phrase: String) -> Bool {
        phrase.split(whereSeparator: { $0.isWhitespace }).count >= 2
    }
}
