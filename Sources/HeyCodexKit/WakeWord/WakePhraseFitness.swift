import Foundation

/// Whether this model can spot a phrase at all, decided before anyone records it.
///
/// Measured, not guessed. Two earlier guesses were both wrong: that the tokens the
/// model decodes from a recording make a better keyword than the phrase's own
/// spelling (they fire on nothing — a decode of "Hey Xena" as `▁A Z EN A` failed on
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
}
