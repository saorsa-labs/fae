import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine input tap, converting to
/// mono 16kHz Float32 in 512-sample chunks for the VAD/STT pipeline.
///
/// Replaces: `src/audio/capture.rs` (CpalCapture)
actor AudioCaptureManager {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isCapturing = false

    /// Target sample rate for pipeline processing.
    static let targetSampleRate: Int = 16_000
    /// Chunk size in samples at target rate (32ms per chunk).
    static let chunkSize: Int = 512

    // MARK: - Public API

    /// Returns an AsyncStream of 512-sample mono Float32 chunks at 16kHz.
    func startCapture() throws -> AsyncStream<AudioChunk> {
        guard !isCapturing else {
            return AsyncStream { $0.finish() }
        }

        let stream = AsyncStream<AudioChunk> { continuation in
            self.continuation = continuation
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Use native format for the tap to avoid format mismatch crashes,
        // then downsample to 16kHz mono in the tap callback.
        let converter: AVAudioConverter?
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioCaptureManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct target audio format"]
            )
        }

        if nativeFormat.sampleRate != Double(Self.targetSampleRate)
            || nativeFormat.channelCount != 1
        {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }

        // Tap at native format — convert in callback to avoid AVAudioEngine crash.
        let nativeChunkSize = AVAudioFrameCount(
            Double(Self.chunkSize) * nativeFormat.sampleRate / Double(Self.targetSampleRate)
        )
        inputNode.installTap(onBus: 0, bufferSize: nativeChunkSize, format: nativeFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            if let conv = converter {
                // Convert to mono 16kHz.
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * Double(Self.targetSampleRate) / buffer.format.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }
                var error: NSError?
                conv.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil {
                    let chunk = Self.extractChunk(from: converted)
                    Task { await self.emitChunk(chunk) }
                }
            } else {
                let chunk = Self.extractChunk(from: buffer)
                Task { await self.emitChunk(chunk) }
            }
        }

        try engine.start()
        isCapturing = true
        NSLog("AudioCaptureManager: started capture at %d Hz (native: %.0f Hz, %d ch)",
              Self.targetSampleRate, nativeFormat.sampleRate, nativeFormat.channelCount)

        return stream
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        isCapturing = false
        NSLog("AudioCaptureManager: stopped")
    }

    // MARK: - Private

    private func emitChunk(_ chunk: AudioChunk) {
        continuation?.yield(chunk)
    }

    private static func extractChunk(from buffer: AVAudioPCMBuffer) -> AudioChunk {
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else {
            return AudioChunk(samples: [], sampleRate: targetSampleRate)
        }
        // Channel 0 is mono (format requested mono).
        let ptr = channelData[0]
        let samples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
        return AudioChunk(samples: samples, sampleRate: targetSampleRate)
    }
}
