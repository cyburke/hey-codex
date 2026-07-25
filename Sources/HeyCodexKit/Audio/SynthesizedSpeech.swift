import Foundation

/// Ordinary speech, synthesized on the spot with the `say` command every Mac
/// already has.
///
/// Enrollment arms the token sequences the model decoded from the user's
/// recordings, because correct spelling alone often does not fire the spotter. A
/// bad decode can be short and generic, though: one take of "Hey Xena" decoded
/// as `▁IN ▁A`, which would have woken on the words "in a" in any sentence. So
/// candidate lines get screened against speech that is definitely not the wake
/// phrase, and anything that fires is thrown out.
public enum SynthesizedSpeech {
    /// Deliberately full of common short words and near-misses of a wake phrase.
    public static let falseAlarmPhrases = [
        "I can help you with that in a moment",
        "the weather today is sunny and warm",
        "hey there, how are you doing",
        "let me check the code for you and get back",
    ]

    public static func samples(of phrase: String) -> [Float]? {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("heycodex-say-\(UUID().uuidString)")
        let aiff = base.appendingPathExtension("aiff")
        let wav = base.appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }
        guard run("/usr/bin/say", ["-o", aiff.path, phrase]),
              run("/usr/bin/afconvert",
                  ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        else { return nil }
        return try? AudioSamples.load(wav)
    }

    /// Clips that must never fire a wake keyword. Any that fail to synthesize are
    /// simply absent: a missing negative weakens the screen but must not block
    /// enrollment.
    public static func falseAlarmClips() -> [[Float]] {
        falseAlarmPhrases.compactMap { samples(of: $0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
