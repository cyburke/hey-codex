import XCTest
@testable import HeyClaudeKit

final class ClosePhraseArbiterTests: XCTestCase {
    func testCloseFirstThenRepeatedLaunchCancelsTheQueuedClose() {
        let arbiter = ClosePhraseArbiter()
        let ticket = try! XCTUnwrap(arbiter.beginCloseCandidate())
        // Models can finish on adjacent audio frames. The repeated launch is
        // later, but must still invalidate the already-pending close.
        arbiter.cancelPendingCloseForRepeatedLaunch()
        XCTAssertFalse(arbiter.claimClose(ticket))
    }

    func testCloseWithoutRepeatedLaunchClaimsExactlyOnceAfterGraceWindow() {
        let arbiter = ClosePhraseArbiter()
        let ticket = try! XCTUnwrap(arbiter.beginCloseCandidate())
        XCTAssertTrue(arbiter.claimClose(ticket))
        XCTAssertFalse(arbiter.claimClose(ticket))
    }

    func testDuplicateCloseCandidatesScheduleOnlyOneClose() {
        let arbiter = ClosePhraseArbiter()
        XCTAssertNotNil(arbiter.beginCloseCandidate())
        XCTAssertNil(arbiter.beginCloseCandidate())
    }

    func testCancellationJustBeforeClaimWins() {
        let arbiter = ClosePhraseArbiter()
        let ticket = try! XCTUnwrap(arbiter.beginCloseCandidate())
        arbiter.cancelPendingCloseForRepeatedLaunch()
        XCTAssertFalse(arbiter.claimClose(ticket))
    }
}
