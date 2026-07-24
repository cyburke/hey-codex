import XCTest
@testable import HeyCodexKit

final class WakePhraseTests: XCTestCase {
    func test_defaultWakePhraseIsHeyCodex() {
        XCTAssertEqual(Settings.default.wakePhrase, "Hey Codex")
    }

    func test_presetsIncludeHeyJarvisAsAnOptionalPhrase() {
        XCTAssertEqual(WakePhrase.presets, ["Hey Codex", "Hey ChatGPT", "Hey Jarvis"])
        XCTAssertTrue(WakePhrase.isRecommended("Hey Jarvis"))
    }

}
