import XCTest
@testable import HeyCodexKit

final class KeywordTokenizerTests: XCTestCase {
    /// Encoding needs the model's vocabulary, so correctness against official
    /// sentencepiece is checked in `swift run hey-codex-selftest tokenizer`
    /// (515 reference encodings plus the model authors' own keyword lines). What is
    /// testable without a model is the text cleanup that happens first.
    func test_normalizesToUppercaseWordsWithoutPunctuation() {
        XCTAssertEqual(KeywordTokenizer.normalize("Hey, Codex!"), "HEY CODEX")
        XCTAssertEqual(KeywordTokenizer.normalize("hey   codex"), "HEY CODEX")
        XCTAssertEqual(KeywordTokenizer.normalize("  "), "")
        XCTAssertEqual(KeywordTokenizer.normalize("!!!"), "")
    }

    func test_encodingAPhraseWithoutAModelDirectoryFails() {
        XCTAssertNil(KeywordTokenizer.tokenize("hey codex",
                                               modelDir: URL(fileURLWithPath: "/nonexistent")))
    }
}

final class WakeCalibrationTests: XCTestCase {
    private let tokens = "\u{2581}HE Y \u{2581}CO DE X"

    private func calibration(firingAtOrBelow limit: Float,
                             failingSamples: Set<Int> = []) -> WakeCalibration {
        WakeCalibration(fires: { line, threshold, audio in
            let index = Int(audio.first ?? 0)
            if failingSamples.contains(index) { return false }
            // Sanity: the line handed to the engine must carry the threshold.
            guard line.contains("#") else { return false }
            return threshold <= limit
        }, thresholds: [0.25, 0.20, 0.15, 0.10])
    }

    private func samples(_ count: Int) -> [[Float]] {
        (0..<count).map { [Float($0)] }
    }

    func test_keywordLineCarriesTheScore() {
        XCTAssertEqual(WakeCalibration.keywordLine(tokens: tokens, score: 1.5),
                       "\u{2581}HE Y \u{2581}CO DE X :1.50")
    }

    /// The calibrated score is 1.25, and one decimal place silently wrote it out as
    /// 1.2 - discarding the value the tuning measurement exists to establish.
    func test_keywordLineKeepsTwoDecimalsOfScore() {
        XCTAssertEqual(WakeCalibration.keywordLine(tokens: tokens, score: KeywordTuning.score),
                       "\u{2581}HE Y \u{2581}CO DE X :1.25")
    }

    /// The per-keyword threshold form exists for when more than one keyword is
    /// armed, where a global threshold cannot serve both.
    func test_keywordLineCanCarryAThresholdToo() {
        XCTAssertEqual(WakeCalibration.keywordLine(tokens: tokens, score: 1.5, threshold: 0.2),
                       "\u{2581}HE Y \u{2581}CO DE X :1.50 #0.20")
    }

    /// What gets persisted must not pin the threshold, or the sensitivity control
    /// silently stops working for an enrolled phrase.
    func test_persistedLineDoesNotPinTheThreshold() {
        let result = calibration(firingAtOrBelow: 0.15).calibrate(tokens: tokens, samples: samples(3))
        XCTAssertFalse(result.keywordLine.contains("#"),
                       "a persisted keyword line must leave the threshold to the setting")
        XCTAssertEqual(result.threshold, 0.15)
    }

    func test_picksTheStrictestThresholdThatWorks() {
        // Everything fires at 0.25, so a twitchier setting is never chosen.
        let result = calibration(firingAtOrBelow: 0.25).calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.threshold, 0.25)
        XCTAssertTrue(result.allFired)
        XCTAssertFalse(result.isMarginal)
    }

    func test_loosensOnlyAsFarAsNeeded() {
        let result = calibration(firingAtOrBelow: 0.15).calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.threshold, 0.15)
        XCTAssertTrue(result.allFired)
    }

    /// The failure that rejected a real enrollment: demanding all three takes
    /// throws away two good recordings because of one bad one.
    func test_twoGoodTakesOutOfThreeIsUsable() {
        let result = calibration(firingAtOrBelow: 0.25, failingSamples: [2])
            .calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.firedCount, 2)
        XCTAssertFalse(result.allFired)
        XCTAssertTrue(result.isUsable, "two of three takes should be enough to enrol")
    }

    func test_oneGoodTakeOutOfThreeIsNotEnough() {
        let result = calibration(firingAtOrBelow: 0.25, failingSamples: [1, 2])
            .calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.firedCount, 1)
        XCTAssertFalse(result.isUsable)
    }

    func test_reportsMarginalWhenItHadToGoToTheFloor() {
        let result = calibration(firingAtOrBelow: 0.10).calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.threshold, 0.10)
        XCTAssertTrue(result.isMarginal, "a floor threshold should warn about false triggers")
    }

    func test_nothingFiringIsNotUsable() {
        let result = calibration(firingAtOrBelow: 0.0).calibrate(tokens: tokens, samples: samples(3))
        XCTAssertEqual(result.firedCount, 0)
        XCTAssertFalse(result.isUsable)
    }

    func test_noSamplesFallsBackToTheDefaultThreshold() {
        let result = calibration(firingAtOrBelow: 0.25).calibrate(tokens: tokens, samples: [])
        XCTAssertEqual(result.threshold, KeywordTuning.threshold)
        XCTAssertFalse(result.isUsable)
    }
}

final class WakePhraseFitnessTests: XCTestCase {
    private let tokens = "\u{2581}HE Y \u{2581}CO DE X"
    private let spoken: [Float] = [1]
    private let ordinary: [[Float]] = [[2], [3]]

    /// The failure this check exists to prevent: "Hey Xena" tokenises fine and can
    /// be recorded three times, but the keyword never fires at any threshold, so
    /// enrollment could only ever reject it after the fact.
    func test_rejectsAPhraseTheModelCannotSpot() {
        let verdict = WakePhraseFitness.check(tokens: tokens, spoken: spoken,
                                              negatives: ordinary,
                                              fires: { _, _, _ in false })
        XCTAssertEqual(verdict, .cannotSpot)
    }

    func test_rejectsAPhraseThatFiresOnOrdinarySpeech() {
        let verdict = WakePhraseFitness.check(tokens: tokens, spoken: spoken,
                                              negatives: ordinary,
                                              fires: { _, _, _ in true })
        XCTAssertEqual(verdict, .tooCommon)
    }

    func test_acceptsAPhraseThatFiresOnItselfAndNothingElse() {
        let verdict = WakePhraseFitness.check(tokens: tokens, spoken: spoken,
                                              negatives: ordinary,
                                              fires: { _, _, audio in audio == [1] })
        XCTAssertEqual(verdict, .good)
    }

    /// A check that could not run must never block someone from recording.
    func test_treatsMissingSpeechSynthesisAsNoObjection() {
        let verdict = WakePhraseFitness.check(tokens: tokens, spoken: nil,
                                              negatives: ordinary,
                                              fires: { _, _, _ in false })
        XCTAssertEqual(verdict, .good)
    }

    /// "Too common" is judged at the strictest threshold. A phrase that only
    /// false-alarms once sensitivity is cranked down is still worth offering.
    func test_judgesFalseAlarmsAtTheStrictestThreshold() {
        let verdict = WakePhraseFitness.check(tokens: tokens, spoken: spoken,
                                              negatives: ordinary,
                                              thresholds: [0.25, 0.10],
                                              fires: { _, threshold, audio in
            audio == [1] || threshold < 0.25
        })
        XCTAssertEqual(verdict, .good)
    }
}
