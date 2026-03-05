@preconcurrency import AVFoundation
import Foundation

/// Plays synthesized audio through the system output device.
///
/// Maintains a persistent AVAudioEngine + player node. Audio buffers are
/// enqueued sequentially; `stop()` interrupts immediately. Emits audio
/// level updates for orb mouth animation.
///
/// Replaces: `src/audio/playback.rs` (CpalPlayback)
actor AudioPlaybackManager {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var graphConfigured = false
    private var graphConfigurationCount = 0
    private var isPlaying = false
    private var pendingFinal = false
    /// Number of scheduled buffers that have not yet fired completion callbacks.
    private var pendingBufferCompletions = 0

    /// Default TTS output sample rate.
    static let ttsSampleRate: Double = 24_000

    /// Playback speed multiplier (0.8-1.4). Adjusts resample ratio.
    private var speed: Float = 1.0

    /// Cache AVAudioConverters by source/destination sample-rate pair.
    private var converterCache: [String: AVAudioConverter] = [:]

    /// Set the playback speed multiplier. Clamped to [0.8, 1.4].
    func setSpeed(_ newSpeed: Float) {
        speed = min(max(newSpeed, 0.8), 1.4)
    }

    /// Callback for playback events.
    private var onEvent: ((PlaybackEvent) -> Void)?

    /// Set the playback event handler.
    func setEventHandler(_ handler: @escaping @Sendable (PlaybackEvent) -> Void) {
        onEvent = handler
    }

    enum PlaybackEvent: Sendable {
        case finished
        case stopped
        case level(rms: Float)
    }

    // MARK: - Lifecycle

    func setup() throws {
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        if !graphConfigured {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
            graphConfigured = true
            graphConfigurationCount += 1
        }
        if !engine.isRunning {
            try engine.start()
        }
        NSLog("AudioPlaybackManager: engine started (output: %.0f Hz)", outputFormat.sampleRate)
    }

    var debugGraphConfigurationCount: Int { graphConfigurationCount }

    // MARK: - Enqueue Audio

    /// Enqueue synthesized audio samples for playback.
    ///
    /// - Parameters:
    ///   - samples: Mono Float32 PCM at `sampleRate`.
    ///   - sampleRate: Source sample rate (typically 24kHz from TTS).
    ///   - isFinal: Whether this is the last chunk in the current utterance.
    func enqueue(samples: [Float], sampleRate: Int, isFinal: Bool) {
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let outputRate = outputFormat.sampleRate

        // Apply speed: treat source rate as higher to speed up, lower to slow down.
        // This changes pitch proportionally — acceptable for voice speed adjustment.
        let effectiveSourceRate = Double(sampleRate) * Double(speed)

        // Resample if effective source rate differs from output device rate.
        let resampled: [Float]
        if effectiveSourceRate != outputRate {
            resampled = avAudioConvertResample(samples, from: effectiveSourceRate, to: outputRate)
        } else {
            resampled = samples
        }

        guard !resampled.isEmpty else { return }

        // Create PCM buffer in the output format.
        let frameCount = AVAudioFrameCount(resampled.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCount
        ) else { return }
        buffer.frameLength = frameCount

        // Fill buffer — duplicate mono to all output channels.
        guard fillPCMBuffer(buffer, withMono: resampled) else {
            NSLog("AudioPlaybackManager: failed to populate PCM buffer for output format")
            return
        }

        if isFinal {
            pendingFinal = true
        }

        pendingBufferCompletions += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { await self?.bufferCompleted() }
        }

        onEvent?(.level(rms: rms(resampled)))

        if !isPlaying {
            playerNode.play()
            isPlaying = true
        }
    }

    /// Signal that no more audio will be enqueued for the current utterance.
    ///
    /// If no buffers are currently playing, fires `.finished` immediately.
    /// Otherwise sets `pendingFinal` so the next buffer completion fires it.
    func markEnd() {
        pendingFinal = true
        // No queued buffers left — finish immediately.
        if !isPlaying && pendingBufferCompletions == 0 {
            pendingFinal = false
            onEvent?(.finished)
        }
    }

    /// Immediately stop playback and discard queued audio.
    func stop() {
        playerNode.stop()
        pendingFinal = false
        pendingBufferCompletions = 0
        isPlaying = false
        onEvent?(.stopped)
    }

    // MARK: - Tone Generation

    /// Play the thinking tone: A3 → C4, 300ms, volume 0.05.
    func playThinkingTone() {
        let samples = AudioToneGenerator.thinkingTone()
        enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
    }

    /// Play the listening tone: C5 → E5, 200ms, volume 0.10.
    func playListeningTone() {
        let samples = AudioToneGenerator.listeningTone()
        enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
    }

    /// Play the ready beep: G5, 150ms, volume 0.12.
    func playReadyBeep() {
        let samples = AudioToneGenerator.readyBeep()
        enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
    }

    // MARK: - File Playback

    /// Play a WAV file from disk (for skill audio output).
    func playFile(url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let samples = MLXTTSEngine.parseWAVToFloat32(data)
            guard !samples.isEmpty else {
                NSLog("AudioPlaybackManager: empty or unsupported WAV at %@", url.lastPathComponent)
                return
            }
            enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
        } catch {
            NSLog("AudioPlaybackManager: failed to play %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    // MARK: - Private

    private func bufferCompleted() {
        if pendingBufferCompletions > 0 {
            pendingBufferCompletions -= 1
        }

        if pendingFinal && pendingBufferCompletions == 0 {
            pendingFinal = false
            isPlaying = false
            onEvent?(.finished)
        }
    }

    private func fillPCMBuffer(_ buffer: AVAudioPCMBuffer, withMono samples: [Float]) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount == samples.count else { return false }

        let channelCount = Int(buffer.format.channelCount)

        if let floatData = buffer.floatChannelData {
            for ch in 0..<channelCount {
                let dst = floatData[ch]
                for i in 0..<frameCount {
                    dst[i] = samples[i]
                }
            }
            return true
        }

        if let int16Data = buffer.int16ChannelData {
            for ch in 0..<channelCount {
                let dst = int16Data[ch]
                for i in 0..<frameCount {
                    let clamped = max(-1.0, min(1.0, samples[i]))
                    dst[i] = Int16(clamped * Float(Int16.max))
                }
            }
            return true
        }

        return false
    }

    private func converterKey(srcRate: Double, dstRate: Double) -> String {
        "\(Int(srcRate.rounded()))->\(Int(dstRate.rounded()))"
    }

    private func avAudioConvertResample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return input }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: dstRate,
            channels: 1,
            interleaved: false
        ) else {
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        let key = converterKey(srcRate: srcRate, dstRate: dstRate)
        let converter: AVAudioConverter
        if let cached = converterCache[key] {
            converter = cached
        } else if let created = AVAudioConverter(from: inputFormat, to: outputFormat) {
            converter = created
            converterCache[key] = created
        } else {
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(input.count)
        ) else {
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }
        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        if let channelData = inputBuffer.floatChannelData?[0] {
            input.withUnsafeBufferPointer { src in
                channelData.update(from: src.baseAddress!, count: input.count)
            }
        }

        let ratio = dstRate / srcRate
        let estimatedOutFrames = max(1, Int(Double(input.count) * ratio) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutFrames)
        ) else {
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        converter.reset()

        var consumedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .endOfStream || status == .inputRanDry,
              let outData = outputBuffer.floatChannelData?[0]
        else {
            NSLog("AudioPlaybackManager: AVAudioConverter resample failed (status=%d) — falling back", status.rawValue)
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        let outCount = Int(outputBuffer.frameLength)
        guard outCount > 0 else {
            NSLog("AudioPlaybackManager: AVAudioConverter produced 0 frames — falling back")
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        let output = Array(UnsafeBufferPointer(start: outData, count: outCount))

        // Safety: if conversion produced effectively silent output while input had signal,
        // use the deterministic linear fallback instead.
        let inRms = rms(input)
        let outRms = rms(output)
        if inRms > 0.001 && (outRms < 0.00001 || outRms < inRms * 0.1) {
            NSLog("AudioPlaybackManager: AVAudioConverter output attenuated (inRms=%.6f outRms=%.6f) — falling back", inRms, outRms)
            return Self.linearResampleFallback(input, from: srcRate, to: dstRate)
        }

        return output
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + ($1 * $1) }
        return sqrt(sum / Float(samples.count))
    }

    /// Legacy linear interpolation fallback if AVAudioConverter is unavailable.
    static func linearResampleFallback(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard !input.isEmpty, srcRate > 0, dstRate > 0 else { return input }
        let ratio = srcRate / dstRate
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))
            let s0 = input[min(idx, input.count - 1)]
            let s1 = input[min(idx + 1, input.count - 1)]
            output[i] = s0 * (1 - frac) + s1 * frac
        }
        return output
    }
}
