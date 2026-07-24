import Foundation

/// Owns the minimal state around ChatGPT Voice's toggle shortcut. It does not
/// infer ChatGPT's UI state: it only ensures the helper never posts a duplicate
/// launch or close shortcut from repeated detector frames.
public final class VoiceActivationController: @unchecked Sendable {
    private let lock = NSLock()
    private var ending = false
    public let latch = VoiceActivationLatch()

    public init() {}

    public var isArmed: Bool { latch.isArmed }

    /// One detected wake can begin exactly one launch shortcut.
    public func beginLaunch() -> Bool { latch.consumeIfArmed() }

    /// A failed launch did not start Voice, so permit a retry.
    public func completeLaunch(success: Bool) {
        guard !success else { return }
        latch.rearm()
    }

    /// A close request is valid only after a helper-initiated launch and only
    /// once until the toggle shortcut completes.
    public func beginClose() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !latch.isArmed, !ending else { return false }
        ending = true
        return true
    }

    /// A successful close returns to the armed state. A failed close remains
    /// latched but permits another explicit close attempt.
    public func completeClose(success: Bool) {
        lock.lock(); ending = false; lock.unlock()
        if success { latch.rearm() }
    }

    public func rearm() {
        lock.lock(); ending = false; lock.unlock()
        latch.rearm()
    }
}
