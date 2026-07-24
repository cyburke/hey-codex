import XCTest
@testable import HeyCodexKit

final class CodexSettingsTests: XCTestCase {
    func test_defaultSettingsUseTheVoiceShortcutCommand() {
        let settings = Settings.default
        XCTAssertEqual(settings.defaultCommandID, "codex-voice")
        XCTAssertEqual(settings.promptCommandID, "codex-voice")
        XCTAssertEqual(settings.commands, Command.seededDefaults)
    }

    func test_settingsRoundTripPreservesWakePhraseAndShortcut() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hey-codex-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = SettingsStore(fileURL: fileURL)
        var settings = Settings.default
        settings.wakePhrase = "Hey Jarvis"
        settings.wakeKeywordsThreshold = 0.08
        settings.voiceShortcut = VoiceShortcut(key: ";", control: true, option: false, command: false)
        settings.voiceShortcutSetupCompleted = true
        try store.save(settings)
        XCTAssertEqual(store.load().wakePhrase, "Hey Jarvis")
        XCTAssertEqual(store.load().wakeKeywordsThreshold, 0.08)
        XCTAssertEqual(store.load().voiceShortcut, settings.voiceShortcut)
        XCTAssertTrue(store.load().voiceShortcutSetupCompleted)
    }
}
