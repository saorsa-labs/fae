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
        configureVoiceProcessingIfAvailable(on: inputNode)
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
        logMicrophoneModeDiagnosticsIfAvailable()

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

    /// Record a fixed-length audio segment and return the raw samples.
    ///
    /// Used for on-demand recording during speaker enrollment (not the streaming pipeline).
    /// Creates a temporary audio engine that records for the specified duration.
    func captureSegment(durationSeconds: Double) async throws -> [Float] {
        let tempEngine = AVAudioEngine()
        let inputNode = tempEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioCaptureManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target format for segment capture"]
            )
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != Double(Self.targetSampleRate) || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }

        let totalSamples = Int(Double(Self.targetSampleRate) * durationSeconds)
        var collected = [Float]()
        collected.reserveCapacity(totalSamples)

        let nativeChunkSize = AVAudioFrameCount(
            Double(Self.chunkSize) * nativeFormat.sampleRate / Double(Self.targetSampleRate)
        )

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Float], Error>) in
            var finished = false

            inputNode.installTap(onBus: 0, bufferSize: nativeChunkSize, format: nativeFormat) {
                buffer, _ in
                guard !finished else { return }

                let chunk: AudioChunk
                if let conv = converter {
                    let frameCapacity = AVAudioFrameCount(
                        Double(buffer.frameLength) * Double(Self.targetSampleRate)
                            / buffer.format.sampleRate
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
                    guard error == nil else { return }
                    chunk = Self.extractChunk(from: converted)
                } else {
                    chunk = Self.extractChunk(from: buffer)
                }

                collected.append(contentsOf: chunk.samples)

                if collected.count >= totalSamples {
                    finished = true
                    inputNode.removeTap(onBus: 0)
                    tempEngine.stop()
                    let result = Array(collected.prefix(totalSamples))
                    cont.resume(returning: result)
                }
            }

            do {
                try tempEngine.start()
            } catch {
                finished = true
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Private

    private func configureVoiceProcessingIfAvailable(on inputNode: AVAudioInputNode) {
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingBypassed = false
            inputNode.isVoiceProcessingAGCEnabled = true
            NSLog("AudioCaptureManager: voice processing enabled on input node")
        } catch {
            NSLog("AudioCaptureManager: voice processing unavailable (%@)", error.localizedDescription)
        }
    }

    private func logMicrophoneModeDiagnosticsIfAvailable() {
        if #available(macOS 12.0, *) {
            let active = AVCaptureDevice.activeMicrophoneMode
            let preferred = AVCaptureDevice.preferredMicrophoneMode
            NSLog(
                "AudioCaptureManager: microphone mode active=%@ preferred=%@",
                Self.microphoneModeLabel(active),
                Self.microphoneModeLabel(preferred)
            )
            if active != .voiceIsolation {
                NSLog("AudioCaptureManager: tip — switch to Voice Isolation in Control Center for cleaner speech capture")
            }
        }
    }

    private static func microphoneModeLabel(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard:
            return "standard"
        case .wideSpectrum:
            return "wide_spectrum"
        case .voiceIsolation:
            return "voice_isolation"
        @unknown default:
            return "unknown"
        }
    }

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
