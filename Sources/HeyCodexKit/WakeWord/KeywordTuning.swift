import Foundation

/// Every tuning value the keyword spotter takes, in one place, with the reason.
///
/// These were previously scattered as literals, and `keywords_score` was one of
/// them: 2.0 against a library default of 1.0. The modeling unit is left at the
/// library's "cjkchar" default deliberately - every keyword is pre-tokenized by
/// `KeywordTokenizer` before sherpa ever sees it, so the BPE-vs-cjkchar setting
/// has no effect here; measured across the model's own reference audio and real
/// enrollment takes at every threshold (AUDIT-2026-07-24.md P1.4). Library
/// defaults are from `KeywordSpotterConfig` in sherpa-onnx.
public enum KeywordTuning {
    /// Acoustic probability needed to trigger. Lower fires more readily.
    /// Library default, and a sensible baseline for a phrase the user has not
    /// calibrated; enrollment lowers it per keyword when a voice needs it.
    public static let threshold: Float = 0.25

    /// Bonus keeping keyword paths alive through the beam search. The library
    /// default is 1.0. Values above roughly 2 start surfacing keywords on weak
    /// acoustic evidence, which reads to a user as random triggering.
    public static let score: Float = 1.5

    /// Beam width. Library default.
    public static let maxActivePaths = 4

    /// Blank frames required after the keyword before it is finalised. The
    /// library default of 1 finalises almost immediately, which fires on
    /// keywords embedded mid-sentence. A wake word is nearly always said on its
    /// own, so waiting for a short pause is the cheapest false-trigger defence
    /// available.
    public static let numTrailingBlanks = 2

    /// Thresholds tried during enrollment, strictest first. Stops at 0.08 to
    /// stay inside the range the sensitivity control allows.
    public static let calibrationThresholds: [Float] = [0.25, 0.20, 0.15, 0.12, 0.10, 0.08]
}
