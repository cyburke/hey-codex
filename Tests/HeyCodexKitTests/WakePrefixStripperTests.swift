import XCTest
@testable import HeyCodexKit

final class WakePrefixStripperTests: XCTestCase {
    func test_bareWake_returnsNil() {
        XCTAssertNil(WakePrefixStripper.command(from: "hey codex"))
        XCTAssertNil(WakePrefixStripper.command(from: "hey codec."))
        XCTAssertNil(WakePrefixStripper.command(from: "cl hey codex."))
    }
    func test_codeCommand() {
        XCTAssertEqual(WakePrefixStripper.command(from: "hey, codex code."), "code")
        XCTAssertEqual(WakePrefixStripper.command(from: "hey codex code"), "code")
    }
    func test_multiWordPrompt() {
        XCTAssertEqual(
            WakePrefixStripper.command(from: "hey codex refactor the auth module"),
            "refactor the auth module")
    }
    func test_optionalWakePhrasesStripThePrefix() {
        XCTAssertEqual(WakePrefixStripper.command(from: "hey jarvis open the app"), "open the app")
        XCTAssertEqual(WakePrefixStripper.command(from: "hey chatgpt code"), "code")
    }
}
