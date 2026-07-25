import Foundation

/// The recordings captured during wake-phrase enrollment, and the one judgement
/// made about each as it arrives.
///
/// This type used to derive the keyword itself from the tokens the model decoded
/// out of each recording, on the theory that a keyword built from dictionary
/// spelling only partially matches a given voice. That was measured and is wrong:
/// a decode of "Hey Xena" as `▁A Z EN A` fires on none of the three takes it came
/// from, at any threshold, while the phrase's own spelling fires for nearly every
/// phrase the model knows. Keyword construction now lives in `KeywordTokenizer`,
/// the go/no-go for a phrase in `WakePhraseFitness`, and sensitivity tuning in
/// `WakeCalibration`.
public struct WakeEnrollment {
    /// One captured recording.
    public struct Sample: Sendable {
        public enum Kind: Sendable { case isolated, natural }
        public let audio: [Float]
        public let kind: Kind
        public init(audio: [Float], kind: Kind) { self.audio = audio; self.kind = kind }
    }

    /// Render decode tokens (e.g. `[" HE","Y"," C","LO","U","D"]`) as a keyword
    /// file line. Kept for the diagnostics log, which records what the model heard
    /// so a rejected enrollment can be explained afterwards.
    public static func keywordLine(from tokens: [String]) -> String {
        tokens.compactMap { tok -> String? in
            let boundary = tok.hasPrefix(" ")
            let t = tok.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return boundary ? "\u{2581}" + t : t
        }.joined(separator: " ")
    }

    /// A phrase-agnostic gate for rejecting empty or one-token glitch captures, so
    /// a recording that caught nothing is retaken rather than counted.
    public static func isPlausibleWake(tokens: [String]) -> Bool {
        let line = keywordLine(from: tokens)
        let pieces = line.split(separator: " ")
        return pieces.count >= 2 && line.contains("\u{2581}")
    }
}
