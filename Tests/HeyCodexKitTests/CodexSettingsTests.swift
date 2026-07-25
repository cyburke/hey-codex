import XCTest
@testable import HeyCodexKit

final class CodexSettingsTests: XCTestCase {
    func test_defaultSettingsUseTheVoiceShortcutCommand() {
        let settings = Settings.default
        XCTAssertEqual(settings.defaultCommandID, "codex-voice")
        XCTAssertEqual(settings.promptCommandID, "codex-voice")
        XCTAssertEqual(settings.commands, Command.seededDefaults)
    }

    /// One source of truth: a fresh install must run at the calibrated score, not
    /// a second hardcoded literal that can silently drift from it (AUDIT-2026-07-24.md
    /// P0.2 - the default was 2.0 while KeywordTuning.score, the value the code's
    /// own comment calls the safe ceiling, was 1.5).
    func test_defaultWakeKeywordsScoreMatchesCalibratedTuning() {
        XCTAssertEqual(Settings.default.wakeKeywordsScore, KeywordTuning.score)
    }

    /// P2: `pushToTalkKey` was removed (dead feature - no CGEventTap exists
    /// anywhere in the app), but it was persisted to every user's settings.json
    /// before this. Decoding an old file that still carries the field must not
    /// fail - Codable ignores keys it has no CodingKeys case for.
    func test_decodingOldSettingsWithRemovedPushToTalkKeyDoesNotFail() throws {
        let legacy = """
            {"projectDirectory":"/tmp","preferredTarget":{"type":"terminal","value":"Terminal"},\
            "wakeKeywordsScore":1.5,"wakeKeywordsThreshold":0.25,"cooldownSeconds":2,\
            "claudeExecutable":"claude","defaultCommandID":"codex-voice","promptCommandID":"codex-voice",\
            "pushToTalkEnabled":true,"pushToTalkKey":"rightOption","wakePhrase":"Hey Codex"}
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.wakePhrase, "Hey Codex")
        XCTAssertTrue(settings.pushToTalkEnabled)
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
