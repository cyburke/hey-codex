import Foundation
import XCTest
@testable import HeyCodexKit

/// Product-level phrase checks. These exercise the exact bundled keyword files
/// and the actual KWS model, rather than the model's unrelated sample phrase.
final class ProductWakePhraseTests: XCTestCase {
    private func modelsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Models")
    }

    private func spokenWav(_ phrase: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hey-codex-product-test-\(UUID().uuidString)")
        let aiff = base.appendingPathExtension("aiff")
        let wav = base.appendingPathExtension("wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", aiff.path, phrase]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw TestError.command("say") }
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", aiff.path, wav.path]
        try convert.run(); convert.waitUntilExit()
        try? FileManager.default.removeItem(at: aiff)
        guard convert.terminationStatus == 0 else { throw TestError.command("afconvert") }
        return wav
    }

    private func launchEngine() throws -> WakeWordEngine {
        let models = modelsDirectory()
        let model = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        return try WakeWordEngine(modelDir: model,
                                  keywordsFile: models.appendingPathComponent("keywords.txt"),
                                  keywordsThreshold: 0.25,
                                  keywordsScore: 2.0)
    }

    private func maximumLaunchEngine() throws -> WakeWordEngine {
        let models = modelsDirectory()
        let model = models.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        return try WakeWordEngine(modelDir: model,
                                  keywordsFile: models.appendingPathComponent("keywords.txt"),
                                  keywordsThreshold: 0.08,
                                  keywordsScore: 2.0)
    }

    func testHeyCodexTriggersLaunch() throws {
        let wav = try spokenWav("Hey Codex")
        defer { try? FileManager.default.removeItem(at: wav) }
        XCTAssertTrue(try launchEngine().detects(in: AudioSamples.load(wav)))
    }

    func testMaximumLaunchSensitivityRejectsNegativeCorpus() throws {
        XCTAssertFalse(try maximumLaunchEngine().detects(in: [Float](repeating: 0, count: 16_000)))
        let modelSpeech = try AudioSamples.load(
            modelsDirectory()
                .appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01/test_wavs/0.wav"))
        XCTAssertFalse(try maximumLaunchEngine().detects(in: modelSpeech))
        for phrase in ["I can help you with that.", "The weather today is sunny and warm."] {
            let wav = try spokenWav(phrase)
            defer { try? FileManager.default.removeItem(at: wav) }
            XCTAssertFalse(try maximumLaunchEngine().detects(in: AudioSamples.load(wav)), "Unexpected wake for: \(phrase)")
        }
    }

    private enum TestError: Error { case command(String) }
}
