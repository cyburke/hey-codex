import Foundation

/// A deliberately conservative, local guard around the global ChatGPT Voice
/// shortcut. ChatGPT does not expose a supported API that tells Hey Codex whether
/// a Voice session is active, so this type never claims to detect one. Instead,
/// one wake activation consumes the latch and further wake activations are ignored
/// until the user explicitly re-arms it from the menu bar.
///
/// The lock makes the latch safe to inspect from the menu-bar main thread while
/// the audio pipeline consumes it on its serial capture queue.
public final class VoiceActivationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true

    public init() {}

    /// Atomically consume one wake activation. Returns false once already latched.
    @discardableResult
    public func consumeIfArmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return false }
        armed = false
        return true
    }

    /// Whether another wake activation may be captured.
    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    /// Explicit user escape hatch after ending a ChatGPT Voice conversation.
    public func rearm() {
        lock.lock(); armed = true; lock.unlock()
    }
}
