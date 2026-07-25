import XCTest
@testable import HeyCodexKit

final class WakeEnrollmentTests: XCTestCase {
    // MARK: - Pure token → keyword mapping

    func test_keywordLine_mapsLeadingSpaceToWordBoundary() {
        let tokens = [" HE", "Y", " C", "LO", "U", "D"]
        XCTAssertEqual(WakeEnrollment.keywordLine(from: tokens), "▁HE Y ▁C LO U D")
    }

    func test_keywordLine_dropsEmptyTokens() {
        XCTAssertEqual(WakeEnrollment.keywordLine(from: [" HE", "", "  ", "Y"]), "▁HE Y")
    }

    func test_isPlausibleWake_acceptsMultiTokenPhraseRejectsGlitch() {
        XCTAssertTrue(WakeEnrollment.isPlausibleWake(tokens: [" HE", "Y", " CO", "DE", "X"]))
        XCTAssertFalse(WakeEnrollment.isPlausibleWake(tokens: [" OUT"]))   // the glitch we saw
    }

}
