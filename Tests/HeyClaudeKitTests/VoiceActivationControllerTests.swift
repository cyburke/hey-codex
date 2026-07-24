import XCTest
@testable import HeyClaudeKit

final class VoiceActivationControllerTests: XCTestCase {
    func testWakePostsExactlyOnceUntilRearmed() {
        let state = VoiceActivationController()
        XCTAssertTrue(state.beginLaunch())
        XCTAssertFalse(state.beginLaunch())
        state.completeLaunch(success: true)
        XCTAssertFalse(state.beginLaunch())
        state.rearm()
        XCTAssertTrue(state.beginLaunch())
    }

    func testFailedLaunchRearmsWithoutPostingClose() {
        let state = VoiceActivationController()
        XCTAssertTrue(state.beginLaunch())
        state.completeLaunch(success: false)
        XCTAssertTrue(state.isArmed)
        XCTAssertFalse(state.beginClose())
    }

    func testClosePostsExactlyOnceAndRearmsAfterSuccess() {
        let state = VoiceActivationController()
        XCTAssertTrue(state.beginLaunch())
        state.completeLaunch(success: true)
        XCTAssertTrue(state.beginClose())
        XCTAssertFalse(state.beginClose())
        state.completeClose(success: true)
        XCTAssertTrue(state.isArmed)
        XCTAssertTrue(state.beginLaunch())
    }

    func testFailedCloseStaysLatchedButCanRetry() {
        let state = VoiceActivationController()
        XCTAssertTrue(state.beginLaunch())
        state.completeLaunch(success: true)
        XCTAssertTrue(state.beginClose())
        state.completeClose(success: false)
        XCTAssertFalse(state.isArmed)
        XCTAssertTrue(state.beginClose())
    }
}
