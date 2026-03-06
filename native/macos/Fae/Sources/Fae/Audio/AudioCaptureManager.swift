import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine input tap, converting to
/// mono 16kHz Float32 in 576-sample chunks for the VAD/STT pipeline.
///
/// Replaces: `src/audio/capture.rs` (CpalCapture)
actor AudioCaptureManager {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isCapturing = false

    /// Target sample rate for pipeline processing.
    static let targetSampleRate: Int = 16_000
    /// Chunk size in samples at target rate (36ms per chunk) to match Silero VAD.
    static let chunkSize: Int = 576

    // MARK: - Software Noise Gate

    /// RMS threshold below which audio chunks are zeroed out before reaching VAD.
    /// This acts as a software substitute for macOS Voice Isolation when the system
    /// keeps reverting to "standard" mic mode. Chunks quieter than this floor are
    /// treated as silence, preventing ambient noise from reaching the neural VAD.
    /// This remains an RMS floor, not the Silero speech-probability threshold.
    var noiseGateThreshold: Float = 0.008

    /// When true, all incoming audio chunks are silenced before reaching the pipeline.
    /// Set by PipelineCoordinator when the user toggles the mic button off.
    var isMuted: Bool = false

    // MARK: - Public API

    /// Mute or unmute the microphone. When muted, incoming audio chunks are
    /// silently dropped before reaching the VAD/STT pipeline.
    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    /// Returns an AsyncStream of 576-sample mono Float32 chunks at 16kHz.
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

    /// Configure voice processing on the input node.
    ///
    /// Voice Processing (VP) creates a Telephony-mode aggregate audio unit with
    /// echo cancellation that requires a reference signal from the same engine.
    /// Fae uses separate AVAudioEngine instances for capture and playback, so VP
    /// never receives a reference signal — its echo canceller operates with a
    /// silent reference, which can cause it to gate or suppress real mic input.
    ///
    /// Additionally, macOS Voice Isolation (Neural Engine) already handles noise
    /// suppression at the system level, and Fae's EchoSuppressor handles time-based
    /// + text-overlap echo filtering. VP is therefore disabled to avoid:
    /// - Signal attenuation below VAD threshold (0.008 RMS)
    /// - Conflict with macOS Voice Isolation
    /// - HALC_ProxyIOContext errors from aggregate device contention
    private func configureVoiceProcessingIfAvailable(on inputNode: AVAudioInputNode) {
        // VP intentionally disabled — see doc comment above.
        // If VP was previously enabled on this engine, disable it to avoid
        // stale aggregate device state.
        do {
            if inputNode.isVoiceProcessingEnabled {
                try inputNode.setVoiceProcessingEnabled(false)
                NSLog("AudioCaptureManager: disabled stale voice processing")
            }
        } catch {
            // Ignore — just means VP wasn't enabled.
        }
        NSLog("AudioCaptureManager: voice processing disabled (relying on system Voice Isolation + EchoSuppressor)")
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
        // Hard mute: mic button toggled off — drop chunk entirely (don't even
        // send silence, so the VAD/STT pipeline stays completely idle).
        if isMuted {
            return
        }
        // Software noise gate: zero out chunks below the noise floor.
        // This prevents low-level ambient noise from reaching VAD when macOS
        // Voice Isolation is not active (system keeps reverting to "standard").
        if noiseGateThreshold > 0, !chunk.samples.isEmpty {
            var sumSquares: Float = 0
            for s in chunk.samples { sumSquares += s * s }
            let rms = (sumSquares / Float(chunk.samples.count)).squareRoot()
            if rms < noiseGateThreshold {
                // Below noise floor — emit silent chunk to keep timing intact.
                let silent = AudioChunk(
                    samples: [Float](repeating: 0, count: chunk.samples.count),
                    sampleRate: chunk.sampleRate
                )
                continuation?.yield(silent)
                return
            }
        }
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
