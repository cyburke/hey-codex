import XCTest
@testable import HeyCodexKit

final class VoiceActivationLatchTests: XCTestCase {
    func test_consumesOnlyOneWakeUntilExplicitlyRearmed() {
        let latch = VoiceActivationLatch()
        XCTAssertTrue(latch.consumeIfArmed())
        XCTAssertFalse(latch.consumeIfArmed(), "a repeated wake must not toggle Voice")
        latch.rearm()
        XCTAssertTrue(latch.consumeIfArmed())
    }
}
