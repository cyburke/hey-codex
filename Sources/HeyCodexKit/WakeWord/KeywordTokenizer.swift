import CBpe
import Foundation

/// Turns a phrase into the token sequence the keyword spotter expects.
///
/// The keyword file must contain the phrase encoded with the model's own BPE
/// vocabulary, and this uses the same encoder sherpa-onnx uses (`ssentencepiece`,
/// already compiled into the static library we link) rather than reimplementing
/// it. `sherpa-onnx-cli text2token` is the documented offline equivalent, and the
/// keyword spotter's own C API has no field for tokenising text itself, so the
/// caller has to do it.
///
/// Two earlier approaches were wrong and are worth naming. Deriving tokens from
/// what the model *decoded* out of a recording produces keywords that fire on
/// nothing, not even the recording they came from. And a hand-written
/// longest-match split, which this replaces, silently disagreed with real BPE:
/// "hey siri" encoded as `▁S IR I` where sentencepiece gives `▁S I RI`. Greedy
/// matching is not what BPE does, so it was right often enough to look correct and
/// wrong often enough to break phrases for no visible reason.
public enum KeywordTokenizer {
    /// Word boundary marker used by sentencepiece vocabularies.
    public static let boundary = "\u{2581}"

    /// Filename of the text vocabulary inside a model directory, produced from the
    /// model's `bpe.model` by `scripts/make-bpe-vocab.py`.
    public static let vocabFileName = "bpe.vocab"

    /// Tokenise a phrase against a model directory, or nil if it cannot be encoded.
    public static func tokenize(_ phrase: String, modelDir: URL) -> String? {
        let cleaned = normalize(phrase)
        guard !cleaned.isEmpty else { return nil }
        let vocab = modelDir.appendingPathComponent(vocabFileName)
        guard FileManager.default.fileExists(atPath: vocab.path) else { return nil }
        guard let raw = hc_bpe_encode(vocab.path, cleaned) else { return nil }
        defer { hc_bpe_free(raw) }
        let tokens = String(cString: raw)
        return tokens.isEmpty ? nil : tokens
    }

    /// Upper-cased words only. The vocabulary is upper case and has no pieces for
    /// punctuation, so "Hey, Codex!" and "hey codex" must encode identically.
    public static func normalize(_ phrase: String) -> String {
        phrase.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
