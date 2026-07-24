import XCTest
@testable import HeyClaudeKit

final class VoiceShortcutTests: XCTestCase {
    func test_defaultIsDedicatedControlOptionV() {
        XCTAssertEqual(VoiceShortcut.default.key, "v")
        XCTAssertTrue(VoiceShortcut.default.control)
        XCTAssertTrue(VoiceShortcut.default.option)
        XCTAssertFalse(VoiceShortcut.default.command)
        XCTAssertEqual(VoiceShortcut.default.displayString, "⌃⌥V")
        XCTAssertEqual(VoiceShortcut.default.virtualKeyCode, 9)
    }

    func test_customShortcutRequiresKnownKeyAndModifier() {
        XCTAssertNil(VoiceShortcut.normalizedKey("vv"))
        XCTAssertFalse(VoiceShortcut(key: "v", control: false, option: false, command: false).isUsable)
        XCTAssertTrue(VoiceShortcut(key: ";", control: true, option: false, command: false).isUsable)
    }

    func test_frontmostChatGPTReceivesDirectShortcutDelivery() {
        XCTAssertEqual(
            VoiceShortcutRouting.destination(
                frontmostBundleIdentifier: VoiceShortcutRouting.chatGPTBundleIdentifier,
                frontmostProcessIdentifier: 1234),
            .application(pid: 1234))
    }

    func test_backgroundChatGPTAndInvalidPidUseGlobalShortcutDelivery() {
        XCTAssertEqual(
            VoiceShortcutRouting.destination(
                frontmostBundleIdentifier: "com.microsoft.edgemac",
                frontmostProcessIdentifier: 1234),
            .systemHID)
        XCTAssertEqual(
            VoiceShortcutRouting.destination(
                frontmostBundleIdentifier: VoiceShortcutRouting.chatGPTBundleIdentifier,
                frontmostProcessIdentifier: 0),
            .systemHID)
    }
}
