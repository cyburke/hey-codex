import CoreAudio
import Foundation
import HeyCodexKit

// On-machine verification harness.
//
// This CLT-only Swift toolchain has no XCTest runner, so the canonical XCTest
// suites in Tests/HeyCodexKitTests/ cannot execute here (they remain for CI /
// Xcode). This executable mirrors those assertions so each task can be proven
// on this machine with `swift run hey-codex-selftest <check>`.

// MARK: - Tiny assertion harness

final class Check {
    let name: String
    var failures: [String] = []
    init(_ name: String) { self.name = name }

    func fail(_ message: String) { failures.append(message) }
    func assert(_ cond: Bool, _ message: @autoclosure () -> String) {
        if !cond { failures.append(message()) }
    }
    func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "") {
        if a != b { failures.append("expected \(b), got \(a). \(message())") }
    }
}

func run(_ name: String, _ body: (Check) throws -> Void) -> Bool {
    let c = Check(name)
    do {
        try body(c)
    } catch {
        c.fail("threw: \(error)")
    }
    if c.failures.isEmpty {
        print("PASS  \(name)")
        return true
    } else {
        print("FAIL  \(name)")
        for f in c.failures { print("      - \(f)") }
        return false
    }
}

// MARK: - Path helpers

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // hey-codex-selftest
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // repo root
let modelsDir = repoRoot.appendingPathComponent("Models")
let fixturesDir = repoRoot
    .appendingPathComponent("Tests/HeyCodexKitTests/Fixtures")

func fixture(_ name: String) -> URL {
    fixturesDir.appendingPathComponent("\(name).wav")
}

let kwsDir = modelsDir
    .appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
let asrDir = modelsDir
    .appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8")
let keywordsFile = modelsDir.appendingPathComponent("keywords.txt")

// MARK: - Checks

func checkSherpaLinks() -> Bool {
    run("sherpaLinks") { c in
        c.assert(HeyCodexKit.sherpaLinks(), "sherpa-onnx C symbols did not link")
    }
}

func checkActivationLatch() -> Bool {
    run("voice.activationLatch") { c in
        let latch = VoiceActivationLatch()
        c.assert(latch.consumeIfArmed(), "first wake should consume the latch")
        c.assert(!latch.consumeIfArmed(), "repeated wake must be ignored")
        latch.rearm()
        c.assert(latch.consumeIfArmed(), "explicit re-arm should allow one new wake")
    }
}

func checkVoiceShortcut() -> Bool {
    run("voice.shortcutDefault") { c in
        let shortcut = VoiceShortcut.default
        c.assertEqual(shortcut.displayString, "⌃⌥V")
        c.assertEqual(shortcut.virtualKeyCode, 9)
        c.assert(shortcut.control && shortcut.option && !shortcut.command,
                 "release default must be Control-Option-V, never Command-V")
    }
}

/// Live probe: proves the Core Graphics window bridge actually decodes, which
/// unit tests of the pure rule cannot show. A silent cast failure here would
/// look exactly like "Voice never opens", so it is worth checking directly.
/// Not part of `all` - it reads live window-server state and needs a GUI session.
func probeVoicePanel() -> Bool {
    run("voice.panelObserverLive") { c in
        let windows = VoicePanelObserver.currentWindows()
        print("  [diag] window bridge decoded \(windows.count) window(s)")
        c.assert(!windows.isEmpty,
                 "window list came back empty - the CGWindow bridge or a GUI session is missing")
        let pid = VoicePanelObserver.chatGPTProcessIdentifier()
        print("  [diag] ChatGPT pid: \(pid.map(String.init) ?? "not running")")
        if let pid {
            let owned = windows.filter { $0.ownerProcessIdentifier == pid }
            let floating = owned.filter { $0.layer > 0 }
            print("  [diag] ChatGPT windows: \(owned.count), floating: \(floating.count), " +
                  "floating on screen: \(floating.filter(\.isOnscreen).count)")
            c.assert(!owned.isEmpty, "ChatGPT is running but owns no decodable windows")
        }
        print("  [diag] Voice panel visible: \(VoicePanelObserver().isPanelVisible())")
    }
}

