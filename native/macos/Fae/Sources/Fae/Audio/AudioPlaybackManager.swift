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

    /// Playback speed multiplier (0.8-1.4). Adjusts resample ratio.
    private var speed: Float = 1.0

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

        // Apply speed: treat source rate as higher to speed up, lower to slow down.
        // This changes pitch proportionally — acceptable for voice speed adjustment.
        let effectiveSourceRate = Double(sampleRate) * Double(speed)

        // Resample if effective source rate differs from output device rate.
        let resampled: [Float]
        if effectiveSourceRate != outputRate {
            resampled = Self.linearResample(samples, from: effectiveSourceRate, to: outputRate)
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
    ///
    /// If no buffers are currently playing, fires `.finished` immediately.
    /// Otherwise sets `pendingFinal` so the next buffer completion fires it.
    func markEnd() {
        if isPlaying {
            pendingFinal = true
        } else {
            // No audio in the queue — fire finished immediately.
            onEvent?(.finished)
        }
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
