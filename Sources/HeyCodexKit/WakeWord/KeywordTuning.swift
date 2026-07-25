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
    /// default is 1.0. `score` and `numTrailingBlanks` were both GUESSED
    /// (1.5, 2) until measured against a 5-voice synthetic corpus plus real
    /// audio in `TUNING-2026-07-25.md` - regenerate with
    /// `swift run hey-codex-selftest tuning`. That grid swept score in
    /// {1.0, 1.25, 1.5, 1.75, 2.0} x numTrailingBlanks in {1, 2, 3} at this
    /// threshold and found 1.25/1 wakes on more of the corpus than the old
    /// 1.5/2 guess, at zero measured false alarms either way - so the guess
    /// had over-corrected the boost, not under-corrected it.
    public static let score: Float = 1.25

    /// Beam width. Library default.
    public static let maxActivePaths = 4

    /// Blank frames required after the keyword before it is finalised. The
    /// library default is 1. Higher waits for a pause after the keyword before
    /// firing, which suppresses a keyword fragment matched mid-sentence at the
    /// cost of latency. Measured in `TUNING-2026-07-25.md`: 1 reached the
    /// same zero-false-alarm result as the previously-guessed 2, with less
    /// latency, so there was no measured benefit to waiting longer.
    public static let numTrailingBlanks = 1

    /// Thresholds tried during enrollment, strictest first. Stops at 0.08 to
    /// stay inside the range the sensitivity control allows.
    public static let calibrationThresholds: [Float] = [0.25, 0.20, 0.15, 0.12, 0.10, 0.08]
}