/// Verify a *built bundle's* Models directory is complete enough to start the
/// wake engine. bundle-app.sh copies an explicit file list rather than the whole
/// model directory, so this is the regression guard for that list: a file
/// dropped from it fails here instead of silently at a user's first launch.
/// Run: `swift run hey-codex-selftest bundle-models dist/HeyCodex.app`
func probeBundleModels(_ appPath: String) -> Bool {
    let models = URL(fileURLWithPath: appPath)
        .appendingPathComponent("Contents/Resources/Models")
    return run("bundle.modelsAreComplete") { c in
        let kws = models.appendingPathComponent(
            "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        let keywords = models.appendingPathComponent("keywords.txt")
        c.assert(FileManager.default.fileExists(atPath: keywords.path),
                 "bundled keywords.txt is missing")
        // Constructing the engine is the real check: it opens every model file
        // it needs and throws .missingModelFile naming any that is absent.
        let engine = try WakeWordEngine(modelDir: kws, keywordsFile: keywords,
                                        keywordsThreshold: wakeThreshold)
        let control = try AudioSamples.load(kwsDir.appendingPathComponent("test_wavs/0.wav"))
        c.assert(!engine.detects(in: control),
                 "bundled engine fired on unrelated speech")
        // Custom wake phrases are encoded at runtime from the bundled vocabulary.
        // Without it, enrollment cannot build a keyword for anything the user types.
        c.assertEqual(KeywordTokenizer.tokenize("hey codex", modelDir: kws) ?? "nil",
                      "\u{2581}HE Y \u{2581}CO DE X",
                      "the bundled app cannot encode a wake phrase")
        let size = (try? FileManager.default.subpathsOfDirectory(atPath: models.path)
            .compactMap { try? FileManager.default.attributesOfItem(
                atPath: models.appendingPathComponent($0).path)[.size] as? Int }
            .reduce(0, +)) ?? 0
        print("  [diag] bundled Models total: \(size / 1_048_576) MB")
    }
}

// MARK: - Audio device footprint

/// Proves AudioCapture touches the microphone and nothing else.
///
/// AVAudioEngine, which this used to be built on, makes CoreAudio fabricate a
/// private aggregate device spanning the default input AND output, so listening
/// for a wake word quietly pulled the user's speakers into a synthetic device.
/// This check fails if any new device appears while capturing, or if a device
/// with output channels starts running.
/// Run: `swift run hey-codex-selftest audio-footprint`
func probeAudioFootprint() -> Bool {
    func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
    }
    func deviceName(_ id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "?" }
        return value as String
    }
    func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }
    func isRunning(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    return run("audio.footprintIsInputOnly") { c in
        let before = Set(deviceIDs())
        print("  [diag] devices before: \(before.count)")

        let frames = Counter()
        let capture = try AudioCapture { samples in
            if !samples.isEmpty { frames.bump() }
        }
        try capture.start()
        Thread.sleep(forTimeInterval: 2.0)

        let after = deviceIDs()
        let added = after.filter { !before.contains($0) }
        let runningWithOutput = after.filter { channelCount($0, kAudioDevicePropertyScopeOutput) > 0 && isRunning($0) }

        print("  [diag] devices during: \(after.count)")
        print("  [diag] frames delivered: \(frames.value)")
        for id in added { print("  [diag] NEW DEVICE: \(deviceName(id))") }
        for id in runningWithOutput { print("  [diag] running output device: \(deviceName(id))") }

        c.assert(frames.value > 0, "no audio frames arrived; capture is not actually live")
        c.assert(added.isEmpty,
                 "capture created \(added.count) device(s): \(added.map(deviceName).joined(separator: ", ")). " +
                 "An aggregate spanning the output device is the AVAudioEngine regression.")
        capture.stop()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Does the app's keyword encoding match official sentencepiece, exactly?
///
/// A keyword that differs from the model's own encoding by a single token never
/// fires, and nothing about it looks wrong. Checked two ways: against a few hundred
/// encodings generated by Google sentencepiece, and against the keyword lines the
/// model's authors shipped beside their plain-text originals.
/// Run: `swift run hey-codex-selftest tokenizer`
func probeTokenizer() -> Bool {
    run("keyword.tokenizerMatchesSentencepiece") { c in
        // Ground truth from official Google sentencepiece over this model's
        // bpe.model. The app encodes with ssentencepiece inside the sherpa-onnx
        // library; the two must agree exactly, because a keyword that differs by
        // one token simply never fires.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/bpe-encodings.tsv")
        guard let text = try? String(contentsOf: fixture, encoding: .utf8) else {
            c.fail("missing \(fixture.path)"); return
        }
        var checked = 0, mismatches: [String] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let phrase = String(parts[0]), expected = String(parts[1])
            checked += 1
            let ours = KeywordTokenizer.tokenize(phrase, modelDir: kwsDir)
            if ours != expected, mismatches.count < 6 {
                mismatches.append("  \(phrase)\n    sentencepiece: \(expected)\n    ours:          \(ours ?? "nil")")
            }
        }
        for m in mismatches { print(m) }
        c.assert(checked > 400, "fixture should cover a few hundred phrases, saw \(checked)")
        c.assertEqual(mismatches.count, 0, "encodings disagree with sentencepiece")
        print("  matched \(checked - mismatches.count)/\(checked) reference encodings")

        // The model authors shipped their own keywords with the raw text beside
        // them, which is an independent check on the same claim.
        let raw = kwsDir.appendingPathComponent("keywords_raw.txt")
        let shipped = kwsDir.appendingPathComponent("keywords.txt")
        if let rawText = try? String(contentsOf: raw, encoding: .utf8),
           let shippedText = try? String(contentsOf: shipped, encoding: .utf8) {
            let phrases = rawText.split(whereSeparator: \.isNewline)
            let lines = shippedText.split(whereSeparator: \.isNewline)
            for (phrase, line) in zip(phrases, lines) {
                let expected = line.split(separator: " :").first.map(String.init) ?? String(line)
                c.assertEqual(KeywordTokenizer.tokenize(String(phrase), modelDir: kwsDir) ?? "nil",
                              expected.trimmingCharacters(in: .whitespaces),
                              "the model authors' own keyword for \(phrase)")
            }
            print("  reproduced \(min(phrases.count, lines.count)) of the model's shipped keyword lines")
        }
    }
}

/// Replays saved enrollment takes through the whole pipeline. Enrollment audio is
/// only ever kept when someone opts in (see EnrollmentDiagnostics.keepsAudio), so
/// this skips silently when there is nothing to replay. It exists so a rejected
/// enrollment can be fixed without asking that person to record it again.
func probeReplayEnrollment(_ phrase: String) -> Bool {
    run("keyword.replayEnrollment") { c in
        let dir = EnrollmentDiagnostics.audioDirectory
        let takes = (1...3).map { dir.appendingPathComponent("take-\($0).wav") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !takes.isEmpty else {
            print("  [skip] no saved takes at \(dir.path)")
            return
        }
        // Saved takes were captured before EnrollmentRecorder normalized gain (or
        // may simply be a quiet mic), so replay them the same way the live path
        // now does: through AudioSamples.normalized at EnrollmentRecorder's
        // target, not raw off disk. Without this, a real quiet recording of a
        // perfectly good phrase reproduces the P1.1 bug this probe exists to
        // catch, rather than testing the fix for it.
        let clips = takes.compactMap { try? AudioSamples.load($0) }
            .map { AudioSamples.normalized($0, targetRMS: EnrollmentRecorder.targetRMS,
                                           peakCeiling: EnrollmentRecorder.peakCeiling) }
        c.assertEqual(clips.count, takes.count, "every saved take should load")
        let calibration = WakeCalibration(fires: { line, threshold, audio in
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("rp-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard let e = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                             keywordsThreshold: threshold) else { return false }
            return e.detects(in: audio)
        })
        let tokenize: (String) -> String? = { KeywordTokenizer.tokenize($0, modelDir: kwsDir) }
        let negatives = SynthesizedSpeech.falseAlarmClips()

        print("  phrase=\(phrase)")
        print("  candidates tried, in order: " +
              WakeCandidateSearch.candidatePhrases(for: phrase).joined(separator: " -> "))
        if let fullTokens = tokenize(phrase) {
            let verdict = WakePhraseFitness.check(tokens: fullTokens,
                                                 spoken: SynthesizedSpeech.samples(of: phrase),
                                                 negatives: negatives, fires: calibration.fires)
            print("  full-phrase keyword=[\(fullTokens)]  fitness=\(verdict)")
        } else {
            print("  full-phrase keyword=<this model cannot spell it>")
        }

        // The whole feature this probe exists to prove: does SOME spelling of
        // the phrase, not necessarily the literal one, end up usable on these
        // real takes? See WakeCandidateSearch.
        guard let search = WakeCandidateSearch.search(phrase: phrase, samples: clips,
                                                       negatives: negatives, tokenize: tokenize,
                                                       calibration: calibration) else {
            c.fail("no spelling of \"\(phrase)\" - literal or fallback - is usable on these takes")
            return
        }
        let result = search.calibration
        print("  WINNING CANDIDATE: \"\(search.candidate.phrase)\"" +
              (search.candidate.isFullPhrase ? " (the full phrase)" : " (fallback - not the literal phrase)"))
        print("  keyword=[\(search.candidate.tokens)]")
        let sweep = KeywordTuning.calibrationThresholds
        let row = sweep.map { threshold in
            clips.filter {
                calibration.fires(WakeCalibration.keywordLine(tokens: search.candidate.tokens, threshold: threshold),
                                  threshold, $0)
            }.count
        }
        print("  takes fired: " + zip(sweep, row).map { String(format: "%.2f:%d", $0, $1) }
                                                .joined(separator: " "))
        print(String(format: "  threshold=%.2f fired=%d/%d usable=%@",
                     result.threshold, result.firedCount, result.sampleCount,
                     result.isUsable ? "yes" : "NO"))
        c.assert(result.isUsable, "the winning candidate must actually be usable on these takes")

        // P1.1: does capture-time gain normalization actually rescue a phrase
        // silenced by level alone, without also rescuing ordinary speech into a
        // false trigger? "hey codex" is the proven-spottable phrase (see
        // wake.detectsWakePhraseInPositiveClip); scale a synthesized take of it
        // down to a real quiet-mic level and confirm EnrollmentRecorder's
        // normalization (AudioSamples.normalized, targeting the same RMS/peak
        // EnrollmentRecorder uses) brings it back to firing. A synthesized
        // ordinary sentence, scaled and normalized exactly the same way, must
        // still stay silent - normalization must not manufacture false triggers
        // out of quiet background speech.
        func scaled(_ samples: [Float], toRMS target: Float) -> [Float] {
            let level = AudioSamples.rms(samples)
            guard level > 0 else { return samples }
            let gain = target / level
            return samples.map { $0 * gain }
        }
        if let knownGood = SynthesizedSpeech.samples(of: "hey codex"),
           let knownTokens = KeywordTokenizer.tokenize("hey codex", modelDir: kwsDir),
           let negative = SynthesizedSpeech.samples(of: SynthesizedSpeech.falseAlarmPhrases[0]) {
            let quietGood = scaled(knownGood, toRMS: EnrollmentRecorder.lowLevelRMS)
            let quietNegative = scaled(negative, toRMS: EnrollmentRecorder.lowLevelRMS)
            print(String(format: "  gain: quiet-good rms=%.4f  quiet-negative rms=%.4f  (both scaled to lowLevelRMS=%.3f)",
                         AudioSamples.rms(quietGood), AudioSamples.rms(quietNegative), EnrollmentRecorder.lowLevelRMS))
            let normalizedGood = AudioSamples.normalized(quietGood, targetRMS: EnrollmentRecorder.targetRMS,
                                                         peakCeiling: EnrollmentRecorder.peakCeiling)
            let normalizedNegative = AudioSamples.normalized(quietNegative, targetRMS: EnrollmentRecorder.targetRMS,
                                                             peakCeiling: EnrollmentRecorder.peakCeiling)
            print(String(format: "  gain: after normalize   good rms=%.4f peak=%.3f  negative rms=%.4f peak=%.3f",
                         AudioSamples.rms(normalizedGood), AudioSamples.peak(normalizedGood),
                         AudioSamples.rms(normalizedNegative), AudioSamples.peak(normalizedNegative)))
            let strictest = KeywordTuning.calibrationThresholds.first ?? KeywordTuning.threshold
            let goodFires = KeywordTuning.calibrationThresholds.contains { t in
                calibration.fires(WakeCalibration.keywordLine(tokens: knownTokens, threshold: t), t, normalizedGood)
            }
            let negativeFires = calibration.fires(
                WakeCalibration.keywordLine(tokens: knownTokens, threshold: strictest), strictest, normalizedNegative)
            print("  gain: known-good fires after normalize? \(goodFires ? "yes" : "NO")"
                  + "   negative fires after normalize? \(negativeFires ? "YES (bad)" : "no")")
            c.assert(goodFires, "normalization should rescue \"hey codex\" scaled down to RMS \(EnrollmentRecorder.lowLevelRMS)")
            c.assert(!negativeFires, "normalization must not turn quiet ordinary speech into a false trigger")
        } else {
            print("  [skip] gain-normalization check: speech synthesis unavailable")
        }
    }
}


/// Do the two detection paths agree?
///
/// The live mic loop calls `WakeWordEngine.feed`, which streams frames into a
/// stream that stays alive across calls. Enrollment validation calls
/// `detects(in:)`, which pads a second of silence and calls `inputFinished`. If a
/// clip fires on one and not the other, enrollment is grading a phrase by a
/// measurement the running app never makes, and every "0 of 3" it reports is
/// suspect.
/// Run: `swift run hey-codex-selftest path-parity <phrase>`
func probePathParity(_ phrase: String) -> Bool {
    run("keyword.pathParity") { c in
        guard let tokens = KeywordTokenizer.tokenize(phrase, modelDir: kwsDir) else {
            c.fail("cannot tokenise \(phrase)"); return
        }
        let dir = EnrollmentDiagnostics.audioDirectory
        let takes = (1...3).map { dir.appendingPathComponent("take-\($0).wav") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !takes.isEmpty else { print("  [skip] no saved takes"); return }
        let clips = takes.compactMap { try? AudioSamples.load($0) }

        func engine(_ threshold: Float) -> WakeWordEngine? {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("pp-\(UUID().uuidString).txt")
            try? (WakeCalibration.keywordLine(tokens: tokens) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            return try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                      keywordsThreshold: threshold)
        }
        // The mic delivers ~100ms frames; stream the clip the same way, and keep
        // feeding silence afterwards the way a live mic never stops.
        func firesStreaming(_ clip: [Float], threshold: Float) -> Bool {
            guard let e = engine(threshold) else { return false }
            let frame = 1600
            var i = 0
            while i < clip.count {
                let chunk = Array(clip[i..<min(i + frame, clip.count)])
                if e.feed(chunk) { return true }
                i += frame
            }
            for _ in 0..<10 where e.feed([Float](repeating: 0, count: frame)) { return true }
            return false
        }
        func firesOneShot(_ clip: [Float], threshold: Float) -> Bool {
            guard let e = engine(threshold) else { return false }
            return e.detects(in: clip)
        }

        print("  phrase=\(phrase)  keyword=[\(tokens)]")
        print("  thresh | detects(in:)  feed() streaming")
        var disagreements = 0
        for threshold in KeywordTuning.calibrationThresholds {
            let oneShot = clips.filter { firesOneShot($0, threshold: threshold) }.count
            let streamed = clips.filter { firesStreaming($0, threshold: threshold) }.count
            if oneShot != streamed { disagreements += 1 }
            print(String(format: "  %.2f   |     %d/%d            %d/%d%@",
                         threshold, oneShot, clips.count, streamed, clips.count,
                         oneShot == streamed ? "" : "   <-- DISAGREE"))
        }
        c.assertEqual(disagreements, 0,
                      "the enrollment check and the live listener disagree on this phrase")
    }
}

/// Where does enrollment's wall-clock time actually go?
///
/// Reported symptoms: "checking that phrase" takes 2-3s before recording starts,
/// and "tuning your voice" freezes for 6s or more with no feedback. This measures
/// the parts rather than guessing which one is expensive.
/// Run: `swift run hey-codex-selftest timing`
func probeTiming() -> Bool {
    run("enroll.timingBreakdown") { c in
        func ms(_ block: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }

        // --- (a)/(b) Pre-record check, measured FIRST and before anything
        // else in this function touches `falseAlarmClips()` - once anything
        // does, the disk cache exists for the rest of the run and a later
        // "cold" measurement would be lying. Whichever state this process
        // finds on disk on entry decides cold vs. warm, so two separate
        // invocations of `swift run hey-codex-selftest timing` give one real
        // cold number and one real warm number; `timing-cold` forces a clean
        // cold run on demand by deleting the cache first.
        let wasCold = !SynthesizedSpeech.negativesCached
        let cache = WakeEngineCache(modelDir: kwsDir)
        let checkTime = ms {
            _ = WakePhraseFitness.check(
                tokens: "\u{2581}HE Y \u{2581}JA R VI S",
                spoken: SynthesizedSpeech.samples(of: "hey jarvis"),
                negatives: SynthesizedSpeech.falseAlarmClips(),
                thresholds: KeywordTuning.fitnessCheckThresholds,
                fires: { line, threshold, audio in cache.fires(line, threshold: threshold, audio: audio) })
        }
        print(String(format: "  PRE-RECORD CHECK (%@ cache, cached negatives now on disk for next run): %.0f ms",
                     wasCold ? "COLD" : "WARM", checkTime))

        // (b) A second call in the same process: RAM-memoized negatives, so
        // this isolates what the disk cache alone is worth vs. the in-memory
        // memoization on top of it.
        let checkTimeMemoized = ms {
            _ = WakePhraseFitness.check(
                tokens: "\u{2581}HE Y \u{2581}JA R VI S",
                spoken: SynthesizedSpeech.samples(of: "hey jarvis"),
                negatives: SynthesizedSpeech.falseAlarmClips(),
                thresholds: KeywordTuning.fitnessCheckThresholds,
                fires: { line, threshold, audio in cache.fires(line, threshold: threshold, audio: audio) })
        }
        print(String(format: "  PRE-RECORD CHECK (same process, RAM-memoized negatives): %.0f ms",
                     checkTimeMemoized))

        // --- Component micro-benchmarks, for context on where the above
        // numbers go (cache is warm for these by construction now, since the
        // block above already populated it - that is fine, they are not
        // trying to measure cold vs. warm, just the pieces).
        let kwFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-\(UUID().uuidString).txt")
        try? ("\u{2581}HE Y \u{2581}CO DE X :1.2\n").write(to: kwFile, atomically: true, encoding: .utf8)

        var engine: WakeWordEngine?
        let build = ms { engine = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: kwFile,
                                                     keywordsThreshold: 0.25) }
        print(String(format: "  engine construction (loads 3 onnx models): %.0f ms", build))

        guard let engine else { c.fail("engine failed"); return }
        let clip = (try? AudioSamples.load(kwsDir.appendingPathComponent("test_wavs/0.wav"))) ?? []
        let detect = ms { _ = engine.detects(in: clip) }
        print(String(format: "  detects() on one clip, engine already built: %.0f ms", detect))

        var one: [Float]?
        let synth1 = ms { one = SynthesizedSpeech.samples(of: "hey jarvis") }
        print(String(format: "  synthesize ONE phrase via say+afconvert: %.0f ms  (%d samples)",
                     synth1, one?.count ?? 0))

        // (c) The full post-recording tune: WakeCandidateSearch.search across
        // three synthesized "takes" of "hey codex", engine-cache reused, vs.
        // the old fresh-engine-per-call baseline, so the collapse from 18
        // constructions to 6 is visible as a number, not just asserted.
        let takes = ["hey codex", "hey codex", "hey codex"].compactMap(SynthesizedSpeech.samples(of:))
        c.assertEqual(takes.count, 3, "all three synthesized takes for the tune timing must exist")
        let tuneCache = WakeEngineCache(modelDir: kwsDir)
        let tuneCalibration = WakeCalibration(fires: { line, threshold, audio in
            tuneCache.fires(line, threshold: threshold, audio: audio)
        })
        let tuneTokenize: (String) -> String? = { KeywordTokenizer.tokenize($0, modelDir: kwsDir) }
        let tuneNegatives = SynthesizedSpeech.falseAlarmClips()
        let tuneTime = ms {
            _ = WakeCandidateSearch.search(phrase: "hey codex", samples: takes,
                                           negatives: tuneNegatives, tokenize: tuneTokenize,
                                           calibration: tuneCalibration)
        }
        print(String(format: "  FULL POST-RECORDING TUNE (engine cache reused, negatives already cached): %.0f ms",
                     tuneTime))

        final class Counter: @unchecked Sendable { var value = 0 }
        let freshConstructions = Counter()
        let freshFires: @Sendable (String, Float, [Float]) -> Bool = { line, threshold, audio in
            freshConstructions.value += 1
            let f = FileManager.default.temporaryDirectory
                .appendingPathComponent("tm3-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: f) }
            try? (line + "\n").write(to: f, atomically: true, encoding: .utf8)
            guard let e = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: f,
                                             keywordsThreshold: threshold) else { return false }
            return e.detects(in: audio)
        }
        let freshCalibration = WakeCalibration(fires: freshFires)
        let tuneTimeBaseline = ms {
            _ = WakeCandidateSearch.search(phrase: "hey codex", samples: takes,
                                           negatives: tuneNegatives, tokenize: tuneTokenize,
                                           calibration: freshCalibration)
        }
        print(String(format: "  FULL POST-RECORDING TUNE (old baseline: fresh engine per clip, %d constructions): %.0f ms",
                     freshConstructions.value, tuneTimeBaseline))

        // --- Engine reuse safety ---
        //
        // BLOCKING per review: the doc comment on `detects(in:)` claiming
        // `reset()` makes the engine safely reusable had never actually been
        // exercised - every call site in the whole tree built one engine per
        // `detects()` call, so reuse across multiple clips was unverified
        // behaviour of the vendored C library (SherpaOnnxResetKeywordStream),
        // not of our Swift wrapper. This does not trust the comment: it runs
        // the same (line, threshold) over 7 real/synthesized clips two ways -
        // fresh engine per clip (ground truth, order cannot matter) vs one
        // engine reused across the whole clip set - and requires bit-for-bit
        // identical fired/not-fired results. It also runs the reused-engine
        // pass a SECOND time in reverse clip order, on a fresh cache instance,
        // specifically to catch a leak that only shows up depending on what
        // came before a given clip (a leak that happened to be symmetric in
        // forward order could hide otherwise).
        let reuseClips: [[Float]] = [
            (try? AudioSamples.load(kwsDir.appendingPathComponent("test_wavs/0.wav"))),
            (try? AudioSamples.load(kwsDir.appendingPathComponent("test_wavs/1.wav"))),
            SynthesizedSpeech.samples(of: "hey codex"),
            SynthesizedSpeech.samples(of: "hey jarvis"),
            SynthesizedSpeech.samples(of: "the weather today is sunny and warm"),
            SynthesizedSpeech.samples(of: "hey there, how are you doing"),
            SynthesizedSpeech.samples(of: "let me check the code for you and get back"),
        ].compactMap { $0 }
        c.assert(reuseClips.count == 7, "expected 7 real/synthesized clips for the reuse check, got \(reuseClips.count)")
        guard let reuseTokens = KeywordTokenizer.tokenize("hey codex", modelDir: kwsDir) else {
            c.fail("could not tokenize 'hey codex' for the reuse check")
            return
        }

        // Ground truth: fresh engine per call. Order cannot affect this, since
        // nothing is shared between calls.
        var baseline: [String: Bool] = [:]
        for threshold in KeywordTuning.calibrationThresholds {
            let line = WakeCalibration.keywordLine(tokens: reuseTokens, threshold: threshold)
            for (index, clip) in reuseClips.enumerated() {
                baseline["\(threshold)|\(index)"] = freshFires(line, threshold, clip)
            }
        }

        func reusedPass(order: [Int]) -> Int {
            let cache = WakeEngineCache(modelDir: kwsDir)
            var mismatches = 0
            for threshold in KeywordTuning.calibrationThresholds {
                let line = WakeCalibration.keywordLine(tokens: reuseTokens, threshold: threshold)
                for index in order {
                    let reused = cache.fires(line, threshold: threshold, audio: reuseClips[index])
                    if reused != baseline["\(threshold)|\(index)"] { mismatches += 1 }
                }
            }
            return mismatches
        }

        let forwardOrder = Array(reuseClips.indices)
        let reverseOrder = Array(reuseClips.indices.reversed())
        let forwardMismatches = reusedPass(order: forwardOrder)
        let reverseMismatches = reusedPass(order: reverseOrder)
        c.assert(forwardMismatches == 0,
                "engine reuse (forward order) must match fresh-engine-per-call - got \(forwardMismatches) mismatches")
        c.assert(reverseMismatches == 0,
                "engine reuse (reverse order) must match fresh-engine-per-call - got \(reverseMismatches) mismatches; an order-dependent leak would show up here even if forward order looked clean")
        print("  ENGINE REUSE SAFETY: \(reuseClips.count) clips x \(KeywordTuning.calibrationThresholds.count) thresholds, forward=\(forwardMismatches) reverse=\(reverseMismatches) mismatches vs. fresh-engine-per-call")

        // --- The duplicate falseAlarmClips() call (review point 3):
        // checkFitness and finishEnrollment each call it independently. Before
        // this fix that meant synthesizing the same 4 sentences twice per
        // enrollment attempt; measure that specific pair of calls in
        // isolation so its contribution is visible on its own.
        let firstCall = ms { _ = SynthesizedSpeech.falseAlarmClips() }
        let secondCall = ms { _ = SynthesizedSpeech.falseAlarmClips() }
        print(String(format: "  DUPLICATE falseAlarmClips() CALL (checkFitness then finishEnrollment): first=%.0f ms second=%.0f ms",
                     firstCall, secondCall))
    }
}

func probeSynthFidelity() -> Bool {
    run("keyword.synthFidelity") { c in
        // The spotter is a 3.3M model and a poor transcriber; read the same clip
        // with the full ASR too, so a claim about pronunciation rests on something
        // that can actually transcribe.
        let asr = try? ParakeetTranscriber(modelDir: asrDir)
        for phrase in ["hey codex", "hey chatgpt", "hey chat gpt", "hey chat g p t",
                       "hey jarvis", "hey xena"] {
            guard let audio = SynthesizedSpeech.samples(of: phrase) else { continue }
            let heard = KwsDebug.decodeTokens(modelDir: kwsDir, samples: audio)
            let transcript = (try? asr?.transcribe(audio)) ?? "<no asr>"
            print("  \(phrase.padding(toLength: 15, withPad: " ", startingAt: 0)) "
                  + "kws=\"\(heard.text)\"".padding(toLength: 26, withPad: " ", startingAt: 0)
                  + " asr=\"\(transcript)\"")
        }
    }
}

func probePhraseFitness() -> Bool {
    run("keyword.phraseFitness") { c in

        func fires(_ tokens: String, _ audio: [Float], threshold: Float) -> Bool {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("pf-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try? (WakeCalibration.keywordLine(tokens: tokens) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            guard let e = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                             keywordsThreshold: threshold) else { return false }
            return e.detects(in: audio)
        }
        let negatives = SynthesizedSpeech.falseAlarmClips()
        let phrases = ["hey codex", "hey chatgpt", "hey siri", "hey jarvis", "hey computer",
                       "ok codex", "hey samantha", "hey machine", "wake up codex",
                       "hey assistant", "hey friday", "hey buddy", "hey xena", "hey there"]
        print("  phrase           fallback  wakes@  falseAlarms  tokens")
        for phrase in phrases {
            guard let tokens = KeywordTokenizer.tokenize(phrase, modelDir: kwsDir) else {
                print("  \(phrase.padding(toLength: 16, withPad: " ", startingAt: 0)) unspellable")
                continue
            }
            let fallback = tokens.split(separator: " ").contains { $0 == KeywordTokenizer.boundary }
            guard let audio = SynthesizedSpeech.samples(of: phrase) else { continue }
            var wakesAt = "never"
            for threshold in KeywordTuning.calibrationThresholds where fires(tokens, audio, threshold: threshold) {
                wakesAt = String(format: "%.2f", threshold); break
            }
            let alarms = negatives.filter { fires(tokens, $0, threshold: 0.25) }.count
            print("  \(phrase.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                  + "\(fallback ? "YES     " : "no      ") \(wakesAt.padding(toLength: 7, withPad: " ", startingAt: 0)) "
                  + "\(alarms)            [\(tokens)]")
            // The claim the UI relies on: the fitness check agrees with what the
            // sweep and the negatives actually show for this phrase.
            let verdict = WakePhraseFitness.check(tokens: tokens, spoken: audio,
                                                 negatives: negatives, fires: { line, t, a in
                fires(String(line.split(separator: " :")[0]), a, threshold: t)
            })
            let expected: WakePhraseFitness.Verdict = alarms > 0 ? .tooCommon
                : (wakesAt == "never" ? .cannotSpot : .good)
            c.assertEqual(verdict, expected, "fitness disagrees with measurement for \(phrase)")
            _ = fallback
        }
    }
}

/// Measures `KeywordTuning.score` and `KeywordTuning.numTrailingBlanks` on real
/// audio, in both directions, and prints a grid so the numbers this file sets
/// have a reproducible source instead of being guessed (they were
/// "Open questions" item 3). Regenerate with:
///
///   swift run hey-codex-selftest tuning
///
/// Prints the grid this produced, the exact
/// corpus, and the winning cell.
///
/// Grid axes: score in {1.0, 1.25, 1.5, 1.75, 2.0} x numTrailingBlanks in
/// {1, 2, 3}, at the shipped threshold 0.25 (not swept - P0.2 already pins it
/// to the default install, and sweeping three axes at once stops being a
/// readable grid).
///
/// Every clip - synthetic and real - is put through the same
/// `AudioSamples.normalized(targetRMS: 0.047, peakCeiling: 0.5)` gain
/// normalization the shipping app now applies before enrollment fitness
/// checks, so this measures runtime behaviour rather than raw `say` output
/// levels.
func probeTuning() -> Bool {
    run("keyword.tuningGrid") { c in
        let targetRMS: Float = 0.047
        let peakCeiling: Float = 0.5

        // Multiple voices deliberately: the two prior GUESSED values in this
        // file were partly a single-voice mistake (measured
        // "Deliberately NOT doing" section, re: the zena/xena re-test). Alex
        // is not installed on every macOS version, so Fred substitutes for it
        // here - both are US English `say` voices distinct from Samantha.
        let voices = ["Samantha", "Alex", "Daniel", "Karen", "Fred"]
        let availableVoices = voices.filter { voice in
            // `say -o` infers the output format from the extension and refuses
            // /dev/null (exit -241), so probe with a real scratch file.
            let probe = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-probe-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: probe) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", voice, "-o", probe.path, "."]
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        if availableVoices.count < voices.count {
            print("  [diag] voices unavailable on this Mac, skipped: "
                  + Set(voices).subtracting(availableVoices).sorted().joined(separator: ", "))
        }

        func synthesize(_ phrase: String, voice: String) -> [Float]? {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("tune-\(UUID().uuidString)")
            let aiff = base.appendingPathExtension("aiff")
            let wav = base.appendingPathExtension("wav")
            defer {
                try? FileManager.default.removeItem(at: aiff)
                try? FileManager.default.removeItem(at: wav)
            }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", aiff.path, phrase]
            guard (try? say.run()) != nil else { return nil }
            say.waitUntilExit()
            guard say.terminationStatus == 0 else { return nil }
            let cv = Process()
            cv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            cv.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            guard (try? cv.run()) != nil else { return nil }
            cv.waitUntilExit()
            return try? AudioSamples.load(wav)
        }

        struct Clip { let label: String; let audio: [Float]; let preNormRMS: Float }
        func clip(_ label: String, _ raw: [Float]) -> Clip {
            Clip(label: label,
                 audio: AudioSamples.normalized(raw, targetRMS: targetRMS, peakCeiling: peakCeiling),
                 preNormRMS: AudioSamples.rms(raw))
        }

        // MARK: keywords under test
        //
        // Production arms exactly one keyword at a time (AppController.swift
        // builds `keywordsFile` from either the bundled default or the one
        // phrase the user enrolled - never several at once). The first version
        // of this grid armed all candidate phrases plus the model's reference
        // keywords together in one engine, and every cell "false-alarmed" on
        // the same clip - which turned out to be the model's own reference
        // keyword FOR EVER firing on "hey there how are you", not anything a
        // real install would ever have armed alongside it. Arming one keyword
        // per engine, matching production, removes that cross-keyword
        // contamination.

        // The default phrase plus several plausible custom ones a real user
        // might enroll. Each gets its own single-keyword engine per cell,
        // tokenized the same way enrollment does.
        let candidatePhrases = ["hey codex", "hey jarvis", "hey computer", "ok codex",
                                 "wake up codex", "hey samantha"]
        var phraseTokens: [String: String] = [:]
        for phrase in candidatePhrases {
            guard let tokens = KeywordTokenizer.tokenize(phrase, modelDir: kwsDir) else {
                print("  [diag] \(phrase) does not tokenize, dropped from the grid"); continue
            }
            phraseTokens[phrase] = tokens
        }
        // The model's own validated keywords (see test_wavs/keywords.txt /
        // trans.txt) - a positive-only sanity control, tested alone, that the
        // tuning grid does not regress detection the model authors themselves
        // shipped as ground truth. Not part of the false-alarm count: no real
        // install ever arms these.
        let referenceClips: [(label: String, tokens: String, wav: String)] = [
            ("test_wavs/0.wav (LIGHT UP)", "▁ L IGHT ▁UP", "test_wavs/0.wav"),
            ("test_wavs/1.wav (LOVELY CHILD)", "▁LOVE LY ▁CHI L D", "test_wavs/1.wav"),
            ("test_wavs/1.wav (FOR EVER)", "▁FOR E VER", "test_wavs/1.wav"),
        ]

        // MARK: positive corpus (per phrase)

        var positivesByPhrase: [String: [Clip]] = [:]
        for phrase in candidatePhrases where phraseTokens[phrase] != nil {
            var clips: [Clip] = []
            for voice in availableVoices {
                guard let raw = synthesize(phrase, voice: voice) else { continue }
                clips.append(clip("\"\(phrase)\" (\(voice))", raw))
            }
            positivesByPhrase[phrase] = clips
        }
        let totalPositives = positivesByPhrase.values.reduce(0) { $0 + $1.count }
        c.assert(totalPositives > 0, "no positive clips were built - say/afconvert may be broken")

        var referencePositives: [(label: String, tokens: String, clip: Clip)] = []
        for r in referenceClips {
            guard let raw = try? AudioSamples.load(kwsDir.appendingPathComponent(r.wav)) else { continue }
            referencePositives.append((r.label, r.tokens, clip(r.label, raw)))
        }

        // MARK: negative corpus (shared across every candidate-phrase engine)

        let falseAlarmSentences = [
            "hey there how are you", "I put it in a bag", "let me check the code for you",
            "the weather today is warm", "can you help me with this later",
            "I think we should go home now", "that sounds like a great idea",
            "please turn off the lights before you leave",
        ]
        var negatives: [Clip] = []
        for sentence in falseAlarmSentences {
            for voice in availableVoices {
                guard let raw = synthesize(sentence, voice: voice) else { continue }
                negatives.append(clip("\"\(sentence)\" (\(voice))", raw))
            }
        }
        // Real human recordings - three takes of "Hey Xena" (a phrase this
        // model cannot spot at all (measured across five voices; "Deliberately NOT
        // doing") captured on a distant monitor mic at RMS 0.005-0.009, 5-9x
        // below the KWS model's own reference level of 0.047. They are not
        // usable as positive evidence for any keyword in this grid - they say
        // the wrong words - so they are folded in here as the hardest
        // available negative: real, quiet, off-keyword human speech. If
        // anything in the corpus is going to false-alarm from noise-floor
        // artifacts introduced by aggressive gain normalization, it is these.
        let takesDir = EnrollmentDiagnostics.audioDirectory
        var realTakesUsed = 0
        for n in 1...3 {
            let takeURL = takesDir.appendingPathComponent("take-\(n).wav")
            if let raw = try? AudioSamples.load(takeURL) {
                negatives.append(clip("take-\(n).wav (real \"hey xena\", quiet mic, stress-only)", raw))
                realTakesUsed += 1
            }
        }
        if realTakesUsed == 0 {
            print("  [diag] no saved enrollment takes found at \(takesDir.path) - real-mic stress negative skipped")
        }

        // MARK: report where the peak ceiling capped normalization short of target

        let allPositiveClips = positivesByPhrase.values.flatMap { $0 } + referencePositives.map(\.clip)
        let short = (allPositiveClips + negatives).filter { AudioSamples.rms($0.audio) < targetRMS * 0.98 }
        if short.isEmpty {
            print("  [diag] every clip reached target RMS \(targetRMS) after normalization")
        } else {
            print("  [diag] peak ceiling (\(peakCeiling)) kept these below target RMS \(targetRMS):")
            for s in short {
                print("    \(s.label.padding(toLength: 55, withPad: " ", startingAt: 0)) "
                      + String(format: "preRMS=%.4f  postRMS=%.4f", s.preNormRMS, AudioSamples.rms(s.audio)))
            }
        }
        print("  [diag] positives=\(totalPositives) across \(positivesByPhrase.count) candidate phrases, "
              + "+\(referencePositives.count) reference-keyword sanity clips (not scored as false-alarm surface)")
        print("  [diag] negatives=\(negatives.count) (incl. \(realTakesUsed) real-mic stress take(s)), "
              + "tested against every candidate phrase's own engine")
        print("  [diag] voices used: \(availableVoices.joined(separator: ", "))")

        // MARK: sweep

        // One keyword armed per engine, matching production - see note above.
        func singleKeywordEngine(tokens: String, score: Float, blanks: Int) -> WakeWordEngine? {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kw-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try? (WakeCalibration.keywordLine(tokens: tokens, score: score) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            return try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                       keywordsThreshold: KeywordTuning.threshold,
                                       keywordsScore: score, numTrailingBlanks: blanks)
        }

        // `detects(in:)` pads every clip with a full second of trailing
        // silence to reliably flush the chunk-16 zipformer's last chunk (see
        // WakeWordEngine.detects(in:)). That is the right model for a
        // positive: the app's capture window keeps recording past the wake
        // word until VAD sees a pause, so there is always ample trailing
        // silence by the time detection runs - which is also why the first
        // run of this grid showed numTrailingBlanks having zero effect on
        // positives at 1/2/3: with a full second of runway, all three are
        // trivially satisfied regardless of the setting.
        //
        // numTrailingBlanks' actual job - per its doc comment, suppressing a
        // false trigger on a fragment buried mid-sentence - can only show up
        // against continuous speech that keeps going, with no artificial
        // pause inserted. So false alarms are measured by streaming the
        // negative clip's own audio frame-by-frame (~100ms/frame, matching
        // the live mic loop) with nothing appended, and checking whether the
        // spotter fires at any point before the sentence ends.
        func firesStreaming(_ e: WakeWordEngine, _ audio: [Float]) -> (Bool, String?) {
            defer { e.reset() }
            let frame = 1600
            var i = 0
            while i < audio.count {
                let chunk = Array(audio[i..<min(i + frame, audio.count)])
                if e.feed(chunk) { return (true, e.lastFiredKeyword) }
                i += frame
            }
            return (false, nil)
        }

        let diag = ProcessInfo.processInfo.environment["HEYCODEX_TUNING_DIAG"] == "1"
        let totalNegativeChecks = negatives.count * positivesByPhrase.count
        let scores: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
        let blanksValues = [1, 2, 3]
        print("\n  score blanks | positives              falseAlarms (per-phrase engine x negative corpus)")
        var best: (score: Float, blanks: Int, positives: Int, falseAlarms: Int)?
        var referenceRegressed = false
        for score in scores {
            for blanks in blanksValues {
                var posHits = 0
                var falseHits = 0
                for (phrase, clips) in positivesByPhrase {
                    guard let tokens = phraseTokens[phrase],
                          let e = singleKeywordEngine(tokens: tokens, score: score, blanks: blanks) else {
                        print("  \(phrase): ENGINE CONSTRUCTION FAILED"); continue
                    }
                    posHits += clips.filter { e.detects(in: $0.audio) }.count
                    for n in negatives {
                        let (fired, keyword) = firesStreaming(e, n.audio)
                        if fired {
                            falseHits += 1
                            if diag { print("    [diag] false alarm: \(n.label) armed=\"\(phrase)\" fired=[\(keyword ?? "?")]") }
                        }
                    }
                }
                // Reference-keyword regression check: positive-only, not part
                // of the false-alarm count (see note above).
                var refHits = 0
                for r in referencePositives {
                    if let e = singleKeywordEngine(tokens: r.tokens, score: score, blanks: blanks),
                       e.detects(in: r.clip.audio) {
                        refHits += 1
                    }
                }
                if refHits < referencePositives.count { referenceRegressed = true }
                print(String(format: "  %.2f  %d      | %3d/%-3d (%5.1f%%)  ref %d/%-3d  %3d/%-3d",
                             score, blanks, posHits, totalPositives,
                             100.0 * Double(posHits) / Double(max(totalPositives, 1)),
                             refHits, referencePositives.count,
                             falseHits, totalNegativeChecks))
                if falseHits == 0, best == nil || posHits > best!.positives {
                    best = (score, blanks, posHits, falseHits)
                }
            }
        }
        if referenceRegressed {
            print("  [diag] at least one cell missed a model-authors' reference keyword - see per-cell ref column")
        }

        // Per-phrase breakdown at the winning cell, so a reader can see which
        // phrases/voices missed rather than only the aggregate count.
        if let b = best {
            print("\n  [diag] per-phrase detection at the winning cell (score=\(b.score), blanks=\(b.blanks)):")
            for (phrase, clips) in positivesByPhrase.sorted(by: { $0.key < $1.key }) {
                guard let tokens = phraseTokens[phrase],
                      let e = singleKeywordEngine(tokens: tokens, score: b.score, blanks: b.blanks) else { continue }
                let hits = clips.filter { e.detects(in: $0.audio) }
                let hitLabels = Set(hits.map(\.label))
                let missed = clips.filter { !hitLabels.contains($0.label) }
                print("    \(phrase.padding(toLength: 16, withPad: " ", startingAt: 0)) \(hits.count)/\(clips.count)"
                      + (missed.isEmpty ? "" : "   missed: " + missed.map { $0.label }.joined(separator: ", ")))
            }
        }

        if let b = best {
            print(String(format: "\n  [winner] score=%.2f numTrailingBlanks=%d - "
                         + "%d/%d positives, 0/%d false alarms. Maximizes positive "
                         + "detection at zero false alarms; lowest score then lowest "
                         + "blanks among ties.",
                         b.score, b.blanks, b.positives, totalPositives, totalNegativeChecks))
        } else {
            print("\n  [winner] none - every cell produced at least one false alarm")
        }
        c.assert(best != nil, "no (score, numTrailingBlanks) combination reached zero false alarms")
    }
}

func checkWakePhraseDefaults() -> Bool {
    run("wakePhrase.defaults") { c in
        c.assertEqual(Settings.default.wakePhrase, "Hey Codex",
                      "Hey Codex must remain the release default")
        c.assertEqual(WakePhrase.presets, ["Hey Codex", "Hey Jarvis", "Hey Computer"])
    }
}

// Mirrors CodexSettingsTests.test_defaultWakeKeywordsScoreMatchesCalibratedTuning.
func checkDefaultKeywordsScore() -> Bool {
    run("wakePhrase.defaultScoreMatchesTuning") { c in
        c.assertEqual(Settings.default.wakeKeywordsScore, KeywordTuning.score,
                      "a fresh install must run at the calibrated score, not a second hardcoded literal")
    }
}

// Audio fixtures are not part of a release checkout. Use the KWS model's own
// distributed validation WAV so this remains reproducible after a fresh clone.
func checkAudioLoader() -> Bool {
    run("audio.loads16kMonoFloatSamples") { c in
        let samples = try AudioSamples.load(kwsDir.appendingPathComponent("test_wavs/0.wav"))
        c.assert(samples.count > 8000, "expected > 8000 samples, got \(samples.count)")
        c.assert(samples.allSatisfy { $0 >= -1.0 && $0 <= 1.0 },
                 "samples out of [-1, 1] range")
    }
}

// Calibrated wake-word threshold, chosen from the threshold sweep in
// probeWake/probeTuning below against real and synthetic clips.
let wakeThreshold: Float = 0.25

func makeWakeEngine(threshold: Float = wakeThreshold) throws -> WakeWordEngine {
    let t0 = Date()
    let e = try WakeWordEngine(modelDir: kwsDir, keywordsFile: keywordsFile,
                               keywordsThreshold: threshold)
    FileHandle.standardError.write(
        "  [diag] wake engine constructed in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s\n"
            .data(using: .utf8)!)
    return e
}

func diagDetect(_ engine: WakeWordEngine, _ samples: [Float], _ label: String) -> Bool {
    let t0 = Date()
    let r = engine.detects(in: samples)
    FileHandle.standardError.write(
        "  [diag] detect(\(label)) -> \(r) in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s\n"
            .data(using: .utf8)!)
    return r
}

// Mirrors WakeWordEngineTests.test_doesNotFireOnNegativeSpeech.
func checkWakeNegative() -> Bool {
    run("wake.doesNotFireOnNegativeSpeech") { c in
        let engine = try makeWakeEngine()
        let samples = [Float](repeating: 0, count: 16000 * 2)
        c.assert(!diagDetect(engine, samples, "silence"), "fired on silence")
    }
}

// Positive control: prove the detection plumbing fires at all, using the
// model's OWN validated keyword file against its OWN test wav (0.wav contains
// "…LIGHT UP HERE…", and test_keywords.txt includes "▁ L IGHT ▁UP").
func checkWakePositiveControl() -> Bool {
    run("wake.positiveControl(model-own-keyword)") { c in
        let ownKeywords = kwsDir.appendingPathComponent("test_wavs/test_keywords.txt")
        let ownWav = kwsDir.appendingPathComponent("test_wavs/0.wav")
        let engine = try WakeWordEngine(modelDir: kwsDir, keywordsFile: ownKeywords,
                                        keywordsThreshold: 0.25)
        let samples = try AudioSamples.load(ownWav)
        c.assert(diagDetect(engine, samples, "0.wav/LIGHT UP"),
                 "engine did not fire on the model's own validated keyword+wav")
    }
}

// Positive detection on a synthetic clip of the wake phrase.
//
// Fires on the synthetic `say -v Samantha "hey claude"` clip at the calibrated
// defaults. The earlier "never fires" symptom was a streaming-flush bug (the
// tail pad was too short to drain the zipformer's last chunk on a ~0.7s clip),
// fixed in WakeWordEngine.detects(in:).
func checkWakePositive() -> Bool {
    run("wake.detectsWakePhraseInPositiveClip") { c in
        let engine = try makeWakeEngine()
        let samples = try AudioSamples.load(fixture("hey_claude_only"))
        c.assert(diagDetect(engine, samples, "hey_claude_only"),
                 "synthetic 'hey claude' clip did not fire the wake word")
    }
}

// Diagnostic sweep: prints detection across thresholds + clips. Not a pass/fail
// gate - used to calibrate `wakeThreshold` honestly. One engine per threshold
// (model load is ~0.3s), all clips reused.
func probeWake() -> Bool {
    print("PROBE wake threshold sweep")
    let clips = ["hey_claude_only", "hey_claude_code", "hey_claude_prompt", "negative_speech"]
    let loaded = clips.compactMap { name -> (String, [Float])? in
        guard let s = try? AudioSamples.load(fixture(name)) else { return nil }
        return (name, s)
    }
    // Fresh engine per (threshold, clip): the wrapper's single internal stream
    // is finished after one detect(), so it is not safely reusable across clips.
    for t in [Float(0.02), 0.05, 0.10, 0.15, 0.20, 0.25] {
        var line = "  thr=\(t):"
        for (name, s) in loaded {
            guard let engine = try? WakeWordEngine(
                modelDir: kwsDir, keywordsFile: keywordsFile, keywordsThreshold: t) else {
                line += " \(name)=ERR"; continue
            }
            line += " \(name)=\(engine.detects(in: s) ? "Y" : "n")"
        }
        print(line)
    }
    return true
}

// What tokens does the KWS transducer ACTUALLY emit for each synthetic clip?
// Drive the same encoder/decoder/joiner as a plain online recognizer so we can
// build the keyword from the real emitted tokens rather than dictionary BPE.
func probeDecode() -> Bool {
    print("PROBE decode (KWS model as online transducer)")
    for clip in ["hey_claude_only", "hey_claude_code", "hey_claude_prompt"] {
        guard let samples = try? AudioSamples.load(fixture(clip)) else { continue }
        let r = KwsDebug.decodeTokens(modelDir: kwsDir, samples: samples)
        print("  \(clip): text=\"\(r.text)\"  tokens=\(r.tokens)")
    }
    return true
}

/// Decode an arbitrary 16 kHz mono WAV with the KWS model. This is used to
/// calibrate a new dedicated command phrase before it is shipped as a keyword.
func probeDecodeFile(_ path: String) -> Bool {
    guard let samples = try? AudioSamples.load(URL(fileURLWithPath: path)) else {
        print("FAIL    could not load \(path) as 16 kHz mono audio")
        return false
    }
    let r = KwsDebug.decodeTokens(modelDir: kwsDir, samples: samples)
    print("DECODE  text=\"\(r.text)\"  tokens=\(r.tokens)")
    return !r.tokens.isEmpty
}

// Live calibration: record YOUR real "hey codex" and show the tokens the KWS
// model emits for it + whether the current keyword fires. The synthetic fixtures
// may tokenize differently than a real voice; this is the data we build the
// keyword from. Run: `swift run hey-codex-selftest mic-decode`.
func probeMicDecode() -> Bool {
    final class Buf: @unchecked Sendable {
        private var s: [Float] = []
        private let lock = NSLock()
        func append(_ f: [Float]) { lock.lock(); s.append(contentsOf: f); lock.unlock() }
        func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return s }
    }

    let rounds = 5, windowSec = 2.5
    print("PROBE mic-decode - say \"hey codex\" once per round (\(rounds) rounds).")
    let wake = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: keywordsFile,
                                   keywordsThreshold: 0.25, keywordsScore: 2.0)
    for round in 1...rounds {
        let buf = Buf()
        guard let mic = try? AudioCapture(onFrame: { buf.append($0) }) else {
            print("  mic init failed"); return true
        }
        print("  Round \(round)/\(rounds): say \"hey codex\" NOW…")
        do { try mic.start() } catch { print("  mic start failed: \(error)"); return true }
        Thread.sleep(forTimeInterval: windowSec)
        mic.stop()

        let samples = buf.snapshot()
        let r = KwsDebug.decodeTokens(modelDir: kwsDir, samples: samples)
        let fired = wake?.detects(in: samples) ?? false
        print("        text=\"\(r.text)\"")
        print("        tokens=\(r.tokens)")
        print("        current keyword fires? \(fired ? "✅ YES" : "❌ NO")")
    }
    print("\n  Keyword file currently: \(((try? String(contentsOf: keywordsFile, encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines))")
    return true
}

// Full wake enrollment over 3 live utterances - the real algorithm end to end,
// dry-run (does NOT overwrite your per-user keyword). Run: `… enroll`.
func probeEnroll() -> Bool {
    let kws = kwsDir   // capture locally so the @Sendable closures don't touch globals
    print("PROBE enroll - 3 live utterances (2 isolated + 1 natural).")

    func recordOne(_ label: String) -> [Float] {
        print("  \(label)")
        final class Clip: @unchecked Sendable { var s: [Float] = [] }
        let clip = Clip()
        let sem = DispatchSemaphore(value: 0)
        let rec = EnrollmentRecorder(endpointSilenceMs: 800, maxSeconds: 8)
        do { try rec.record(onClip: { c in clip.s = c; sem.signal() }) }
        catch { print("    mic failed: \(error)"); return [] }
        sem.wait()
        print("    captured \(clip.s.count) samples (~\(String(format: "%.1f", Double(clip.s.count) / 16000))s)")
        return clip.s
    }

    let samples: [WakeEnrollment.Sample] = [
        .init(audio: recordOne("Isolated 1 - say the phrase NOW…"), kind: .isolated),
        .init(audio: recordOne("Isolated 2 - say the phrase NOW…"), kind: .isolated),
        .init(audio: recordOne("Natural - say the phrase and ask for something…"), kind: .natural),
    ]

    let phrase = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    let spoken = phrase.isEmpty ? "hey codex" : phrase
    guard let tokens = KeywordTokenizer.tokenize(spoken, modelDir: kws) else {
        print("  cannot tokenise \(spoken)"); return false
    }
    let calibration = WakeCalibration(fires: { line, threshold, audio in
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hc-enroll-kw.txt")
        try? (line + "\n").write(to: tmp, atomically: true, encoding: .utf8)
        guard let e = try? WakeWordEngine(modelDir: kws, keywordsFile: tmp,
                                          keywordsThreshold: threshold)
        else { return false }
        return e.detects(in: audio)
    })

    let verdict = WakePhraseFitness.check(tokens: tokens,
                                         spoken: SynthesizedSpeech.samples(of: spoken),
                                         negatives: SynthesizedSpeech.falseAlarmClips(),
                                         fires: calibration.fires)
    let r = calibration.calibrate(tokens: tokens, samples: samples.map(\.audio))
    print("\n  === ENROLLMENT RESULT (dry run - not saved) ===")
    print("  phrase: \(spoken)")
    print("  keyword: \(r.keywordLine)")
    print("  fitness: \(verdict)")
    print("  threshold: \(r.threshold)")
    print("  takes firing: \(r.firedCount)/\(r.sampleCount)   usable: \(r.isUsable ? "YES" : "NO")")
    let labels = ["isolated-1", "isolated-2", "natural   "]
    for (i, sample) in samples.enumerated() {
        let toks = KwsDebug.decodeTokens(modelDir: kws, samples: sample.audio).tokens
        let f = calibration.fires(WakeCalibration.keywordLine(tokens: tokens, threshold: r.threshold),
                                  r.threshold, sample.audio)
        print("    \(labels[i]): fires \(f ? "yes" : "NO ")   heardAs=\(WakeEnrollment.keywordLine(from: toks))")
    }
    return r.isUsable
}

// DIAG 1 - audio sanity: transcribe the EXACT wake clip used by the wake test.
func probeTranscribeOnly() -> Bool {
    print("PROBE asr transcript of hey_claude_only")
    guard let samples = try? AudioSamples.load(fixture("hey_claude_only")),
          let t = try? ParakeetTranscriber(modelDir: asrDir) else {
        print("  ERR could not load model/clip"); return true
    }
    let text = (try? t.transcribe(samples)) ?? "<threw>"
    print("  hey_claude_only: \"\(text)\"")
    return true
}

// DIAG 2 - boost sweep. keywords_score keeps the keyword path alive in the
// beam when acoustic evidence is weak (a different lever than threshold). Sweep
// it over the positive clip AND negative_speech so we can pick a value with
// separation (fires on positive, quiet on negative). Threshold pinned low.
func probeBoostSweep() -> Bool {
    print("PROBE wake boost sweep (threshold=0.10)")
    let clips = ["hey_claude_only", "negative_speech"]
    let loaded = clips.compactMap { name -> (String, [Float])? in
        guard let s = try? AudioSamples.load(fixture(name)) else { return nil }
        return (name, s)
    }
    print("  boost  | " + loaded.map { $0.0 }.joined(separator: "  "))
    for boost in [Float(1.0), 2.0, 3.0, 5.0, 8.0] {
        var line = "  \(String(format: "%.1f", boost))    |"
        for (_, s) in loaded {
            // Fresh engine per (boost, clip): the single internal stream is
            // finished after one detect().
            guard let e = try? WakeWordEngine(
                modelDir: kwsDir, keywordsFile: keywordsFile,
                keywordsThreshold: 0.10, keywordsScore: boost) else {
                line += " ERR"; continue
            }
            line += " \(e.detects(in: s) ? "FIRE" : "----")"
        }
        print(line)
    }
    return true
}

// MARK: - Threshold sweep (wake-sensitivity slider verification)

/// Proves the `keywordsThreshold` parameter - what the Settings ▸ Voice
/// sensitivity slider sets - actually gates firing. Sweeps from eager (low) to
/// strict (high) at the shipped boost; the positive clip should fire while the
/// gate is below its achieved score and stop once the gate climbs past it. The
/// shaded band [0.08 … 0.30] marks the slider's live range (see VoiceSection).
func probeThresholdSweep() -> Bool {
    print("PROBE wake threshold sweep (score=2.0; slider range 0.08…0.30)")
    let clips = ["hey_claude_only", "negative_speech"]
    let loaded = clips.compactMap { name -> (String, [Float])? in
        guard let s = try? AudioSamples.load(fixture(name)) else { return nil }
        return (name, s)
    }
    print("  thresh | " + loaded.map { $0.0 }.joined(separator: "  "))
    for thresh in [Float(0.08), 0.15, 0.25, 0.30, 0.50, 0.70, 0.90] {
        let band = (thresh >= 0.08 && thresh <= 0.30) ? "*" : " "
        var line = "  \(String(format: "%.2f", thresh))\(band)  |"
        for (_, s) in loaded {
            guard let e = try? WakeWordEngine(
                modelDir: kwsDir, keywordsFile: keywordsFile,
                keywordsThreshold: thresh, keywordsScore: 2.0) else {
                line += " ERR"; continue
            }
            line += " \(e.detects(in: s) ? "FIRE" : "----")"
        }
        print(line)
    }
    return true
}

// Mirrors ParakeetTranscriberTests.test_transcribesPromptClip.
func checkTranscribe() -> Bool {
    run("asr.transcribesPromptClip") { c in
        let t0 = Date()
        let t = try ParakeetTranscriber(modelDir: asrDir)
        FileHandle.standardError.write(
            "  [diag] ASR engine constructed in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s\n"
                .data(using: .utf8)!)
        let text = try t.transcribe(try AudioSamples.load(fixture("hey_claude_prompt")))
        print("  [asr] transcript: \"\(text)\"")
        c.assert(text.contains("refactor"), "expected 'refactor', got: \(text)")
        c.assert(text.contains("auth"), "expected 'auth', got: \(text)")
    }
}

// Diagnostic (not a test): reproduces the app's exact routing for each
// "hey claude" fixture - transcribe -> WakePrefixStripper -> CommandRegistry , 
// to reveal which command a bare/coded/prompt utterance actually resolves to.
// Mirrors VoiceSession.handle. Run: `swift run hey-codex-selftest route`.
func probeRoute() -> Bool {
    run("route.resolvesFixturesToCommands") { _ in
        let asr = try ParakeetTranscriber(modelDir: asrDir)
        let s = Settings.default
        let registry = CommandRegistry(commands: s.commands,
                                       defaultCommandID: s.defaultCommandID,
                                       promptCommandID: s.promptCommandID)

        func kindLabel(_ k: CommandKind) -> String {
            switch k {
            case .runShell(let s): return "runShell(\(s))"
            case .sendCodexVoiceShortcut: return "sendCodexVoiceShortcut"
            }
        }

        func report(_ tag: String, _ raw: String) {
            let stripped = WakePrefixStripper.command(from: raw)
            let res = registry.resolve(transcript: stripped)
            print("  [route] \(tag)")
            print("          raw       = \"\(raw)\"")
            print("          stripped  = \(stripped.map { "\"\($0)\"" } ?? "nil (bare wake)")")
            if let res = res {
                print("          resolved  = \(res.command.label)  [\(kindLabel(res.command.kind))]  prompt=\(res.prompt.map { "\"\($0)\"" } ?? "nil")")
            } else {
                print("          resolved  = nil (no command)")
            }
        }

        for name in ["hey_claude_only", "hey_claude_code", "hey_claude_prompt"] {
            report(name, try asr.transcribe(try AudioSamples.load(fixture(name))))
        }

        // Simulate the LIVE capture clip: 2.0s preroll silence + utterance +
        // trailing silence to the 2.5s post-fire cap. Tests whether Parakeet
        // hallucinates/repeats on the silence padding the live path adds.
        let only = try AudioSamples.load(fixture("hey_claude_only"))
        let lead = [Float](repeating: 0, count: 32000)   // 2.0s @ 16kHz preroll
        for tailS in [0.6, 1.5, 2.5] {
            let tail = [Float](repeating: 0, count: Int(16000 * tailS))
            let padded = lead + only + tail
            report("padded(lead2.0s+tail\(tailS)s)", try asr.transcribe(padded))
        }
    }
}

