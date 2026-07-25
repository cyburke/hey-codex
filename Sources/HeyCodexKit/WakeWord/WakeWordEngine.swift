import Foundation
import CSherpaOnnx

/// Wraps the sherpa-onnx online keyword spotter for the "hey codex" wake word.
public final class WakeWordEngine {
    /// `guard let engine = try? WakeWordEngine(...)` at call sites throws away
    /// the specific case, but `LocalizedError` means whichever file was missing
    /// still survives into any `error.localizedDescription` those call sites
    /// already show the user, instead of every distinct failure collapsing into
    /// the same generic message (AUDIT-2026-07-24.md P1.5).
    public enum Error: Swift.Error, LocalizedError {
        case missingModelFile(String)

        public var errorDescription: String? {
            switch self {
            case .missingModelFile(let name): return "Missing wake-word model file: \(name)"
            }
        }
    }

    private let spotter: SherpaOnnxKeywordSpotterWrapper

    /// The keyword text `getResult()` reported on the most recent fire, before
    /// `reset()` clears it. Diagnostic only - lets a multi-keyword sweep (see
    /// `probeTuning`) report which armed phrase actually fired on a false
    /// alarm, instead of just that one of several did.
    public private(set) var lastFiredKeyword: String?

    /// - Parameters:
    ///   - modelDir: directory of the KWS zipformer model (encoder/decoder/joiner + tokens.txt).
    ///   - keywordsFile: tokenized keywords file containing the "hey codex" entry.
    ///   - keywordsThreshold: per-keyword trigger gate. Lower fires more eagerly.
    ///   - keywordsScore: per-keyword boost added to keyword-path hypotheses
    ///     during the modified beam search — it keeps the keyword path alive in
    ///     the beam when acoustic evidence is weak. This is the primary lever for
    ///     spotting a hard wake word on a small model; see `KeywordTuning.score`
    ///     for the calibrated value and why it is 1.25, not the library's 1.0
    ///     (TUNING-2026-07-25.md has the measurement).
    ///   - maxActivePaths: beam width for the keyword spotter's modified search.
    ///   - numTrailingBlanks: blank frames required after the keyword before it
    ///     is finalised. Higher makes it wait for a pause, which cuts false
    ///     triggers mid-sentence at the cost of a little latency.
    public init(modelDir: URL, keywordsFile: URL,
                keywordsThreshold: Float = KeywordTuning.threshold,
                keywordsScore: Float = KeywordTuning.score,
                maxActivePaths: Int = KeywordTuning.maxActivePaths,
                numTrailingBlanks: Int = KeywordTuning.numTrailingBlanks) throws {
        func path(_ name: String) throws -> String {
            let u = modelDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else {
                // `guard let engine = try? WakeWordEngine(...)` at every call site
                // collapses every distinct missing file into one generic failure -
                // log the specific name here so it survives that, in Console.app
                // even when nobody kept the thrown error (AUDIT-2026-07-24.md P1.5).
                Log.audio.error("WakeWordEngine: missing model file \(name, privacy: .public) in \(modelDir.path, privacy: .public)")
                throw Error.missingModelFile(name)
            }
            return u.path
        }
        // Filenames match the gigaspeech KWS release (verified against the
        // downloaded Models/ directory).
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: try path("encoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            decoder: try path("decoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            joiner:  try path("joiner-epoch-12-avg-2-chunk-16-left-64.onnx"))
        // KeywordTokenizer pre-tokenizes every keyword (e.g. "▁HE Y ▁CO DE X")
        // before it ever reaches sherpa, so sherpa never has to tokenize raw text
        // itself here and modeling_unit/bpe_vocab make no difference to what
        // fires: measured by feeding the model's own reference audio and three
        // real enrollment takes through both settings across the full threshold
        // sweep and diffing the results - identical in every case (AUDIT-2026-07-24.md
        // P1.4). Left at the library's "cjkchar" default; a `bpe.model` file is
        // deliberately not shipped (see scripts/bundle-app.sh) so this also matches
        // what every built app actually runs.
        if ProcessInfo.processInfo.environment["HEYCODEX_KWS_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[swift] unit=cjkchar bpe=<unused>\n".utf8))
        }
        let model = sherpaOnnxOnlineModelConfig(
            tokens: try path("tokens.txt"),
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: ProcessInfo.processInfo.environment["HEYCODEX_KWS_DEBUG"] == "1" ? 1 : 0)
        let feat = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxKeywordSpotterConfig(
            featConfig: feat,
            modelConfig: model,
            keywordsFile: keywordsFile.path,
            maxActivePaths: maxActivePaths,
            numTrailingBlanks: numTrailingBlanks,
            keywordsScore: keywordsScore,
            keywordsThreshold: keywordsThreshold)
        self.spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
    }

    /// Feeds a full buffer of 16 kHz mono samples and returns whether the keyword fired.
    ///
    /// The vendored `SherpaOnnxKeywordSpotterWrapper` owns a single internal,
    /// stateful stream (no `createStream()` and no per-call stream argument),
    /// so we drive that stream and `reset()` it before returning so the engine
    /// can be reused for a subsequent buffer.
    public func detects(in samples: [Float]) -> Bool {
        spotter.acceptWaveform(samples: samples, sampleRate: 16000)
        // Tail pad so the streaming zipformer (chunk-16) flushes its final
        // partial chunk. Short wake clips (~0.7s) emit too few frames otherwise:
        // 0.2s of pad gave only ~2 decode steps and never tripped the keyword;
        // 1s reliably flushes the last tokens.
        spotter.acceptWaveform(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000)
        spotter.inputFinished()
        while spotter.isReady() {
            spotter.decode()
            let result = spotter.getResult()
            if !result.keyword.isEmpty {
                lastFiredKeyword = result.keyword
                spotter.reset()
                return true
            }
        }
        spotter.reset()
        return false
    }

    /// Continuous-streaming feed for the live mic loop.
    ///
    /// Feeds one frame of 16 kHz mono samples into the persistent stream and
    /// drains the decoder. Unlike `detects(in:)`, this does NOT call
    /// `inputFinished()` — the stream stays alive across calls so the next
    /// frame continues the same utterance. Returns `true` and `reset()`s the
    /// stream's decoding state on a fire (so the next call starts fresh);
    /// returns `false` otherwise, leaving the stream ready for more frames.
    public func feed(_ samples: [Float]) -> Bool {
        spotter.acceptWaveform(samples: samples, sampleRate: 16000)
        while spotter.isReady() {
            spotter.decode()
            let result = spotter.getResult()
            if !result.keyword.isEmpty {
                lastFiredKeyword = result.keyword
                spotter.reset()
                return true
            }
        }
        return false
    }

    /// Discards an in-progress utterance without producing a result. Used when
    /// a repeated launch phrase takes priority over the close detector.
    public func reset() { spotter.reset() }
}
