import Foundation

/// Decides whether Voice-panel detection may be believed on this machine.
///
/// Detection is an observation of another app's window structure, so it must
/// never be a hard dependency. This type keeps the helper's behavior strictly
/// monotonic:
///
/// - **Unproven** (the state every install starts in): detection is used only
///   to *learn*. Behavior is exactly the pre-detection behavior — post the
///   shortcut and latch. A helper that has never seen a Voice panel never
///   claims one is missing.
/// - **Proven**: the panel has been observed at least once here, so this build
///   of ChatGPT does expose the signal. Only now may absence mean anything.
/// - **Trust lost**: if a proven detector then misses several launches in a row,
///   ChatGPT probably changed. Fall back to unproven behavior rather than
///   fighting it, and let the UI say so.
///
/// The consequence worth stating plainly: if OpenAI restructures the Voice panel,
/// Hey Codex degrades to the simple fire-and-latch behavior it had before. It
/// does not break.
public final class VoiceDetectionTrust: @unchecked Sendable {
    /// How many consecutive unconfirmed launches revoke a proven detector.
    /// Small enough to recover quickly, large enough to survive one slow launch
    /// or a user who dismissed the panel within the confirmation window.
    public static let failureBudget = 3

    private let lock = NSLock()
    private var proven: Bool
    private var consecutiveMisses = 0

    public init(isProven: Bool = false) {
        self.proven = isProven
    }

    /// Whether absence of a panel is currently meaningful.
    public var isProven: Bool {
        lock.lock(); defer { lock.unlock() }
        return proven
    }

    /// A panel was seen. Returns true when this is the first proof on this
    /// machine, so the caller can persist the flag.
    @discardableResult
    public func observedPanel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        consecutiveMisses = 0
        guard !proven else { return false }
        proven = true
        return true
    }

    /// A launch completed without the panel appearing. Returns true when this
    /// miss revoked trust, so the caller can persist and surface that.
    @discardableResult
    public func launchWentUnconfirmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard proven else { return false }
        consecutiveMisses += 1
        guard consecutiveMisses >= Self.failureBudget else { return false }
        proven = false
        consecutiveMisses = 0
        return true
    }
}
