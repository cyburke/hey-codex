import Foundation
import CSherpaOnnx

/// Wraps the sherpa-onnx online keyword spotter for the "hey codex" wake word.
public final class WakeWordEngine {
    public enum Error: Swift.Error { case missingModelFile(String) }

    private let spotter: SherpaOnnxKeywordSpotterWrapper

    /// - Parameters:
    ///   - modelDir: directory of the KWS zipformer model (encoder/decoder/joiner + tokens.txt).
    ///   - keywordsFile: tokenized keywords file containing the "hey codex" entry.
    ///   - keywordsThreshold: per-keyword trigger gate. Lower fires more eagerly.
    ///   - keywordsScore: per-keyword boost added to keyword-path hypotheses
    ///     during the modified beam search — it keeps the keyword path alive in
    ///     the beam when acoustic evidence is weak. This is the primary lever for
    ///     spotting a hard wake word on a small model; see
    ///     internal design notes for the calibrated value.
    ///   - maxActivePaths: beam width for the keyword spotter's modified search.
    ///   - numTrailingBlanks: blank frames required after the keyword before it
    ///     is finalised. Higher makes it wait for a pause, which cuts false
    ///     triggers mid-sentence at the cost of a little latency.
    ///   - modelingUnit: how sherpa interprets the keywords file. With "bpe" and
    ///     a `bpeVocab`, keywords may be written as plain text and sherpa
    ///     tokenises them canonically. Left at the library's "cjkchar" default
    ///     this model was being handed Chinese-character rules for English text.
    public init(modelDir: URL, keywordsFile: URL,
                keywordsThreshold: Float = KeywordTuning.threshold,
                keywordsScore: Float = KeywordTuning.score,
                maxActivePaths: Int = KeywordTuning.maxActivePaths,
                numTrailingBlanks: Int = KeywordTuning.numTrailingBlanks,
                modelingUnit: String = KeywordTuning.modelingUnit,
                bpeVocabFile: String? = nil) throws {
        func path(_ name: String) throws -> String {
            let u = modelDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else { throw Error.missingModelFile(name) }
            return u.path
        }
        // Filenames match the gigaspeech KWS release (verified against the
        // downloaded Models/ directory).
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: try path("encoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            decoder: try path("decoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            joiner:  try path("joiner-epoch-12-avg-2-chunk-16-left-64.onnx"))
        // The BPE vocabulary is what lets a plain-text keyword be tokenised the
        // same way the model was trained, instead of us guessing token splits.
        let bpe = bpeVocabFile ?? (FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent(KeywordTuning.bpeVocabName).path)
            ? modelDir.appendingPathComponent(KeywordTuning.bpeVocabName).path : "")
        if ProcessInfo.processInfo.environment["HEYCODEX_KWS_DEBUG"] == "1" {
            let unit = bpe.isEmpty ? "cjkchar" : modelingUnit
            let shown = bpe.isEmpty ? "<empty>" : bpe
            FileHandle.standardError.write(Data("[swift] unit=\(unit) bpe=\(shown)\n".utf8))
        }
        let model = sherpaOnnxOnlineModelConfig(
            tokens: try path("tokens.txt"),
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: ProcessInfo.processInfo.environment["HEYCODEX_KWS_DEBUG"] == "1" ? 1 : 0,
            modelingUnit: bpe.isEmpty ? "cjkchar" : modelingUnit,
            bpeVocab: bpe)
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
        // 1s reliably flushes the last tokens. See docs tuning log.
        spotter.acceptWaveform(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000)
        spotter.inputFinished()
        while spotter.isReady() {
            spotter.decode()
            if !spotter.getResult().keyword.isEmpty {
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
            if !spotter.getResult().keyword.isEmpty {
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
