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
    /// a second hardcoded literal that can silently drift from it (they
    /// P0.2 - the default was 2.0 while KeywordTuning.score, the value the code's
    /// own comment calls the safe ceiling, was 1.5).
    func test_defaultWakeKeywordsScoreMatchesCalibratedTuning() {
        XCTAssertEqual(Settings.default.wakeKeywordsScore, KeywordTuning.score)
    }

    /// Removed fields: `pushToTalkKey`, `pushToTalkEnabled`,
    /// `mascotID`, `mascotColorHex`, `mascotIdleAnimations`, `claudeExecutable`,
    /// `onboardingCompleted`, and `preferredTarget` (with the terminal/editor
    /// routing layer it pointed at) are all gone - every one was persisted to
    /// every user's settings.json for a feature the app doesn't have. Decoding
    /// an old file that still carries any of them must not fail - Codable
    /// ignores keys it has no CodingKeys case for.
    func test_decodingOldSettingsWithRemovedFieldsDoesNotFail() throws {
        let legacy = """
            {"projectDirectory":"/tmp","preferredTarget":{"type":"editor","value":"Cursor"},\
            "wakeKeywordsScore":1.5,"wakeKeywordsThreshold":0.25,"cooldownSeconds":2,\
            "claudeExecutable":"claude","defaultCommandID":"codex-voice","promptCommandID":"codex-voice",\
            "onboardingCompleted":true,"mascotID":"classic","mascotColorHex":"#D87757",\
            "mascotIdleAnimations":true,"pushToTalkEnabled":true,"pushToTalkKey":"rightOption",\
            "wakePhrase":"Hey Codex"}
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.wakePhrase, "Hey Codex")
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