// MARK: - Dispatch

func main() -> Int32 {
    setbuf(stdout, nil)  // unbuffered: see progress live even when piped
    let requested = CommandLine.arguments.dropFirst().first ?? "all"
    var allOK = true

    // Explicit, side-effecting live checks - never part of "all".
    if requested == "path-parity" {
        let phrase = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        return probePathParity(phrase.isEmpty ? "hey codex" : phrase) ? 0 : 1
    }
    if requested == "timing" {
        return probeTiming() ? 0 : 1
    }
    if requested == "timing-cold" {
        try? FileManager.default.removeItem(at: SynthesizedSpeech.cacheDirectory)
        return probeTiming() ? 0 : 1
    }
    if requested == "clear-negatives-cache" {
        try? FileManager.default.removeItem(at: SynthesizedSpeech.cacheDirectory)
        print("cleared \(SynthesizedSpeech.cacheDirectory.path)")
        return 0
    }
    if requested == "synth-fidelity" {
        return probeSynthFidelity() ? 0 : 1
    }
    if requested == "phrase-fitness" {
        return probePhraseFitness() ? 0 : 1
    }
    if requested == "replay-enrollment" {
        let phrase = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        return probeReplayEnrollment(phrase.isEmpty ? "hey codex" : phrase) ? 0 : 1
    }
    if requested == "tuning" {
        return probeTuning() ? 0 : 1
    }
    if requested == "tokenizer" {
        return probeTokenizer() ? 0 : 1
    }
    if requested == "audio-footprint" {
        return probeAudioFootprint() ? 0 : 1
    }
    if requested == "bundle-models" {
        let app = CommandLine.arguments.dropFirst(2).first ?? "dist/HeyCodex.app"
        return probeBundleModels(app) ? 0 : 1
    }
    if requested == "decode-file" {
        guard let path = CommandLine.arguments.dropFirst(2).first else {
            print("usage: hey-codex-selftest decode-file /path/to/16k-mono.wav")
            return 2
        }
        return probeDecodeFile(path) ? 0 : 1
    }

    func maybe(_ key: String, _ check: () -> Bool) {
        if requested == "all" || requested == key {
            if !check() { allOK = false }
        }
    }

    maybe("sherpa", checkSherpaLinks)
    maybe("latch", checkActivationLatch)
    maybe("shortcut", checkVoiceShortcut)
    maybe("wake-phrase", checkWakePhraseDefaults)
    maybe("wake-phrase-score", checkDefaultKeywordsScore)
    // `all` deliberately uses only release-relevant, deterministic checks.
    // The remaining probes stay available by explicit name for model diagnosis.
    maybe("audio", checkAudioLoader)
    maybe("wake-negative", checkWakeNegative)
    maybe("wake-control", checkWakePositiveControl)
    if requested != "all" {
        maybe("voice-panel", probeVoicePanel)
        maybe("wake-positive", checkWakePositive)
        maybe("wake-probe", probeWake)
        maybe("decode-probe", probeDecode)
        maybe("mic-decode", probeMicDecode)
        maybe("enroll", probeEnroll)
        maybe("asr-only", probeTranscribeOnly)
        maybe("boost-sweep", probeBoostSweep)
        maybe("threshold-sweep", probeThresholdSweep)
        maybe("asr", checkTranscribe)
        maybe("route", probeRoute)
    }

    return allOK ? 0 : 1
}

exit(main())
