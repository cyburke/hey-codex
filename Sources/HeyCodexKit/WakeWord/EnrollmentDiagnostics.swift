import Foundation

/// Writes one line per enrollment attempt next to the settings file - opt-in only.
///
/// Enrollment can fail for reasons invisible from the UI: clips too short, the
/// model decoding three different token sequences for the same phrase, or a
/// threshold sweep that never makes every take fire. Without a record, a
/// rejection is unexplainable to the user and unfixable by anyone else. But the
/// app tells the user on screen that nothing is recorded or stored, so this must
/// never write anything unless someone has deliberately created the marker file
/// below - there is no UI path to it.
public enum EnrollmentDiagnostics {
    /// Test-only seam: overrides the base directory below `~/Library/Application
    /// Support` normally resolves to. Internal (not public), so it cannot be set
    /// from HeyCodexApp - only `@testable import` reaches it. Without this, a test
    /// exercising `record`/`saveAudioIfEnabled` would write into the real user's
    /// Application Support directory.
    nonisolated(unsafe) static var baseDirectoryOverride: URL?

    public static var fileURL: URL {
        let base = baseDirectoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HeyCodex/enrollment.log")
    }

    /// Only exists when the marker file below is present. Enrollment audio is
    /// otherwise discarded the moment calibration finishes.
    public static var audioDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("enrollment-audio")
    }

    /// Opt-in, and off unless someone deliberately creates the marker file. This
    /// exists so a failing enrollment can be replayed offline rather than
    /// re-recorded over and over.
    public static var keepsAudio: Bool {
        FileManager.default.fileExists(
            atPath: fileURL.deletingLastPathComponent()
                .appendingPathComponent("keep-enrollment-audio").path)
    }

    public static func saveAudioIfEnabled(_ clips: [[Float]]) {
        guard keepsAudio else { return }
        let dir = audioDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.diagnostics.error("enrollment-audio directory create failed: \(String(describing: error), privacy: .public)")
            return
        }
        for (index, clip) in clips.enumerated() {
            let url = dir.appendingPathComponent("take-\(index + 1).wav")
            try? FileManager.default.removeItem(at: url)
            do {
                try AudioSamples.write(clip, to: url)
            } catch {
                Log.diagnostics.error("enrollment audio write failed for take-\(index + 1, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Which armed line fires on which take, at each threshold tried. A single
    /// "fired=0/3" cannot distinguish a phrase this model cannot hear from a
    /// keyword file it rejected outright.
    public static func grid(lines: [String],
                            thresholds: [Float],
                            samples: [[Float]],
                            fires: (String, Float, [Float]) -> Bool) -> String {
        var out = "grid rows=line cols=threshold, cell=takes fired\n"
        for (index, line) in lines.enumerated() {
            let cells = thresholds.map { threshold in
                let fired = samples.filter { fires(line, threshold, $0) }.count
                return "\(fired)"
            }
            out += "  line\(index + 1) \(cells.joined(separator: " "))  [\(line)]\n"
        }
        out += "  thresholds \(thresholds.map { String(format: "%.2f", $0) }.joined(separator: " "))\n"
        return out
    }

    /// Opt-in, gated by the same marker as `keepsAudio` (see above) - not a
    /// second on/off switch to keep in sync. With no marker file, an enrollment
    /// leaves no `enrollment.log` at all, matching the privacy claim the app
    /// makes on screen (AUDIT-2026-07-24.md P0.1).
    public static func record(phrase: String,
                              tokens: String,
                              sampleCounts: [Int],
                              grid: String = "",
                              result: WakeCalibration.Result) {
        guard keepsAudio else { return }
        let seconds = sampleCounts.map { String(format: "%.2fs", Double($0) / 16000.0) }
        let entry = """
            phrase=\(phrase)
            tokens=[\(tokens)]
            clips=\(seconds.joined(separator: ", "))
            armed=\(result.keywordLines.map { "[\($0)]" }.joined(separator: " "))
            \(grid)threshold=\(result.threshold) fired=\(result.firedCount)/\(result.sampleCount) usable=\(result.isUsable) marginal=\(result.isMarginal)

            """
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try handle.write(contentsOf: Data(entry.utf8))
                try handle.close()
            } else {
                try Data(entry.utf8).write(to: url)
            }
        } catch {
            // Every write here used to be `try?` - a failed write and a working
            // one looked identical, for the one component whose entire purpose is
            // leaving a record (AUDIT-2026-07-24.md P1.5).
            Log.diagnostics.error("enrollment.log write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
