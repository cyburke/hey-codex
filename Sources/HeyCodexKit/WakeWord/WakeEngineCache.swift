import Foundation

/// Caches one `WakeWordEngine` per (keyword line, threshold) pair, since engine
/// construction (~226ms, loading 3 ONNX models) dominates cost far more than
/// `detects(in:)` on an already-built engine (~76ms) - measured in
/// the enrollment-latency work. Enrollment tests the same
/// (line, threshold) pair against every recorded clip and every negative clip
/// in turn, so building the engine once per pair instead of once per clip
/// collapses calibration's 18 constructions (6 thresholds x 3 takes) down to 6.
///
/// Reuse safety was verified, not assumed: `WakeWordEngine.detects(in:)` already
/// calls `reset()` on its single internal stream before every return, but that
/// path had never actually been exercised for reuse in production (the live
/// listening loop uses the separate, non-finished `feed(_:)`, and every call
/// site here used to build a fresh engine per clip). `swift run
/// hey-codex-selftest timing` now includes `engineReuseGivesIdenticalResults`,
/// which runs the same set of clips through a fresh engine per clip and through
/// one shared, reused engine and asserts the fire/no-fire result is identical
/// for every clip at every threshold tried. It is.
///
/// NOT thread-safe by design: every caller here drives its `fires` closure
/// sequentially from inside one `Task.detached` body (`WakeCalibration` and
/// `WakeCandidateSearch` never call `fires` concurrently), so no lock is taken.
/// Do not share one instance across concurrent callers.
/// `@unchecked Sendable`: `WakeCalibration.fires` requires `@Sendable` because
/// it may be handed to a `Task.detached`, but this cache is only ever touched
/// from the single task that owns it (see the not-thread-safe note above), so
/// there is no actual concurrent access for the compiler to catch.
public final class WakeEngineCache: @unchecked Sendable {
    private var engines: [String: WakeWordEngine] = [:]
    private let modelDir: URL

    public init(modelDir: URL) { self.modelDir = modelDir }

    /// Matches the `fires` closure shape `WakeCalibration` and
    /// `WakePhraseFitness` already take, so it drops in as that closure.
    public func fires(_ line: String, threshold: Float, audio: [Float]) -> Bool {
        let key = "\(line)\u{1}\(threshold)"
        let engine: WakeWordEngine
        if let cached = engines[key] {
            engine = cached
        } else {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("heycodex-cal-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil,
                  let built = try? WakeWordEngine(modelDir: modelDir, keywordsFile: file,
                                                  keywordsThreshold: threshold)
            else { return false }
            engines[key] = built
            engine = built
        }
        return engine.detects(in: audio)
    }
}
