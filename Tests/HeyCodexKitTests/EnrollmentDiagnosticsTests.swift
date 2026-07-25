import XCTest
@testable import HeyCodexKit

/// P0.1: the app tells the user on screen that nothing is recorded. `record` and
/// `saveAudioIfEnabled` must genuinely produce no on-disk artifact unless someone
/// has deliberately created the opt-in marker file - and once they have, the
/// files must actually appear. P1.5: a write failure must not crash the caller.
///
/// Every test points `baseDirectoryOverride` at a scratch temp directory so
/// nothing here ever touches the real user's `~/Library/Application Support`.
final class EnrollmentDiagnosticsTests: XCTestCase {
    private func withScratchBase(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-diag-test-\(UUID().uuidString)")
        EnrollmentDiagnostics.baseDirectoryOverride = dir
        defer {
            EnrollmentDiagnostics.baseDirectoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func sampleResult() -> WakeCalibration.Result {
        WakeCalibration.Result(keywordLine: "\u{2581}HE Y \u{2581}CO DE X :1.5",
                              threshold: 0.15, firedCount: 3, sampleCount: 3)
    }

    func test_recordWritesNothingWithoutTheMarkerFile() {
        withScratchBase { _ in
            EnrollmentDiagnostics.record(phrase: "hey codex", tokens: "▁HE Y ▁CO DE X",
                                        sampleCounts: [16000], result: sampleResult())
            EnrollmentDiagnostics.saveAudioIfEnabled([[Float](repeating: 0, count: 16000)])
            XCTAssertFalse(FileManager.default.fileExists(atPath: EnrollmentDiagnostics.fileURL.path),
                           "no marker file present - enrollment must leave no enrollment.log")
            XCTAssertFalse(FileManager.default.fileExists(atPath: EnrollmentDiagnostics.audioDirectory.path),
                           "no marker file present - enrollment must leave no audio either")
        }
    }

    func test_recordWritesWithTheMarkerFilePresent() throws {
        try withScratchBase { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("HeyCodex"),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent("HeyCodex/keep-enrollment-audio").path, contents: nil)
            XCTAssertTrue(EnrollmentDiagnostics.keepsAudio)

            EnrollmentDiagnostics.record(phrase: "hey codex", tokens: "▁HE Y ▁CO DE X",
                                        sampleCounts: [16000], result: sampleResult())
            EnrollmentDiagnostics.saveAudioIfEnabled([[Float](repeating: 0, count: 1600)])

            XCTAssertTrue(FileManager.default.fileExists(atPath: EnrollmentDiagnostics.fileURL.path),
                         "marker file present - enrollment.log should be written")
            let contents = try String(contentsOf: EnrollmentDiagnostics.fileURL, encoding: .utf8)
            XCTAssertTrue(contents.contains("phrase=hey codex"))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: EnrollmentDiagnostics.audioDirectory.appendingPathComponent("take-1.wav").path))
        }
    }

    /// P1.5: when `enrollment.log`'s own path is unwritable (occupied by a
    /// directory instead of a file), the write fails - `record` must not crash.
    /// Before this fix every write here was `try?`, so a failure and a working
    /// write were indistinguishable; this only proves the failure path is safe,
    /// since asserting the os_log side effect itself needs Console.app, not XCTest.
    func test_recordDoesNotCrashWhenTheLogPathIsUnwritable() throws {
        try withScratchBase { dir in
            let heyCodexDir = dir.appendingPathComponent("HeyCodex")
            try FileManager.default.createDirectory(at: heyCodexDir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: heyCodexDir.appendingPathComponent("keep-enrollment-audio").path, contents: nil)
            XCTAssertTrue(EnrollmentDiagnostics.keepsAudio)
            // Occupy enrollment.log's own path with a directory so no write can succeed.
            try FileManager.default.createDirectory(at: EnrollmentDiagnostics.fileURL,
                                                    withIntermediateDirectories: true)

            EnrollmentDiagnostics.record(phrase: "hey codex", tokens: "▁HE Y ▁CO DE X",
                                        sampleCounts: [16000], result: sampleResult())
            // No crash reaching here is the assertion. The path is still a
            // directory, not silently replaced by log content.
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: EnrollmentDiagnostics.fileURL.path, isDirectory: &isDir))
            XCTAssertTrue(isDir.boolValue)
        }
    }
}
