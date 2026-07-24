@preconcurrency import AVFoundation
import Foundation

/// Live microphone capture, delivering 16 kHz mono Float frames on a serial queue.
///
/// Deliberately built on `AVCaptureSession` rather than `AVAudioEngine`.
///
/// `AVAudioEngine` on macOS runs one I/O unit spanning the default input *and*
/// the default output device, and merely installing an input tap makes CoreAudio
/// fabricate a private aggregate device covering both. Measured on a Mac whose
/// monitor provides input and output through a single USB device:
///
///     AVAudioEngine:     devices 5 -> 6
///                        NEW: CADefaultDeviceAggregate  in:2 out:2  IO-RUNNING
///     AVCaptureSession:  devices 5 -> 5
///                        CHANGED: the microphone only,  in:2 out:0  IO-RUNNING
///
/// An always-listening menu bar app must not drag the user's speakers into a
/// synthetic aggregate device just to hear a wake word. Capture is input only.
///
/// `@unchecked Sendable`: mutable state lives on the capture queue, which is also
/// the delivery queue.
public final class AudioCapture: @unchecked Sendable {
    public enum CaptureError: Swift.Error {
        case noInputDevice
        case sessionRejectedInput
        case sessionRejectedOutput
    }

    /// Sample rate the wake-word engine expects.
    public static let sampleRate = 16000.0

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.heycodex.audiocapture")
    private let delegate: SampleDelegate

    /// onFrame is invoked on a private serial queue with 16 kHz mono samples.
    /// `device` defaults to the system input; being able to name one explicitly
    /// keeps a future device picker from having to touch anything else.
    public init(device: AVCaptureDevice? = nil, onFrame: @escaping ([Float]) -> Void) throws {
        guard let device = device ?? AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noInputDevice
        }
        self.delegate = SampleDelegate(onFrame: onFrame)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.sessionRejectedInput }
        session.addInput(input)

        // macOS lets the capture output convert for us, so there is no manual
        // resampling step and no AVAudioConverter to keep in step with whatever
        // format the device happens to be in.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.sessionRejectedOutput }
        session.addOutput(output)
    }

    public func start() throws {
        guard !session.isRunning else { return }
        delegate.setMuted(false)
        session.startRunning()
    }

    public func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    /// Mute **releases the microphone at the OS level** rather than dropping
    /// frames: stopping the session tears the input stream down, so the orange
    /// recording indicator goes out and other apps can take the device.
    ///
    /// Returns the resulting live state (`true` = capturing). A session that
    /// fails to restart reports `false`, so the caller never claims a live
    /// microphone the OS did not grant.
    @discardableResult
    public func setMuted(_ value: Bool) -> Bool {
        if value {
            delegate.setMuted(true)
            stop()
            return false
        }
        delegate.setMuted(false)
        session.startRunning()
        return session.isRunning
    }

    /// Receives capture buffers and turns them into plain sample arrays.
    private final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private let onFrame: ([Float]) -> Void
        private var muted = false

        init(onFrame: @escaping ([Float]) -> Void) { self.onFrame = onFrame }

        /// Set from the main actor but read on the capture queue. A stale read
        /// only costs one extra frame, which the caller already tolerates.
        func setMuted(_ value: Bool) { muted = value }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !muted else { return }
            let samples = Self.floatSamples(from: sampleBuffer)
            guard !samples.isEmpty else { return }
            onFrame(samples)
        }

        /// Copy the buffer's Float32 samples out. The block buffer is retained for
        /// the call and released on return, so no memory escapes the delegate.
        static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
            var list = AudioBufferList()
            var block: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &block)
            guard status == noErr, block != nil else { return [] }
            var samples: [Float] = []
            for buffer in UnsafeMutableAudioBufferListPointer(&list) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self), count: count))
            }
            return samples
        }
    }
}
