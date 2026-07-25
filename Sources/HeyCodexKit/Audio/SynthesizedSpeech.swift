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

    /// Test-only seam: overrides the base directory below `~/Library/Application
    /// Support` normally resolves to, the same pattern `EnrollmentDiagnostics`
    /// uses so tests never touch the real user's directory.
    nonisolated(unsafe) static var baseDirectoryOverride: URL?

    /// The four negative clips cost ~1s each to synthesize (spawning `say` +
    /// `afconvert` dominates, not model inference - measured in
    /// spawning `say` and `afconvert`) and never change, so they
    /// are written to disk once and reused forever after, plus memoized in
    /// memory so repeated calls within one run of the app are free.
    ///
    /// PRIVACY NOTE, since this writes into the same `~/Library/Application
    /// Support/HeyCodex/` directory the privacy rules cover: this
    /// is a DIFFERENT thing from that finding and is not gated behind
    /// `EnrollmentDiagnostics.keepsAudio`, deliberately. What gets written here
    /// is four fixed, built-in, non-personal test sentences (`falseAlarmPhrases`
    /// above) spoken by `say` - never anything the user said, never anything
    /// derived from their microphone. The app's on-screen promise is about the
    /// user's own voice; this cache exists purely to make enrollment fast and
    /// would be identical on every Mac running this build. Gating it behind
    /// `keepsAudio` would defeat the point (nobody would ever see the speed
    /// win) and there is nothing to consent to.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var memoizedNegatives: [[Float]]?

    /// Public so the on-machine `timing` selftest probe can delete it to
    /// measure a genuine cold-cache run, and print it in reports.
    public static var cacheDirectory: URL {
        let base = baseDirectoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HeyCodex/negatives-cache")
    }

    /// A stable (not randomized-per-process, unlike `Hashable`/`hashValue`)
    /// content hash of `falseAlarmPhrases`, folded into the cached filenames so
    /// editing those sentences invalidates the old cache instead of silently
    /// reusing stale audio for wording that no longer exists. FNV-1a, not
    /// CryptoKit: four short strings do not need a cryptographic hash, just a
    /// cheap stable one.
    private static var phrasesContentHash: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in falseAlarmPhrases.joined(separator: "\u{1}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func cachedNegativeURLs() -> [URL] {
        let hash = phrasesContentHash
        return (0..<falseAlarmPhrases.count).map {
            cacheDirectory.appendingPathComponent("negative-\(hash)-\($0).wav")
        }
    }

    /// Whether every negative clip is already cached on disk for the current
    /// `falseAlarmPhrases` content, so callers can tell a user "getting set up"
    /// only on the genuinely slow first run.
    public static var negativesCached: Bool {
        cachedNegativeURLs().allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

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
    ///
    /// Checks the in-memory cache first, then the on-disk cache, and only
    /// synthesizes (concurrently - the four phrases are independent) when
    /// neither has them, writing the result to disk for next time.
    public static func falseAlarmClips() -> [[Float]] {
        cacheLock.lock()
        if let memoized = memoizedNegatives {
            cacheLock.unlock()
            return memoized
        }
        cacheLock.unlock()

        let loaded = loadOrGenerateNegatives()
        cacheLock.lock()
        memoizedNegatives = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func loadOrGenerateNegatives() -> [[Float]] {
        let urls = cachedNegativeURLs()
        let fromDisk = urls.compactMap { try? AudioSamples.load($0) }
        if fromDisk.count == urls.count { return fromDisk }

        let generated = synthesizeConcurrently(falseAlarmPhrases)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for (index, clip) in generated.enumerated() where index < urls.count {
            guard let clip else { continue }
            try? AudioSamples.write(clip, to: urls[index])
        }
        return generated.compactMap { $0 }
    }

    /// Boxes the per-phrase results so `DispatchQueue.concurrentPerform`'s
    /// closure can write into them - matches the `Once` box pattern already
    /// used for a GCD callback in `AudioSamples.load`, rather than introducing
    /// a new concurrency idiom for the same problem.
    private final class ResultsBox: @unchecked Sendable {
        var values: [[Float]?]
        init(count: Int) { values = [[Float]?](repeating: nil, count: count) }
    }

    /// Synthesizes every phrase in parallel: each call to `say`/`afconvert` is
    /// an independent process spawn (~1s), so four of them serially cost ~4s
    /// wall time but cost ~1s run concurrently. `DispatchQueue.concurrentPerform`
    /// rather than a `TaskGroup` because this function stays synchronous - every
    /// existing caller of `falseAlarmClips()` already runs off the main thread
    /// (inside `Task.detached`) and calls it as a plain function, and keeping
    /// that shape means no caller needs to change.
    private static func synthesizeConcurrently(_ phrases: [String]) -> [[Float]?] {
        let box = ResultsBox(count: phrases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: phrases.count) { index in
            let clip = samples(of: phrases[index])
            lock.lock()
            box.values[index] = clip
            lock.unlock()
        }
        return box.values
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
