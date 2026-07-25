import Foundation

/// Every tuning value the keyword spotter takes, in one place, with the reason.
///
/// These were previously scattered as literals, and two of them were wrong:
/// `keywords_score` was 2.0 against a library default of 1.0, and the modeling
/// unit was left at "cjkchar" (Chinese characters) while feeding an English BPE
/// model, with no BPE vocabulary supplied at all. Library defaults are from
/// `KeywordSpotterConfig` in sherpa-onnx.
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

    /// Tells sherpa the keywords file is English BPE text rather than CJK
    /// characters, so plain text can be tokenised canonically.
    public static let modelingUnit = "bpe"

    /// Ships inside the KWS model directory.
    public static let bpeVocabName = "bpe.model"

    /// Thresholds tried during enrollment, strictest first. Stops at 0.08 to
    /// stay inside the range the sensitivity control allows.
    public static let calibrationThresholds: [Float] = [0.25, 0.20, 0.15, 0.12, 0.10, 0.08]
}
