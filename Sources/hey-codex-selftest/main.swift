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

/// Does a plain-text keyword work, given the BPE vocabulary?
///
/// This is the assumption the whole keyword design now rests on. Previously the
/// app hand-wrote token splits like "▁HE Y ▁CO DE X" and enrollment derived them
/// from what the model decoded, which produced nonsense such as "▁A GE ▁A R G US"
/// for "Hey Jarvis". Canonical tokenisation removes the guesswork, but only if
/// sherpa really accepts raw text here.
/// Run: `swift run hey-codex-selftest bpe-keywords`
func probeBpeKeywords() -> Bool {
    run("keyword.plainTextWithBpeVocab") { c in
        func spoken(_ phrase: String) throws -> [Float] {
            let aiff = FileManager.default.temporaryDirectory
                .appendingPathComponent("kws-\(UUID().uuidString).aiff")
            let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
            defer {
                try? FileManager.default.removeItem(at: aiff)
                try? FileManager.default.removeItem(at: wav)
            }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-o", aiff.path, phrase]
            try say.run(); say.waitUntilExit()
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            try convert.run(); convert.waitUntilExit()
            return try AudioSamples.load(wav)
        }

        func keywordFile(_ contents: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kw-\(UUID().uuidString).txt")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let bpe = kwsDir.appendingPathComponent(KeywordTuning.bpeVocabName)
        c.assert(FileManager.default.fileExists(atPath: bpe.path),
                 "bpe.model missing from the model directory; plain text keywords cannot work without it")

        let positive = try spoken("hey codex")
        let negative = try spoken("the weather today is sunny and warm")

        // Plain text, tokenised by sherpa using the BPE vocabulary.
        let plain = try keywordFile("HEY CODEX\n")
        let engine = try WakeWordEngine(modelDir: kwsDir, keywordsFile: plain,
                                        keywordsThreshold: KeywordTuning.threshold,
                                        keywordsScore: KeywordTuning.score)
        let firedOnPhrase = diagDetect(engine, positive, "plain-text keyword vs \"hey codex\"")
        c.assert(firedOnPhrase, "a plain text keyword did not fire on the phrase it names")

        let negEngine = try WakeWordEngine(modelDir: kwsDir, keywordsFile: plain,
                                          keywordsThreshold: KeywordTuning.threshold,
                                          keywordsScore: KeywordTuning.score)
        c.assert(!diagDetect(negEngine, negative, "plain-text keyword vs unrelated speech"),
                 "plain text keyword fired on unrelated speech")

        // Per-keyword score and threshold, the documented way to tune one keyword
        // without moving a global dial that affects every other one.
        let tuned = try keywordFile("HEY CODEX :1.5 #0.20\n")
        let tunedEngine = try WakeWordEngine(modelDir: kwsDir, keywordsFile: tuned)
        c.assert(diagDetect(tunedEngine, positive, "per-keyword :score #threshold"),
                 "per-keyword score and threshold syntax was not accepted")
    }
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
        let clips = takes.compactMap { try? AudioSamples.load($0) }
        c.assertEqual(clips.count, takes.count, "every saved take should load")
        guard let tokens = KeywordTokenizer.tokenize(phrase, modelDir: kwsDir) else {
            c.fail("cannot tokenise \(phrase)"); return
        }
        let calibration = WakeCalibration(fires: { line, threshold, audio in
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("rp-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            guard let e = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                             keywordsThreshold: threshold) else { return false }
            return e.detects(in: audio)
        })
        print("  phrase=\(phrase)")
        print("  keyword=[\(tokens)]")
        let verdict = WakePhraseFitness.check(tokens: tokens,
                                             spoken: SynthesizedSpeech.samples(of: phrase),
                                             negatives: SynthesizedSpeech.falseAlarmClips(),
                                             fires: calibration.fires)
        print("  fitness=\(verdict)")
        let sweep = KeywordTuning.calibrationThresholds
        let row = sweep.map { threshold in
            clips.filter {
                calibration.fires(WakeCalibration.keywordLine(tokens: tokens, threshold: threshold),
                                  threshold, $0)
            }.count
        }
        print("  takes fired: " + zip(sweep, row).map { String(format: "%.2f:%d", $0, $1) }
                                                .joined(separator: " "))
        let result = calibration.calibrate(tokens: tokens, samples: clips)
        print(String(format: "  threshold=%.2f fired=%d/%d usable=%@",
                     result.threshold, result.firedCount, result.sampleCount,
                     result.isUsable ? "yes" : "NO"))
        // Fitness is advisory: a warning that turns out to be wrong is fine, a
        // clearance that turns out to be wrong is not.
        if verdict == .good {
            c.assert(result.isUsable, "fitness cleared this phrase but no recording of it fires")
        }
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

func probeTuning() -> Bool {
    run("keyword.tuningGrid") { c in
        func spoken(_ phrase: String) throws -> [Float] {
            let aiff = FileManager.default.temporaryDirectory
                .appendingPathComponent("t-\(UUID().uuidString).aiff")
            let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
            defer {
                try? FileManager.default.removeItem(at: aiff)
                try? FileManager.default.removeItem(at: wav)
            }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-o", aiff.path, phrase]
            try say.run(); say.waitUntilExit()
            let cv = Process()
            cv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            cv.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
            try cv.run(); cv.waitUntilExit()
            return try AudioSamples.load(wav)
        }
        guard let tokens = KeywordTokenizer.tokenize("hey codex", modelDir: kwsDir) else {
            c.fail("tokenisation failed"); return
        }
        let positive = try spoken("hey codex")
        let negatives = [
            try spoken("the weather today is sunny and warm"),
            try spoken("I can help you with that"),
            try spoken("hey there how are you doing"),
            try spoken("let me check the codebase for you"),
        ]

        func detects(_ audio: [Float], score: Float, threshold: Float, blanks: Int) -> Bool {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kw-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            try? (WakeCalibration.keywordLine(tokens: tokens, score: score) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            guard let e = try? WakeWordEngine(modelDir: kwsDir, keywordsFile: file,
                                             keywordsThreshold: threshold,
                                             keywordsScore: score,
                                             numTrailingBlanks: blanks) else { return false }
            return e.detects(in: audio)
        }

        print("  score thresh blanks | wake? falseAlarms")
        var recommended: (Float, Float, Int)?
        for score in [Float(1.0), 1.5, 2.0] {
            for threshold in [Float(0.25), 0.20, 0.15] {
                for blanks in [1, 2] {
                    let woke = detects(positive, score: score, threshold: threshold, blanks: blanks)
                    let false_ = negatives.filter { detects($0, score: score, threshold: threshold, blanks: blanks) }.count
                    print(String(format: "  %.1f   %.2f   %d      | %@   %d",
                                 score, threshold, blanks, woke ? "yes" : "NO ", false_))
                    if woke, false_ == 0, recommended == nil { recommended = (score, threshold, blanks) }
                }
            }
        }
        if let r = recommended {
            print(String(format: "  [diag] strictest setting that wakes with zero false alarms: score=%.1f threshold=%.2f blanks=%d", r.0, r.1, r.2))
        }
        c.assert(recommended != nil, "no combination woke on the phrase without false alarms")
    }
}

func checkWakePhraseDefaults() -> Bool {
    run("wakePhrase.defaults") { c in
        c.assertEqual(Settings.default.wakePhrase, "Hey Codex",
                      "Hey Codex must remain the release default")
        c.assertEqual(WakePhrase.presets, ["Hey Codex", "Hey Jarvis", "Hey Computer"])
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

// Calibrated wake-word threshold; see internal design notes.
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
// fixed in WakeWordEngine.detects(in:). See internal design notes.
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
            case .runCLI(let t):   return "runCLI(\(t))"
            case .openApp(let b):  return "openApp(\(b))"
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

// MARK: - Editor target routing (mirrors EditorRoutingTests + CommandExecutorTests)

final class URLBox: @unchecked Sendable { var url: URL? }
final class ResultBox: @unchecked Sendable { var result: Result<Void, LaunchFailure>? }

final class ProbeMockLauncher: TerminalLauncher, @unchecked Sendable {
    var launched: [LaunchSpec] = []
    func isAvailable() -> Bool { true }
    func launch(_ spec: LaunchSpec) throws { launched.append(spec) }
}

func probeEditorRoute() -> Bool {
    var ok = true
    ok = run("editor.deepLinkEncodesPrompt") { c in
        let url = DeepLinkBuilder.url(editor: .cursor, integration: .claudeCode,
                                      prompt: "fix the bug - now 🚀")
        c.assertEqual(url.absoluteString,
            "cursor://anthropic.claude-code/open?prompt=fix%20the%20bug%20%E2%80%94%20now%20%F0%9F%9A%80")
    } && ok
    ok = run("editor.deepLinkNoPrompt") { c in
        c.assertEqual(DeepLinkBuilder.url(editor: .vscode, integration: .claudeCode, prompt: nil).absoluteString,
                      "vscode://anthropic.claude-code/open")
    } && ok
    ok = run("editor.launchTargetRoundTrips") { c in
        for t: LaunchTarget in [.terminal(.iterm2), .editor(.cursor), .editor(.antigravity)] {
            let data = try JSONEncoder().encode(t)
            c.assertEqual(try JSONDecoder().decode(LaunchTarget.self, from: data), t)
        }
    } && ok
    ok = run("editor.resolverPicksSingleActiveEditor") { c in
        c.assertEqual(DefaultTargetResolver.resolve(candidates: [.cursor, .vscode], active: [.cursor]),
                      .editor(.cursor))
        c.assertEqual(DefaultTargetResolver.resolve(candidates: [.cursor, .vscode], active: []),
                      .terminal(.terminalApp))
        c.assertEqual(DefaultTargetResolver.resolve(candidates: [.cursor, .vscode], active: [.cursor, .vscode]),
                      .terminal(.terminalApp))
    } && ok
    ok = run("editor.resolverMapsIdeNames") { c in
        c.assertEqual(DefaultTargetResolver.activeEditors(
            fromIdeNames: ["Cursor", "Visual Studio Code"], among: [.cursor, .vscode, .antigravity]),
                      [.cursor, .vscode])
    } && ok
    ok = run("editor.executorOpensDeepLink") { c in
        let box = URLBox()
        let exec = CommandExecutor(settings: .default,
                                   launcherFor: { _ in ProbeMockLauncher() },
                                   openURL: { box.url = $0; return true })
        let cmd = Command(id: "claude-code", label: "Claude Code", triggers: ["code"],
                          kind: .runCLI(commandTemplate: "claude {prompt}"),
                          target: .editor(.cursor), acceptsPrompt: true,
                          editorIntegration: .claudeCode)
        exec.execute(cmd, prompt: "fix the bug") { _ in }
        c.assertEqual(box.url?.absoluteString ?? "nil",
                      "cursor://anthropic.claude-code/open?prompt=fix%20the%20bug")
    } && ok
    ok = run("editor.availabilityTempHome") { c in
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-selftest-avail-\(ProcessInfo.processInfo.globallyUniqueString)")
        let ext = home.appendingPathComponent(".cursor/extensions/anthropic.claude-code-2.1.0")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let avail = EditorAvailability(home: home, appInstalled: { $0 == EditorKind.cursor.bundleID })
        c.assert(avail.isReady(.cursor, integration: .claudeCode), "cursor should be ready")
        c.assert(!avail.isReady(.vscode, integration: .claudeCode), "vscode should not be ready")
    } && ok
    return ok
}

// LIVE end-to-end: drives the REAL backend path (Command → CommandExecutor →
// DeepLinkBuilder → NSWorkspace.open) to open Claude Code inside Cursor. Has a
// real side effect, so it's never part of "all" - run it explicitly.
func probeEditorOpenLive(_ editor: EditorKind) -> Bool {
    let exec = CommandExecutor(settings: .default,
                               launcherFor: { _ in ProbeMockLauncher() })
    let cmd = Command(id: "claude-code", label: "Claude Code", triggers: ["code"],
                      kind: .runCLI(commandTemplate: "claude {prompt}"),
                      target: .editor(editor), acceptsPrompt: true,
                      editorIntegration: .claudeCode)
    let prompt = "BACKEND TEST - opened via CommandExecutor, do not press enter"
    print("  url = \(DeepLinkBuilder.url(editor: editor, integration: .claudeCode, prompt: prompt).absoluteString)")
    let outcome = ResultBox()
    exec.execute(cmd, prompt: prompt) { outcome.result = $0 }
    switch outcome.result {
    case .success:
        print("OPENED  \(editor.rawValue) - check the editor for a Claude Code panel")
        return true
    case .failure(let f):
        print("FAIL    \(f.localizedDescription)")
        return false
    case .none:
        print("FAIL    no result (completion not called)")
        return false
    }
}

// Claude-Code-only routing on the shipped defaults (pure - no models needed).
func probeDefaultRouting() -> Bool {
    run("routing.claudeCodeOnlyDefaults") { c in
        let s = Settings.default
        c.assertEqual(s.defaultCommandID, "claude-code", "bare wake → code")
        let registry = CommandRegistry(commands: s.commands,
                                       defaultCommandID: s.defaultCommandID,
                                       promptCommandID: s.promptCommandID)
        // bare "hey claude" (stripped to nil) → claude-code, no prompt
        let bare = registry.resolve(transcript: nil)
        c.assertEqual(bare?.command.id ?? "nil", "claude-code")
        c.assert(bare?.prompt == nil, "bare wake should carry no prompt")
        // "code <task>" → claude-code with the task as prompt
        let withTask = registry.resolve(transcript: "code refactor the auth module")
        c.assertEqual(withTask?.command.id ?? "nil", "claude-code")
        c.assertEqual(withTask?.prompt ?? "nil", "refactor the auth module")
        // freeform → claude-code with full text
        let freeform = registry.resolve(transcript: "what does this function do")
        c.assertEqual(freeform?.command.id ?? "nil", "claude-code")
        // no leftover desktop-app command
        c.assert(!s.commands.contains { $0.id == "claude-desktop" }, "claude-desktop should be gone")

        // Migration: a claude-code command persisted before `editorIntegration`
        // existed must be backfilled - else an editor target falls back to a
        // terminal. (The exact shape that shipped in users' settings.json.)
        let legacy = #"{"projectDirectory":"/tmp","preferredTarget":{"type":"editor","value":"Cursor"},"wakeKeywordsScore":2,"wakeKeywordsThreshold":0.25,"cooldownSeconds":2,"claudeExecutable":"claude","onboardingCompleted":true,"defaultCommandID":"claude-code","promptCommandID":"claude-code","commands":[{"acceptsPrompt":true,"id":"claude-code","kind":{"runCLI":{"commandTemplate":"claude {prompt}"}},"label":"Claude Code","triggers":["code"]}]}"#
        let migrated = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        let cc = migrated.commands.first { $0.id == "claude-code" }
        c.assert(cc?.editorIntegration == .claudeCode, "editorIntegration should be backfilled on migrated claude-code")
    }
}

// MARK: - Dispatch

func main() -> Int32 {
    setbuf(stdout, nil)  // unbuffered: see progress live even when piped
    let requested = CommandLine.arguments.dropFirst().first ?? "all"
    var allOK = true

    // Explicit, side-effecting live checks - never part of "all".
    if requested == "editor-open-live" {
        let editorArg = CommandLine.arguments.dropFirst(2).first ?? "Cursor"
        let editor = EditorKind(rawValue: editorArg) ?? .cursor
        return probeEditorOpenLive(editor) ? 0 : 1
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
    if requested == "bpe-keywords" {
        return probeBpeKeywords() ? 0 : 1
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
        maybe("default-route", probeDefaultRouting)
        maybe("editor-route", probeEditorRoute)
    }

    return allOK ? 0 : 1
}

exit(main())
