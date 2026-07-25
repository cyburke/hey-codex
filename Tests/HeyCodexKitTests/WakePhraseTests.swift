import XCTest
@testable import HeyCodexKit

final class WakePhraseTests: XCTestCase {
    func test_defaultWakePhraseIsHeyCodex() {
        XCTAssertEqual(Settings.default.wakePhrase, "Hey Codex")
    }

    func test_presetsAreASmallSetOfSuggestions() {
        XCTAssertEqual(WakePhrase.presets, ["Hey Codex", "Hey Jarvis", "Hey Computer"])
        XCTAssertTrue(WakePhrase.presets.allSatisfy(WakePhrase.isRecommended))
    }

}
