import AVFoundation
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
    private var isPlaying = false
    private var pendingFinal = false

    /// Default TTS output sample rate.
    static let ttsSampleRate: Double = 24_000

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
        engine.attach(playerNode)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        try engine.start()
        NSLog("AudioPlaybackManager: engine started (output: %.0f Hz)", outputFormat.sampleRate)
    }

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

        // Resample if TTS rate differs from output device rate.
        let resampled: [Float]
        if Double(sampleRate) != outputRate {
            resampled = Self.linearResample(samples, from: Double(sampleRate), to: outputRate)
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
        let channelCount = Int(outputFormat.channelCount)
        for ch in 0..<channelCount {
            if let channelData = buffer.floatChannelData?[ch] {
                for i in 0..<Int(frameCount) {
                    channelData[i] = resampled[i]
                }
            }
        }

        if isFinal {
            pendingFinal = true
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { await self?.bufferCompleted() }
        }

        if !isPlaying {
            playerNode.play()
            isPlaying = true
        }
    }

    /// Signal that no more audio will be enqueued for the current utterance.
    func markEnd() {
        pendingFinal = true
    }

    /// Immediately stop playback and discard queued audio.
    func stop() {
        playerNode.stop()
        pendingFinal = false
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

    // MARK: - Private

    private func bufferCompleted() {
        if pendingFinal {
            pendingFinal = false
            isPlaying = false
            onEvent?(.finished)
        }
    }

    /// Linear interpolation resampling.
    static func linearResample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
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
