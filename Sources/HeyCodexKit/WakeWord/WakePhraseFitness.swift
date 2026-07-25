import Foundation

/// Whether this model can spot a phrase at all, decided before anyone records it.
///
/// Measured, not guessed. Two earlier guesses were both wrong: that the tokens the
/// model decodes from a recording make a better keyword than the phrase's own
/// spelling (they fire on nothing: a decode of "Hey Xena" as `▁A Z EN A` failed on
/// the very takes it came from), and that a fallback boundary token in the
/// tokenisation predicts failure (`yo robot` and `hey zorp` contain one and wake
/// perfectly). See `swift run hey-codex-selftest phrase-fitness`.
///
/// What does predict it is simply trying the phrase. macOS can speak any phrase
/// with `say`, so the app synthesizes it and tests the real keyword against real
/// audio in about a second. "Hey Xena" fails every threshold; "Hey Jarvis" fires at
/// the strictest one. `WakePhraseEnrollmentWindowController` runs this check right
/// after the Record button is pressed and before any recording starts (not on
/// every keystroke) - better to say so before burning three takes on a phrase
/// that cannot work than after.
///
/// When a phrase does come back `.cannotSpot` and it contains a word starting
/// with X or Z, there is now a real mechanical reason to point to instead of a
/// shrug: this vocabulary has zero word-initial pieces for either letter (see
/// `startsWithUnspellableLetter`). This stays a warning, never a refusal - the
/// user's own recordings are the real authority, and `WakeCandidateSearch`
/// trying the phrase's other words may well rescue it anyway (e.g. "Hey Xena"
/// -> "Xena" fires 3/3 on real takes).
public enum WakePhraseFitness {
    public enum Verdict: Equatable, Sendable {
        /// Worth recording.
        case good
        /// The keyword never fired, at any threshold. Recording will not help.
        case cannotSpot
        /// Fires on ordinary sentences, so it would wake on its own.
        case tooCommon
    }

    /// - Parameters:
    ///   - spoken: the phrase as audio, or nil if speech synthesis is unavailable.
    ///   - negatives: clips that must not fire.
    ///   - fires: whether the keyword line fires at a threshold on some audio.
    public static func check(tokens: String,
                            spoken: [Float]?,
                            negatives: [[Float]],
                            thresholds: [Float] = KeywordTuning.calibrationThresholds,
                            fires: (_ line: String, _ threshold: Float, _ audio: [Float]) -> Bool)
    -> Verdict {
        // No synthesized audio means no evidence either way. Never block someone
        // from recording on the strength of a check that could not run.
        guard let spoken else { return .good }
        let line = WakeCalibration.keywordLine(tokens: tokens)
        let strictest = thresholds.first ?? KeywordTuning.threshold
        if negatives.contains(where: { fires(line, strictest, $0) }) { return .tooCommon }
        guard thresholds.contains(where: { fires(line, $0, spoken) }) else { return .cannotSpot }
        return .good
    }

    /// Letters this vocabulary has no word-initial piece for at all. Measured
    /// directly against the model's `tokens.txt` (500 pieces): zero begin
    /// `▁X` or `▁Z`, every other letter has at least two. A word starting with
    /// one of these always decomposes into a standalone boundary token plus
    /// separate letter pieces (e.g. "zena" -> `▁ Z EN A`), instead of the usual
    /// boundary-fused first piece (e.g. "codex" -> `▁CO DE X`). That standalone
    /// boundary is a real, mechanical gap, not a guess.
    ///
    /// It is not a reliable *predictor* of failure on its own - "hey zorp"
    /// tokenizes the same way (`▁ Z OR P`) and still wakes reliably - so this
    /// is offered only as the explanation once `check(...)` has already
    /// returned `.cannotSpot`, never as a reason to refuse a phrase before
    /// trying it.
    public static let unspellableInitialLetters: Set<Character> = ["x", "z"]

    /// Whether any word in `phrase` starts with a letter this vocabulary
    /// cannot spell as an attached first piece.
    public static func startsWithUnspellableLetter(_ phrase: String) -> Bool {
        phrase.split(whereSeparator: { $0.isWhitespace }).contains { word in
            guard let letter = word.lowercased().first else { return false }
            return unspellableInitialLetters.contains(letter)
        }
    }
}
