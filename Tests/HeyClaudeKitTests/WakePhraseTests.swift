import XCTest
@testable import HeyClaudeKit

final class WakePhraseTests: XCTestCase {
    func test_defaultWakePhraseIsHeyCodex() {
        XCTAssertEqual(Settings.default.wakePhrase, "Hey Codex")
    }

    func test_presetsIncludeHeyJarvisAsAnOptionalPhrase() {
        XCTAssertEqual(WakePhrase.presets, ["Hey Codex", "Hey ChatGPT", "Hey Jarvis"])
        XCTAssertTrue(WakePhrase.isRecommended("Hey Jarvis"))
    }

    func test_closePhraseIsSeparateFromTheLaunchPhrase() {
        XCTAssertEqual(VoiceClosePhrase.displayName, "Close Codex")
        XCTAssertNotEqual(VoiceClosePhrase.keywordLine, "▁HE Y ▁CO DE X")
    }
}
