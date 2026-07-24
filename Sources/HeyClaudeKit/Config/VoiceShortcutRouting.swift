import Foundation

/// Selects where the synthetic Voice shortcut is delivered. ChatGPT's global
/// hotkey path is appropriate while it is backgrounded; when it is already
/// frontmost, the same sequence must reach its local event path directly.
public enum VoiceShortcutRouting {
    public static let chatGPTBundleIdentifier = "com.openai.codex"

    public enum Destination: Equatable, Sendable {
        case systemHID
        case application(pid: Int32)
    }

    public static func destination(frontmostBundleIdentifier: String?,
                                   frontmostProcessIdentifier: Int32) -> Destination {
        guard frontmostBundleIdentifier == chatGPTBundleIdentifier,
              frontmostProcessIdentifier > 0 else { return .systemHID }
        return .application(pid: frontmostProcessIdentifier)
    }
}
