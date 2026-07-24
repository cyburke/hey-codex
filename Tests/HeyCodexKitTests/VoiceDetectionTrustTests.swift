import XCTest
@testable import HeyCodexKit

final class VoiceDetectionTrustTests: XCTestCase {
    func test_startsUnprovenSoAbsenceIsNeverEvidence() {
        XCTAssertFalse(VoiceDetectionTrust().isProven)
    }

    func test_seeingThePanelOnceProvesDetectionAndReportsTheFirstProofOnly() {
        let trust = VoiceDetectionTrust()
        XCTAssertTrue(trust.observedPanel(), "first proof must be persisted")
        XCTAssertTrue(trust.isProven)
        XCTAssertFalse(trust.observedPanel(), "already proven - nothing new to persist")
    }

    func test_unprovenDetectorNeverRevokesItself() {
        let trust = VoiceDetectionTrust()
        for _ in 0..<(VoiceDetectionTrust.failureBudget * 2) {
            XCTAssertFalse(trust.launchWentUnconfirmed())
        }
        XCTAssertFalse(trust.isProven)
    }

    func test_provenDetectorSurvivesMissesUpToTheBudget() {
        let trust = VoiceDetectionTrust(isProven: true)
        for _ in 0..<(VoiceDetectionTrust.failureBudget - 1) {
            XCTAssertFalse(trust.launchWentUnconfirmed())
            XCTAssertTrue(trust.isProven)
        }
    }

    func test_provenDetectorRevokesItselfAfterTheBudgetIsSpent() {
        let trust = VoiceDetectionTrust(isProven: true)
        var revoked = false
        for _ in 0..<VoiceDetectionTrust.failureBudget {
            revoked = trust.launchWentUnconfirmed() || revoked
        }
        XCTAssertTrue(revoked, "a stale detector must fall back, not block the user")
        XCTAssertFalse(trust.isProven)
    }

    /// One good launch clears the run of misses, so intermittent slowness never
    /// accumulates into a revocation.
    func test_oneConfirmedLaunchResetsTheFailureRun() {
        let trust = VoiceDetectionTrust(isProven: true)
        for _ in 0..<(VoiceDetectionTrust.failureBudget - 1) {
            _ = trust.launchWentUnconfirmed()
        }
        trust.observedPanel()
        for _ in 0..<(VoiceDetectionTrust.failureBudget - 1) {
            XCTAssertFalse(trust.launchWentUnconfirmed())
        }
        XCTAssertTrue(trust.isProven)
    }

    func test_revokedDetectorCanBeProvenAgain() {
        let trust = VoiceDetectionTrust(isProven: true)
        for _ in 0..<VoiceDetectionTrust.failureBudget { _ = trust.launchWentUnconfirmed() }
        XCTAssertFalse(trust.isProven)
        XCTAssertTrue(trust.observedPanel())
        XCTAssertTrue(trust.isProven)
    }
}
