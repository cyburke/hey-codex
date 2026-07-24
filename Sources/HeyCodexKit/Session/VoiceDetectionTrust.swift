import Foundation

/// Decides whether Voice-panel detection may be believed on this machine.
///
/// Every install starts unproven, where detection only learns and behavior
/// matches the pre-detection helper: post the shortcut and latch. Absence of a
/// panel means nothing until one has actually been seen here. After that a
/// detector that misses `failureBudget` launches in a row revokes itself.
///
/// So if OpenAI restructures the Voice panel, Hey Codex falls back to
/// fire-and-latch rather than breaking.
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
