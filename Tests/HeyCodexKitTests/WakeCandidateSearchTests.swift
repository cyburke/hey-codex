import XCTest
@testable import HeyCodexKit

final class WakeCandidateSearchTests: XCTestCase {
    // MARK: - candidatePhrases: pure text generation, no model needed.

    func test_fullPhraseIsAlwaysFirst() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "hey xena").first, "hey xena")
    }

    func test_stripsALeadingFillerWord() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "hey xena"), ["hey xena", "xena"])
    }

    /// "hey siri": stripping "hey" leaves the single word "siri", which is also
    /// what the final-word candidate would be. It must appear once, not twice.
    func test_doesNotDuplicateWhenRemainderIsAlreadyTheFinalWord() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "hey siri"), ["hey siri", "siri"])
    }

    func test_addsTheFinalWordWhenItDiffersFromTheRemainder() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "ok computer boom"),
                       ["ok computer boom", "computer boom", "boom"])
    }

    /// Only a leading filler counts. A phrase that doesn't start with one of the
    /// recognized fillers gets no fallback candidates at all.
    func test_noFillerMeansNoFallbackCandidates() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "wake up codex"), ["wake up codex"])
    }

    func test_singleWordPhraseHasOnlyItself() {
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "xena"), ["xena"])
    }

    func test_fillerIsOnlyRecognizedInFirstPosition() {
        // "hey" is a filler word, but only in first position. "codex hey" does
        // not start with one, so nothing is stripped and there is no fallback.
        XCTAssertEqual(WakeCandidateSearch.candidatePhrases(for: "codex hey"), ["codex hey"])
    }

    // MARK: - search: candidate selection with injected tokenize + fires.

    private func samples(_ count: Int) -> [[Float]] { (0..<count).map { [Float($0)] } }

    /// A calibration whose `fires` closure looks at which fake token marker a
    /// line contains, so different candidates can be made to behave
    /// differently without a real model.
    private func calibration(fires: @escaping @Sendable (String, Float, [Float]) -> Bool) -> WakeCalibration {
        WakeCalibration(fires: fires, thresholds: [0.25, 0.20, 0.15, 0.10])
    }

    func test_fullPhrasePreferredWhenItWorks() {
        let calibration = calibration(fires: { line, _, _ in line.contains("FULL") })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [],
            tokenize: { $0 == "hey xena" ? "FULL" : "TAIL" },
            calibration: calibration)
        XCTAssertEqual(result?.candidate.phrase, "hey xena")
        XCTAssertTrue(result?.candidate.isFullPhrase ?? false)
    }

    /// The measured "Hey Xena" case: the full phrase never fires, but the
    /// filler-stripped remainder does.
    func test_fillerStrippedCandidateChosenWhenFullPhraseDoesNotFire() {
        let calibration = calibration(fires: { line, _, _ in line.contains("TAIL") })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [],
            tokenize: { $0 == "hey xena" ? "FULL" : "TAIL" },
            calibration: calibration)
        XCTAssertEqual(result?.candidate.phrase, "xena")
        XCTAssertFalse(result?.candidate.isFullPhrase ?? true)
        XCTAssertTrue(result?.calibration.isUsable ?? false)
    }

    /// A candidate that matches every take perfectly but also fires on ordinary
    /// speech must still be rejected - the false-alarm screen outranks fit to
    /// the recordings.
    func test_rejectsACandidateThatFalseAlarmsEvenIfItMatchesTheTakesPerfectly() {
        let calibration = calibration(fires: { line, _, audio in
            if line.contains("FULL") { return true }          // fires on every take AND the negative
            if line.contains("TAIL") { return audio != [9] }  // fires on every take, not the negative
            return false
        })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [[9]],
            tokenize: { $0 == "hey xena" ? "FULL" : "TAIL" },
            calibration: calibration)
        // FULL matches all three takes but also fires on ordinary speech, so it
        // must be skipped in favor of TAIL even though FULL is the more
        // faithful spelling and fires perfectly on the recordings.
        XCTAssertEqual(result?.candidate.phrase, "xena")
    }

    /// Short candidates (here, fewer than 4 tokenized pieces) must clear the
    /// false-alarm screen at every calibration threshold, not just the
    /// strictest. A candidate that only misbehaves once sensitivity loosens is
    /// exactly the failure this guards: `WakeCalibration.calibrate` is free to
    /// land on a loose threshold, and a short candidate is the kind of thing
    /// that becomes a false trigger once it does.
    func test_shortCandidateMustClearTheScreenAtEveryThreshold() {
        // "▁IN ▁A" - 2 pieces, definitely "short". Fires on the negative only
        // once the threshold loosens past the strictest (0.25).
        let calibration = calibration(fires: { line, threshold, audio in
            guard line.contains("SHORT") else { return false }
            if audio == [9] { return threshold < 0.25 }   // negative: fires once loosened
            return true                                    // samples: always fire
        })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [[9]],
            tokenize: { $0 == "hey xena" ? nil : "\u{2581}IN \u{2581}A" /* SHORT-ish, 2 pieces */ },
            calibration: calibration)
        // "hey xena" is unspellable here (tokenize returns nil), so the only
        // real candidate is the 2-piece fallback, which must be rejected.
        XCTAssertNil(result, "a short candidate that false-alarms once loosened must never be armed")
    }

    /// The same shaped fallback candidate, but one that stays silent on the
    /// negative at every threshold, must still be accepted - the stricter bar
    /// only rejects candidates that actually misbehave.
    func test_shortCandidateIsAcceptedWhenItNeverFalseAlarms() {
        let calibration = calibration(fires: { line, _, audio in
            guard line.contains("IN") else { return false }
            return audio != [9]
        })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [[9]],
            tokenize: { $0 == "hey xena" ? nil : "\u{2581}IN \u{2581}A" },
            calibration: calibration)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.calibration.isUsable ?? false)
    }

    func test_isShortRecognizesFewerThanFourPiecesOrASingleWord() {
        XCTAssertTrue(WakeCandidateSearch.isShort(tokens: "\u{2581}IN \u{2581}A", phrase: "in a"))
        XCTAssertTrue(WakeCandidateSearch.isShort(tokens: "\u{2581} Z EN A", phrase: "zena"))
        XCTAssertFalse(WakeCandidateSearch.isShort(tokens: "\u{2581}HE Y \u{2581}CO DE X", phrase: "hey codex"))
    }

    func test_noUsableCandidateReturnsNil() {
        let calibration = calibration(fires: { _, _, _ in false })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [],
            tokenize: { _ in "TOKENS" },
            calibration: calibration)
        XCTAssertNil(result)
    }

    func test_unspellableCandidatesAreSkipped() {
        // Neither candidate tokenizes; search must not crash and must return nil.
        let calibration = calibration(fires: { _, _, _ in true })
        let result = WakeCandidateSearch.search(
            phrase: "hey xena", samples: samples(3), negatives: [],
            tokenize: { _ in nil },
            calibration: calibration)
        XCTAssertNil(result)
    }
}

final class WakePhraseFitnessUnspellableLetterTests: XCTestCase {
    func test_flagsAWordStartingWithXOrZ() {
        XCTAssertTrue(WakePhraseFitness.startsWithUnspellableLetter("hey xena"))
        XCTAssertTrue(WakePhraseFitness.startsWithUnspellableLetter("zena"))
        XCTAssertTrue(WakePhraseFitness.startsWithUnspellableLetter("wake up Xavier"))
    }

    func test_doesNotFlagOrdinaryPhrases() {
        XCTAssertFalse(WakePhraseFitness.startsWithUnspellableLetter("hey codex"))
        XCTAssertFalse(WakePhraseFitness.startsWithUnspellableLetter("hey jarvis"))
    }
}
