import Foundation

/// The separate, local-only phrase accepted while ChatGPT Voice is active.
/// It is intentionally distinct from the launch phrase, so a repeated
/// “Hey Codex” can never be mistaken for a request to end a conversation.
public enum VoiceClosePhrase {
    public static let displayName = "Close Codex"
    public static let keywordLine = "▁C LO SE ▁CO DE X"
    /// A deliberately conservative threshold, independent of the user-tunable
    /// launch threshold. Ending Voice toggles the ChatGPT shortcut, so it must
    /// not inherit a more sensitive launch setting.
    public static let keywordsThreshold: Float = 0.25
}
