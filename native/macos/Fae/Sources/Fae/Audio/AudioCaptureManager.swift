import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine input tap, converting to
/// mono 16kHz Float32 in 576-sample chunks for the VAD/STT pipeline.
///
/// Replaces: `src/audio/capture.rs` (CpalCapture)
actor AudioCaptureManager {
    struct SegmentSpeechQuality: Sendable {
        let rms: Float
        let peak: Float
        let voicedFrameRatio: Float
        let voicedDurationSeconds: Double

        var hasUsableSpeech: Bool {
            // Require substantial voiced speech for reliable speaker embeddings.
            // WeSpeaker needs ~3s+ of speech for stable 256-dim embeddings.
            rms >= 0.01 && peak >= 0.05 && voicedFrameRatio >= 0.15 && voicedDurationSeconds >= 2.0
        }
    }

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
    /// Capture audio for enrollment. Uses the MAIN engine (no concurrency conflict)
    /// via a temporary tap diversion. Waits for speech to actually start before
    /// collecting, strips leading/trailing silence, and validates quality.
    ///
    /// - Parameters:
    ///   - durationSeconds: Maximum recording window (will stop early if enough speech captured).
    /// - Returns: Float32 samples at targetSampleRate with silence trimmed.
    func captureSegment(durationSeconds: Double) async throws -> [Float] {
        // Use a fresh engine to avoid interfering with the main capture pipeline.
        // The main engine tap stays running — enrollment uses a separate AVAudioEngine.
        let tempEngine = AVAudioEngine()
        let inputNode = tempEngine.inputNode
        configureVoiceProcessingIfAvailable(on: inputNode)
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

        // Collect MORE than needed — we'll trim silence afterward.
        let maxSamples = Int(Double(Self.targetSampleRate) * (durationSeconds + 6.0))
        let minSpeechSamples = Int(Double(Self.targetSampleRate) * 3.0) // At least 3s of speech for stable embeddings
        var collected = [Float]()
        collected.reserveCapacity(maxSamples)

        let nativeChunkSize = AVAudioFrameCount(
            Double(Self.chunkSize) * nativeFormat.sampleRate / Double(Self.targetSampleRate)
        )

        // Speech detection state — wait for speech to start before the timer runs.
        let speechRMSThreshold: Float = 0.015
        var speechDetected = false
        var speechStartIndex = 0
        var silenceAfterSpeechFrames = 0
        let silenceEndThreshold = Int(Double(Self.targetSampleRate) * 2.0) // 2s silence = end (TTS has natural pauses)

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

                // Compute chunk RMS for speech detection.
                var sumSq: Float = 0
                for s in chunk.samples { sumSq += s * s }
                let chunkRMS = (sumSq / max(Float(chunk.samples.count), 1)).squareRoot()

                if !speechDetected && chunkRMS >= speechRMSThreshold {
                    speechDetected = true
                    // Mark where speech started (with 200ms lookback for onset).
                    speechStartIndex = max(0, collected.count - chunk.samples.count - Self.targetSampleRate / 5)
                    NSLog("AudioCaptureManager: enrollment speech detected at %.2fs (rms=%.4f)",
                          Double(collected.count) / Double(Self.targetSampleRate), chunkRMS)
                }

                if speechDetected {
                    if chunkRMS < speechRMSThreshold {
                        silenceAfterSpeechFrames += chunk.samples.count
                    } else {
                        silenceAfterSpeechFrames = 0
                    }

                    // End capture when: enough speech + silence detected, or max time reached.
                    let speechSamples = collected.count - speechStartIndex - silenceAfterSpeechFrames
                    let done = (speechSamples >= minSpeechSamples && silenceAfterSpeechFrames >= silenceEndThreshold)
                        || collected.count >= maxSamples

                    if done {
                        finished = true
                        inputNode.removeTap(onBus: 0)
                        tempEngine.stop()

                        // Trim: extract from speech start to end of speech (before trailing silence).
                        let speechEnd = max(speechStartIndex + minSpeechSamples,
                                            collected.count - silenceAfterSpeechFrames)
                        let trimmed = Array(collected[speechStartIndex..<min(speechEnd, collected.count)])
                        NSLog("AudioCaptureManager: enrollment captured %.2fs raw → %.2fs trimmed (%d samples)",
                              Double(collected.count) / Double(Self.targetSampleRate),
                              Double(trimmed.count) / Double(Self.targetSampleRate),
                              trimmed.count)
                        cont.resume(returning: trimmed)
                    }
                }

                // Timeout: max recording time even if no speech detected.
                if collected.count >= maxSamples && !finished {
                    finished = true
                    inputNode.removeTap(onBus: 0)
                    tempEngine.stop()
                    // Return whatever we have, trimming leading silence if possible.
                    let result = speechDetected
                        ? Array(collected[speechStartIndex...])
                        : Array(collected.suffix(Int(Double(Self.targetSampleRate) * durationSeconds)))
                    cont.resume(returning: result)
                }
            }

            do {
                // Pause main capture while temp engine uses the mic.
                let mainWasCapturing = self.isCapturing
                if mainWasCapturing {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    NSLog("AudioCaptureManager: paused main capture for enrollment")
                }

                try tempEngine.start()
                self.logMicrophoneModeDiagnosticsIfAvailable()

                // After temp engine finishes (continuation resumes),
                // restart the main engine. Schedule on this actor.
                Task { [weak self] in
                    // Wait for the continuation to complete.
                    while !finished {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard let self, mainWasCapturing else { return }
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms settle
                    await self.restartMainCaptureAfterEnrollment()
                }
            } catch {
                finished = true
                cont.resume(throwing: error)
            }
        }
    }

    /// Restart the main capture engine after enrollment stole the mic.
    private func restartMainCaptureAfterEnrollment() {
        guard !isCapturing else { return }
        NSLog("AudioCaptureManager: restarting main capture after enrollment")

        let inputNode = engine.inputNode
        configureVoiceProcessingIfAvailable(on: inputNode)
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let nativeChunkSize = AVAudioFrameCount(
            Double(Self.chunkSize) * nativeFormat.sampleRate / Double(Self.targetSampleRate)
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            NSLog("AudioCaptureManager: failed to create target format for restart")
            return
        }

        let converter: AVAudioConverter?
        if nativeFormat.sampleRate != Double(Self.targetSampleRate) || nativeFormat.channelCount != 1 {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: nativeChunkSize, format: nativeFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

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

            self.continuation?.yield(chunk)
        }

        do {
            try engine.start()
            isCapturing = true
            NSLog("AudioCaptureManager: main capture restarted successfully")
        } catch {
            NSLog("AudioCaptureManager: main capture restart failed: %@", error.localizedDescription)
        }
    }

    static func analyzeSegment(_ samples: [Float], sampleRate: Int = targetSampleRate) -> SegmentSpeechQuality {
        guard !samples.isEmpty else {
            return SegmentSpeechQuality(rms: 0, peak: 0, voicedFrameRatio: 0, voicedDurationSeconds: 0)
        }

        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = (sumSquares / Float(samples.count)).squareRoot()

        let frameSize = max(sampleRate / 50, 160) // ~20 ms
        let hopSize = max(frameSize / 2, 80) // ~10 ms
        let voicedThreshold = max(0.02, rms * 0.6)

        var frameCount = 0
        var voicedFrames = 0
        var offset = 0
        while offset + frameSize <= samples.count {
            var frameSumSquares: Float = 0
            for idx in offset..<(offset + frameSize) {
                let sample = samples[idx]
                frameSumSquares += sample * sample
            }
            let frameRMS = (frameSumSquares / Float(frameSize)).squareRoot()
            frameCount += 1
            if frameRMS >= voicedThreshold {
                voicedFrames += 1
            }
            offset += hopSize
        }

        let voicedFrameRatio: Float
        let voicedDurationSeconds: Double
        if frameCount > 0 {
            voicedFrameRatio = Float(voicedFrames) / Float(frameCount)
            voicedDurationSeconds = Double(voicedFrames * hopSize) / Double(sampleRate)
        } else {
            voicedFrameRatio = 0
            voicedDurationSeconds = 0
        }

        return SegmentSpeechQuality(
            rms: rms,
            peak: peak,
            voicedFrameRatio: voicedFrameRatio,
            voicedDurationSeconds: voicedDurationSeconds
        )
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
