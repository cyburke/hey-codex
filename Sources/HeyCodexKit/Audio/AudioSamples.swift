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
}
