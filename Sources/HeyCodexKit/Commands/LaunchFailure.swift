import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A typed, user-actionable launch failure. Every failure mode a
/// `CommandExecutor` can hit maps to one case carrying enough context to tell
/// the user *what* broke and *how to fix it*.
///
/// `LocalizedError` gives the menu its two lines (`errorDescription` +
/// `recoverySuggestion`); `islandMessage` is the short form the notch shows during
/// the failure beat. `Sendable` so it can cross from the audio queue (where the
/// launch runs) to the main actor intact, never collapsed to a `Bool`.
public enum LaunchFailure: Error, Equatable, Sendable, LocalizedError {
    /// A `runShell` command failed to spawn.
    case shellFailed(String)

    /// One-line headline (menu primary line + log).
    public var errorDescription: String? {
        switch self {
        case .shellFailed(let msg):
            return "The command failed to run - \(msg)"
        }
    }

    /// What the user can do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .shellFailed:
            return nil
        }
    }

    /// A System Settings pane that fixes this failure, surfaced as an actionable
    /// menu button. nil when there's no one-click pane.
    public var settingsURL: URL? {
        switch self {
        case .shellFailed:
            return nil
        }
    }

    /// The compact line the notch island shows during the failure beat.
    public var islandMessage: String {
        switch self {
        case .shellFailed:
            return "Command failed"
        }
    }
}
