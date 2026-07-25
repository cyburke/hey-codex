@preconcurrency import AVFoundation

public enum AudioSamples {
    public enum Error: Swift.Error { case readFailed }

    /// Loads a WAV file as mono Float32 PCM resampled to 16 kHz.
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw Error.readFailed
        }
        let inBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuffer)

        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1
        let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)!

        // One-shot feed flag in a reference box: AVAudioConverter calls this
        // block synchronously, but a captured `var` trips the Sendable-closure
        // warning, so use a reference (matches AudioCapture).
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if once.consumed { status.pointee = .noDataNow; return nil }
            once.consumed = true; status.pointee = .haveData; return inBuffer
        }
        if let convError { throw convError }

        let ptr = outBuffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuffer.frameLength)))
    }

    /// Writes mono 16 kHz samples as a 16-bit WAV. Used only by the opt-in
    /// enrollment capture, so a failed enrollment can be replayed offline
    /// instead of asking someone to record it again and again.
    public static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                              AVSampleRateKey: 16000,
                                              AVNumberOfChannelsKey: 1,
                                              AVLinearPCMBitDepthKey: 16,
                                              AVLinearPCMIsFloatKey: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Root-mean-square level, on the same [-1, 1] scale `load` returns. The
    /// low-level signal enrollment needs: a phrase the model handles perfectly
    /// produces zero hits once its RMS is scaled down to real quiet-mic levels
    /// (measured on saved enrollment takes at RMS 0.005-0.009 against the KWS
    /// model's own reference audio at 0.047 - see AUDIT-2026-07-24.md P1.1).
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    /// Largest absolute sample value, on the same [-1, 1] scale.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// Boosts a quiet clip toward `targetRMS`, but never past `peakCeiling` on
    /// the loudest sample. RMS-matching alone was measured insufficient for one
    /// voice whose crest factor (peak/RMS ratio) differed from the reference -
    /// the boost needed to hit target RMS would have clipped its peaks, which
    /// distorts the waveform the KWS model actually sees rather than just
    /// scaling it. Only ever boosts (a clip already at or above target is
    /// returned unchanged) - normalization is a rescue for quiet input, not a
    /// general loudness leveler.
    public static func normalized(_ samples: [Float], targetRMS: Float, peakCeiling: Float) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let level = rms(samples)
        guard level > 0 else { return samples }
        var gain = targetRMS / level
        let loudest = peak(samples)
        if loudest > 0 {
            gain = min(gain, peakCeiling / loudest)
        }
        guard gain > 1 else { return samples }
        return samples.map { $0 * gain }
    }
}
