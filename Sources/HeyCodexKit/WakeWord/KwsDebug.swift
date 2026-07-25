import Foundation
import CSherpaOnnx

/// Diagnostic helper: drives the KWS model's encoder/decoder/joiner as a plain
/// online transducer recognizer to reveal the literal tokens the model emits
/// for a given clip. Used to calibrate the wake-word keyword tokenization
/// against what the model actually hears (not dictionary BPE). Not used in the
/// detection path.
public enum KwsDebug {
    public static func decodeTokens(modelDir: URL, samples: [Float]) -> (text: String, tokens: [String]) {
        func path(_ n: String) -> String { modelDir.appendingPathComponent(n).path }
        // The C++ wrapper force-unwraps a failed recognizer allocation. Keep
        // malformed resource paths in Swift so an optional calibration feature
        // can report an unusable sample instead of terminating the whole app.
        let required = [
            "encoder-epoch-12-avg-2-chunk-16-left-64.onnx",
            "decoder-epoch-12-avg-2-chunk-16-left-64.onnx",
            "joiner-epoch-12-avg-2-chunk-16-left-64.onnx",
            "tokens.txt",
        ]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: path($0)) }) else {
            return ("", [])
        }
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: path("encoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            decoder: path("decoder-epoch-12-avg-2-chunk-16-left-64.onnx"),
            joiner:  path("joiner-epoch-12-avg-2-chunk-16-left-64.onnx"))
        let model = sherpaOnnxOnlineModelConfig(
            tokens: path("tokens.txt"), transducer: transducer, numThreads: 1, provider: "cpu")
        let feat = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var cfg = sherpaOnnxOnlineRecognizerConfig(
            featConfig: feat, modelConfig: model, decodingMethod: "greedy_search")
        let rec = SherpaOnnxRecognizer(config: &cfg)
        rec.acceptWaveform(samples: samples)
        // Same tail flush as WakeWordEngine.detects: this streaming zipformer needs
        // a full second of pad plus inputFinished to emit its last chunk. With 0.3s
        // and no inputFinished, every decode lost its final token — "hey jarvis"
        // came back as "HEY JARVI" — which reads as a mispronunciation rather than
        // a truncation and sent one diagnosis down the wrong path entirely.
        rec.acceptWaveform(samples: [Float](repeating: 0, count: 16000))
        rec.inputFinished()
        while rec.isReady() { rec.decode() }
        let r = rec.getResult()
        return (r.text, r.tokens)
    }
}
