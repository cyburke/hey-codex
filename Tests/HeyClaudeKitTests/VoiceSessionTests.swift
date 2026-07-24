import XCTest
@testable import HeyClaudeKit

final class VoiceSessionTests: XCTestCase {
    private func registry() -> CommandRegistry {
        CommandRegistry(commands: Command.seededDefaults,
                        defaultCommandID: "codex-voice",
                        promptCommandID: "codex-voice")
    }

    func test_bareWakeResolvesVoiceShortcut() {
        let executed = Box<[(Command, String?)]>([])
        let session = VoiceSession(
            transcribe: { _ in "hey codex" }, now: { 100 }, cooldownSeconds: 0,
            registry: registry(), execute: { executed.value.append(($0, $1)) })
        session.handle(utterance: [0.1])
        XCTAssertEqual(executed.value.first?.0.id, "codex-voice")
        XCTAssertNil(executed.value.first?.1)
    }

    func test_cooldownSuppressesRapidRefires() {
        let count = Box(0)
        let session = VoiceSession(
            transcribe: { _ in "hey codex" }, now: { 100 }, cooldownSeconds: 2,
            registry: registry(), execute: { _, _ in count.value += 1 })
        session.handle(utterance: [0.1])
        session.handle(utterance: [0.1])
        XCTAssertEqual(count.value, 1)
    }

    func test_latchMakesRepeatedWakeHarmlessUntilRearmed() {
        let latch = VoiceActivationLatch()
        let count = Box(0)
        let session = VoiceSession(
            transcribe: { _ in "hey codex" }, now: { 100 }, cooldownSeconds: 0,
            registry: registry(), execute: { _, _ in count.value += 1 }, activationLatch: latch)
        session.handle(utterance: [0.1])
        session.handle(utterance: [0.1])
        XCTAssertEqual(count.value, 1)
        latch.rearm()
        session.handle(utterance: [0.1])
        XCTAssertEqual(count.value, 2)
    }

    func test_latchedRepeatReportsNoResolution() {
        let latch = VoiceActivationLatch()
        let observed = Box<VoiceSession.Outcome?>(nil)
        let session = VoiceSession(
            transcribe: { _ in "hey codex" }, now: { 100 }, cooldownSeconds: 0,
            registry: registry(), execute: { _, _ in },
            observe: { observed.value = $0 }, activationLatch: latch)
        session.handle(utterance: [0.1])
        session.handle(utterance: [0.1])
        XCTAssertNil(observed.value?.resolved)
    }

    func test_handleManualEmptyClipDoesNotExecute() {
        let executed = Box(false)
        let session = VoiceSession(
            transcribe: { _ in "   " }, now: { 0 }, cooldownSeconds: 0,
            registry: registry(), execute: { _, _ in executed.value = true })
        XCTAssertFalse(session.handleManual(utterance: [0, 0]))
        XCTAssertFalse(executed.value)
    }
}
