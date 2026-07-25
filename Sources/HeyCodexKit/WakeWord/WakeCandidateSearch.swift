import Foundation

/// Chooses which spelling of a phrase to arm, by trying a small, ordered set of
/// candidate encodings against the user's own recordings — instead of handing
/// `WakeCalibration` exactly one spelling and giving up if it never fires.
///
/// Measured on three real recordings of "Hey Xena" (see AUDIT-2026-07-24.md):
/// the full phrase, canonically tokenized (`▁HE Y ▁ X EN A`), fires 0/3 at
/// every threshold from 0.25 down to 0.08. That is not a bad recording — the
/// model's 500-piece vocabulary has zero word-initial pieces beginning with X
/// or Z, so any word starting with one of those letters tokenizes with a
/// standalone boundary piece that represents no sound (see
/// `WakePhraseFitness`). "zena" alone, same voice, same takes, fires 3/3 at
/// the strictest threshold. The failure was in the spelling, not the voice.
///
/// So this searches candidate spellings in order of fidelity to what the user
/// typed and keeps the first one that both (a) actually fires on at least 2 of
/// 3 takes, via `WakeCalibration.Result.isUsable`, and (b) does not fire on
/// ordinary speech. It never blends candidates or arms more than one: arming
/// several at once was tried and it let a junk two-token line (`▁IN ▁A`, a bad
/// decode of one "Hey Xena" take) get armed, which would have woken on the
/// words "in a" in any sentence.
public enum WakeCandidateSearch {
    /// Leading filler words people naturally prefix a wake phrase with when
    /// they type it. Only the first word is ever treated as filler — "hey siri
    /// hey" loses one "hey", not both, and a filler that isn't in first
    /// position isn't filler, it's part of the phrase.
    static let fillers: Set<String> = ["hey", "ok", "okay", "yo", "hi"]

    /// One spelling under consideration.
    public struct Candidate: Sendable {
        /// The phrase text this candidate stands for, for the honesty message
        /// shown to the user (e.g. "Xena").
        public let phrase: String
        /// The tokenized keyword line contents (no score/threshold suffix).
        public let tokens: String
        /// Whether this is the literal, unmodified phrase the user typed. The
        /// only candidate that needs no disclosure.
        public let isFullPhrase: Bool
    }

    public struct Result: Sendable {
        public let candidate: Candidate
        public let calibration: WakeCalibration.Result
    }

    /// Candidate phrases, most-faithful-to-what-was-typed first:
    /// 1. The phrase exactly as typed.
    /// 2. The phrase with a leading filler word removed, if it starts with one.
    /// 3. The final word alone, if that differs from candidate 2.
    /// Pure text generation — no tokenizing, no model, no audio. Duplicates
    /// (case-insensitive) are dropped so the same spelling never gets tried,
    /// and therefore never gets disclosed, twice.
    public static func candidatePhrases(for phrase: String) -> [String] {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var out = [phrase]
        guard let first = words.first, words.count > 1, fillers.contains(first.lowercased())
        else { return out }
        let remainder = words.dropFirst().joined(separator: " ")
        if !out.contains(where: { $0.caseInsensitiveCompare(remainder) == .orderedSame }) {
            out.append(remainder)
        }
        if let last = words.last,
           !out.contains(where: { $0.caseInsensitiveCompare(last) == .orderedSame }) {
            out.append(last)
        }
        return out
    }

    /// Whether a candidate is short enough that the ordinary screen needs a
    /// tighter bar than usual.
    ///
    /// Rule: fewer than 4 tokenized pieces, or a single word. Both are cheap
    /// acoustic targets — a two-token line like `▁IN ▁A` (the junk decode that
    /// motivated this whole search, see the type doc) only needs two weak
    /// pieces to line up, and it did so on the words "in a" in ordinary
    /// speech. `WakePhraseFitness` screens the full phrase only at the
    /// strictest threshold, on the theory that a phrase built to be sayable
    /// on purpose won't accidentally get easier to trigger as sensitivity is
    /// loosened. A short fallback candidate has no such guarantee — it is by
    /// construction the leftover of a phrase, not something chosen for
    /// distinctiveness — and calibration may well settle on a loose threshold
    /// for it, so the screen has to hold at every threshold calibration might
    /// choose, not just the strictest.
    static func isShort(tokens: String, phrase: String) -> Bool {
        tokens.split(separator: " ").count < 4
            || phrase.split(whereSeparator: { $0.isWhitespace }).count == 1
    }

    /// True if this candidate must be rejected: it fires on ordinary speech.
    static func failsFalseAlarmScreen(tokens: String, phrase: String,
                                      negatives: [[Float]],
                                      calibration: WakeCalibration) -> Bool {
        let strictest = calibration.thresholds.first ?? KeywordTuning.threshold
        let thresholds = isShort(tokens: tokens, phrase: phrase)
            ? calibration.thresholds
            : [strictest]
        return thresholds.contains { threshold in
            let line = WakeCalibration.keywordLine(tokens: tokens, threshold: threshold)
            return negatives.contains { calibration.fires(line, threshold, $0) }
        }
    }

    /// Try each candidate in order and keep the first that is both safe and
    /// usable. `tokenize` is injected (rather than a model directory taken
    /// directly) so this is testable without the model, the same way
    /// `WakeCalibration.fires` is injected.
    public static func search(phrase: String,
                              samples: [[Float]],
                              negatives: [[Float]],
                              tokenize: (String) -> String?,
                              calibration: WakeCalibration) -> Result? {
        let phrases = candidatePhrases(for: phrase)
        for candidatePhrase in phrases {
            guard let tokens = tokenize(candidatePhrase) else { continue }
            guard !failsFalseAlarmScreen(tokens: tokens, phrase: candidatePhrase,
                                         negatives: negatives, calibration: calibration)
            else { continue }
            let result = calibration.calibrate(tokens: tokens, samples: samples)
            guard result.isUsable else { continue }
            let candidate = Candidate(phrase: candidatePhrase, tokens: tokens,
                                      isFullPhrase: candidatePhrase.caseInsensitiveCompare(phrase) == .orderedSame)
            return Result(candidate: candidate, calibration: result)
        }
        return nil
    }
}
