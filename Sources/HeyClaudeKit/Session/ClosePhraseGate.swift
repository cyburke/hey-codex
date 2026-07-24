import Foundation

/// Arbitrates the two KWS detectors while Voice is latched. A Close Codex hit
/// is only a *candidate*: it must survive a short grace window during which a
/// delayed Hey Codex result from the same utterance can cancel it.
public struct ClosePhraseTicket: Equatable, Sendable {
    fileprivate let generation: UInt64
}

public final class ClosePhraseArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var pendingGeneration: UInt64?

    public init() {}

    /// Starts one pending close candidate. Duplicate detector results cannot
    /// schedule a second shortcut while a candidate is awaiting arbitration.
    public func beginCloseCandidate() -> ClosePhraseTicket? {
        lock.lock(); defer { lock.unlock() }
        guard pendingGeneration == nil else { return nil }
        nextGeneration &+= 1
        pendingGeneration = nextGeneration
        return ClosePhraseTicket(generation: nextGeneration)
    }

    /// Hey Codex wins over Close Codex. This invalidates even a close task that
    /// is already waiting on another executor.
    public func cancelPendingCloseForRepeatedLaunch() {
        lock.lock(); defer { lock.unlock() }
        pendingGeneration = nil
    }

    /// Atomically claims a still-valid close after the grace window. A stale or
    /// cancelled ticket cannot post the toggle shortcut.
    public func claimClose(_ ticket: ClosePhraseTicket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingGeneration == ticket.generation else { return false }
        pendingGeneration = nil
        return true
    }
}
