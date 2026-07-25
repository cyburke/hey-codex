import Foundation

public enum MicrophoneAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied
}

/// Where the user is in first-run setup, as one value the menu can render.
public enum SetupState: Equatable, Sendable {
    case needsMicrophone
    /// Asked and refused, or switched off later. Only System Settings fixes it.
    case microphoneBlocked
    case needsAccessibility
    /// macOS has recorded the grant, but this process was told "denied" and
    /// will never be told otherwise. Only a relaunch clears it.
    case accessibilityPendingRelaunch
    case ready

    public var isComplete: Bool { self == .ready }
}

public enum AccessibilityGrant {
    /// Whether the Accessibility grant on this Mac is recorded but does not apply
    /// to the running binary.
    ///
    /// `AXIsProcessTrusted` sees the row in System Settings and says yes, while
    /// the post-event gate says no, and a relaunch has already been tried without
    /// changing that. macOS binds an Accessibility authorization to a specific
    /// build, so replacing the app (any upgrade does) can leave a row that is
    /// visibly switched on and no longer valid. Removing the row and granting it
    /// again is the only fix, and nothing in the UI can infer it for the user.
    public static func isStale(state: SetupState, alreadyRelaunched: Bool) -> Bool {
        state == .accessibilityPendingRelaunch && alreadyRelaunched
    }
}

public enum SetupStateResolver {
    /// Resolve the two permissions into a single step.
    ///
    /// `accessibilityTrusted` and `canPostEvents` come from two different macOS
    /// APIs that disagree in a specific, useful way. `AXIsProcessTrusted` re-reads
    /// the current grant, while `CGPreflightPostEventAccess` answers a process
    /// once and never revises it. So trusted-but-cannot-post is not a
    /// contradiction: it is exactly the state of "the user granted it a moment
    /// ago and this process has not restarted yet", which is the single most
    /// confusing moment in setup and the one worth naming.
    public static func state(microphone: MicrophoneAuthorization,
                             accessibilityTrusted: Bool,
                             canPostEvents: Bool) -> SetupState {
        switch microphone {
        case .denied: return .microphoneBlocked
        case .notDetermined: return .needsMicrophone
        case .authorized: break
        }
        if canPostEvents { return .ready }
        return accessibilityTrusted ? .accessibilityPendingRelaunch : .needsAccessibility
    }
}
