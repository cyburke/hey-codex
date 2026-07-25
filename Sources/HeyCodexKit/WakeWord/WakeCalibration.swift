import Foundation

/// Builds a keyword entry for a phrase and calibrates how eagerly it should fire.
///
/// The keyword comes from the phrase's own spelling, tokenised against the model's
/// vocabulary. Deriving it instead from what the model decoded out of a recording
/// was tried and measured: those lines fire on nothing, not even the takes they came
/// from, and the only ones that did fire were short generic fragments like `▁IN ▁A`,
/// which would wake on the words "in a" in any sentence. `WakePhraseFitness` decides
/// up front whether a phrase can be spotted at all; this type only tunes how
/// sensitive it needs to be for one particular voice.
public struct WakeCalibration {
    public struct Result: Equatable, Sendable {
        /// The keyword file line to persist.
        public let keywordLine: String
        public var keywordLines: [String] { [keywordLine] }
        /// Threshold chosen, recorded so the UI can warn when it had to go low.
        public let threshold: Float
        /// How many of the supplied recordings fired at that threshold.
        public let firedCount: Int
        public let sampleCount: Int

        public var allFired: Bool { firedCount == sampleCount && sampleCount > 0 }
        /// Enough to trust, without demanding perfection from every take. One bad
        /// recording out of three should not throw away two good ones.
        public var isUsable: Bool { sampleCount > 0 && firedCount * 2 > sampleCount }
        /// Landing on the loosest threshold means false triggers are likely.
        public var isMarginal: Bool { threshold <= 0.10 }
    }

    /// Whether `lines` at `threshold` fires on `audio`. Injected so calibration
    /// is testable without a model.
    public let fires: @Sendable (_ line: String, _ threshold: Float, _ audio: [Float]) -> Bool
    public let thresholds: [Float]

    public init(fires: @escaping @Sendable (String, Float, [Float]) -> Bool,
                thresholds: [Float] = KeywordTuning.calibrationThresholds) {
        self.fires = fires
        self.thresholds = thresholds
    }

    /// Compose a keyword file line with an explicit per-keyword boost and
    /// threshold, which is how sherpa documents tuning one keyword without
    /// disturbing any other.
    /// A per-keyword `#threshold` overrides the global one, which would make the
    /// sensitivity control inert. With a single active keyword the two are
    /// equivalent, so the shipped line carries only the score and the calibrated
    /// threshold is stored as the setting the user can still adjust. The
    /// threshold form stays available for when more than one keyword is armed.
    public static func keywordLine(tokens: String,
                                   score: Float = KeywordTuning.score,
                                   threshold: Float? = nil) -> String {
        // Two decimals, not one: the measured score is 1.25 and "%.1f" wrote it
        // out as 1.2, silently discarding the value the tuning sweep exists to
        // justify. A persisted keyword line must carry the number the app decided on.
        var line = "\(tokens) :\(String(format: "%.2f", score))"
        if let threshold { line += " #\(String(format: "%.2f", threshold))" }
        return line
    }

    /// Build the keyword set: the canonical line first, then any distinct variant
    /// the model produced for these recordings.
    ///
    /// Find the strictest threshold at which the user's recordings fire.
    ///
    /// Strictest first, so a phrase that works cleanly is not left needlessly
    /// twitchy. Stops as soon as every recording fires.
    public func calibrate(tokens: String, samples: [[Float]]) -> Result {
        let persisted = Self.keywordLine(tokens: tokens)
        guard !samples.isEmpty else {
            return Result(keywordLine: persisted, threshold: KeywordTuning.threshold,
                          firedCount: 0, sampleCount: 0)
        }
        var best = (threshold: thresholds.last ?? KeywordTuning.threshold, fired: 0)
        for threshold in thresholds {
            let probe = Self.keywordLine(tokens: tokens, threshold: threshold)
            let fired = samples.filter { fires(probe, threshold, $0) }.count
            if fired > best.fired { best = (threshold, fired) }
            if fired == samples.count {
                return Result(keywordLine: persisted, threshold: threshold,
                              firedCount: fired, sampleCount: samples.count)
            }
        }
        return Result(keywordLine: persisted, threshold: best.threshold,
                      firedCount: best.fired, sampleCount: samples.count)
    }
}
