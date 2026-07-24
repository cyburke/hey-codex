import XCTest
@testable import HeyCodexKit

final class SetupStateTests: XCTestCase {
    private func state(_ mic: MicrophoneAuthorization,
                       trusted: Bool = false,
                       canPost: Bool = false) -> SetupState {
        SetupStateResolver.state(microphone: mic,
                                 accessibilityTrusted: trusted,
                                 canPostEvents: canPost)
    }

    func test_microphoneComesFirst() {
        XCTAssertEqual(state(.notDetermined), .needsMicrophone)
        // Even with accessibility already sorted, the mic is still step one.
        XCTAssertEqual(state(.notDetermined, trusted: true, canPost: true), .needsMicrophone)
    }

    func test_refusedMicrophoneIsItsOwnStepBecauseOnlySettingsFixesIt() {
        XCTAssertEqual(state(.denied), .microphoneBlocked)
        XCTAssertEqual(state(.denied, trusted: true, canPost: true), .microphoneBlocked)
    }

    func test_microphoneDoneMovesToAccessibility() {
        XCTAssertEqual(state(.authorized), .needsAccessibility)
    }

    /// The state this whole design exists for. macOS has the grant, but this
    /// process was told no and will never be told otherwise, so the honest
    /// instruction is "relaunch", not "try again".
    func test_grantedButStaleProcessAsksForARelaunch() {
        XCTAssertEqual(state(.authorized, trusted: true, canPost: false),
                       .accessibilityPendingRelaunch)
    }

    func test_bothPermissionsPresentIsReady() {
        XCTAssertEqual(state(.authorized, trusted: true, canPost: true), .ready)
        XCTAssertTrue(state(.authorized, trusted: true, canPost: true).isComplete)
    }

    /// A process that can post events is done, whatever AXIsProcessTrusted says.
    /// Being able to do the thing outranks any API's opinion about it.
    func test_abilityToPostOutranksTheTrustFlag() {
        XCTAssertEqual(state(.authorized, trusted: false, canPost: true), .ready)
    }

    func test_onlyReadyCountsAsComplete() {
        for s: SetupState in [.needsMicrophone, .microphoneBlocked,
                              .needsAccessibility, .accessibilityPendingRelaunch] {
            XCTAssertFalse(s.isComplete, "\(s) must not read as finished setup")
        }
    }
}
