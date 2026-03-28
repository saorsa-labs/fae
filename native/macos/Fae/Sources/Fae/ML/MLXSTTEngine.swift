import Foundation
import MLX
import MLXAudioSTT

/// Speech-to-text engine using Qwen3-ASR via mlx-audio-swift.
///
/// Replaces: `src/stt/mod.rs` (parakeet-rs)
actor MLXSTTEngine: STTEngine {
    private var model: Qwen3ASRModel?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    // MARK: - Streaming ASR State (Phase 3)

    /// Accumulated audio during active speech for periodic re-transcription.
    private var streamingBuffer: [Float] = []

    /// Current streaming partial transcript.
    private(set) var partialTranscript: String = ""

    /// Previous partial transcript for stability comparison.
    private var previousPartial: String = ""

    /// Maximum character-level edit distance ratio between consecutive partials
    /// before the new partial is suppressed as unstable.  0.8 means >80% of
    /// the previous text changed — likely noise contamination, not real speech.
    static let maxPartialInstabilityRatio: Float = 0.8

    /// Epoch of the currently in-flight streaming run, or `nil` if no run is
    /// active.  Replaces a simple boolean flag — because the epoch is captured
    /// per-run, a stale run that resumes after a reset/watchdog can never
    /// accidentally clear a newer run's slot.
    ///
    /// Only `runStreamingTranscription()` may set this (on entry) or clear it
    /// (on exit, if its epoch still matches).  `resetStreaming()` never touches
    /// it — it only advances `streamingEpoch` to invalidate the run.  The
    /// watchdog in `shouldRunStreamingTranscription()` may nil it to reclaim
    /// a wedged slot.
    private var activeStreamingRunEpoch: UInt64?

    /// Wall-clock time the active streaming run started (for wedge detection).
    private var streamingRunStartedAt: Date?

    /// Engine-internal epoch.  Incremented by `resetStreaming()` and by the
    /// watchdog so that an in-flight `runStreamingTranscription()` detects the
    /// invalidation at its next actor re-entry point and bails out.
    private var streamingEpoch: UInt64 = 0

    /// Number of samples in `streamingBuffer` when the last streaming run started.
    private var lastStreamingRunSampleCount: Int = 0

    /// Minimum new samples (500ms at 16kHz) before running another streaming transcription.
    static let streamingIntervalSamples = 8_000

    /// Maximum wall-clock seconds a streaming transcription may run before the
    /// watchdog declares it wedged and reclaims the slot.  3s is generous —
    /// 1.5s of 16kHz audio transcribes in <500ms on M-series.
    static let streamingWedgeTimeoutSeconds: TimeInterval = 3.0

    /// Load the STT model.
    func load(modelID: String = "mlx-community/Qwen3-ASR-1.7B-4bit") async throws {
        loadState = .loading
        NSLog("MLXSTTEngine: loading model %@", modelID)
        do {
            model = try await Qwen3ASRModel.fromPretrained(modelID)
            isLoaded = true
            loadState = .loaded
            NSLog("MLXSTTEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXSTTEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Transcribe a speech segment to text.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult {
        guard let model else {
            throw MLEngineError.notLoaded("STT")
        }

        // Audio preprocessing: peak normalize + high-pass filter for better ASR accuracy.
        var processed = samples
        Self.preprocessForASR(&processed, sampleRate: sampleRate)

        let audio = MLXArray(processed)
        let output = model.generate(audio: audio)

        return STTResult(
            text: output.text,
            language: output.language,
            confidence: nil
        )
    }

    // MARK: - Audio Preprocessing

    /// Normalize peak amplitude to -3dBFS and apply 80Hz high-pass filter.
    /// Peak normalization ensures consistent input level; high-pass removes
    /// low-frequency rumble/hum that degrades ASR accuracy.
    private static func preprocessForASR(_ samples: inout [Float], sampleRate: Int) {
        // Peak normalize to -3dBFS (0.707 linear)
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        if peak > 0.001 {
            let gain = Float(0.707) / peak
            for i in samples.indices { samples[i] *= gain }
        }

        // 80Hz high-pass filter (1-pole IIR)
        let rc = 1.0 / (2.0 * Float.pi * 80.0)
        let dt = 1.0 / Float(sampleRate)
        let alpha = rc / (rc + dt)
        var prev: Float = 0
        var prevFiltered: Float = 0
        for i in samples.indices {
            let filtered = alpha * (prevFiltered + samples[i] - prev)
            prev = samples[i]
            prevFiltered = filtered
            samples[i] = filtered
        }
    }

    // MARK: - Streaming ASR

    /// Append audio samples to the streaming buffer during active speech.
    func feedStreamingAudio(_ samples: [Float]) {
        streamingBuffer.append(contentsOf: samples)
    }

    /// Whether enough new audio has accumulated to justify a streaming
    /// transcription.
    ///
    /// Also runs a **wedge watchdog**: if an active run has been stuck for
    /// longer than `streamingWedgeTimeoutSeconds`, it reclaims the slot by
    /// advancing the epoch (invalidating the stuck run) and nilling
    /// `activeStreamingRunEpoch`.  Returns `false` on the reclaim pass so the
    /// next pipeline loop iteration gets the fresh run.
    ///
    /// **Limitation**: reclaiming the slot does not cancel the underlying
    /// `Qwen3ASRModel.generateStream()` `Task.detached` producer, which
    /// continues running until it finishes or hits EOS.  For ~1.5s of audio
    /// this is typically <500ms of residual GPU work.  The old run's results
    /// are discarded (epoch mismatch) so correctness is unaffected — only
    /// GPU utilization is briefly suboptimal.  True cancellation would require
    /// vendor-side cooperative cancellation support.
    func shouldRunStreamingTranscription() -> Bool {
        // Watchdog: detect and recover from a wedged streaming run.
        if let activeEpoch = activeStreamingRunEpoch,
           let started = streamingRunStartedAt,
           Date().timeIntervalSince(started) > Self.streamingWedgeTimeoutSeconds
        {
            NSLog("MLXSTTEngine: streaming run (epoch %llu) wedged for >%.0fs — reclaiming slot",
                  activeEpoch, Self.streamingWedgeTimeoutSeconds)
            streamingEpoch &+= 1
            activeStreamingRunEpoch = nil
            streamingRunStartedAt = nil
            // Return false this pass — the slot was just reclaimed.
            // Next call (36ms later) will see the empty slot and fresh buffer.
            return false
        }

        guard activeStreamingRunEpoch == nil else { return false }
        let newSamples = streamingBuffer.count - lastStreamingRunSampleCount
        return newSamples >= Self.streamingIntervalSamples
    }

    /// Run a streaming transcription on the accumulated buffer.
    ///
    /// Uses `generateStream()` to stream tokens, collecting them into a partial
    /// transcript.  Returns `nil` if the model isn't loaded, another streaming
    /// run is active, or an error occurs.
    ///
    /// **Single-run guarantee**: `activeStreamingRunEpoch` is set to the
    /// current epoch on entry.  Every exit path clears it **only if the epoch
    /// still matches** — a stale run that resumes after a reset or watchdog
    /// reclaim will see its epoch no longer matches and exit without touching
    /// the slot, even if a newer run has claimed it.
    func runStreamingTranscription() async -> String? {
        guard let model, activeStreamingRunEpoch == nil, !streamingBuffer.isEmpty else {
            return nil
        }
        let runEpoch = streamingEpoch
        activeStreamingRunEpoch = runEpoch
        streamingRunStartedAt = Date()
        lastStreamingRunSampleCount = streamingBuffer.count

        let audio = MLXArray(streamingBuffer)
        var tokens: [String] = []
        do {
            let stream = model.generateStream(audio: audio)
            for try await event in stream {
                // Check epoch after each actor re-entry (each await).
                guard streamingEpoch == runEpoch else {
                    releaseSlotIfOwner(runEpoch)
                    return nil
                }
                switch event {
                case .token(let text):
                    tokens.append(text)
                case .info, .result:
                    break
                }
            }
        } catch {
            releaseSlotIfOwner(runEpoch)
            NSLog("MLXSTTEngine: streaming transcription error: %@", error.localizedDescription)
            return nil
        }

        // Final epoch check before committing the result.
        guard streamingEpoch == runEpoch else {
            releaseSlotIfOwner(runEpoch)
            return nil
        }
        releaseSlotIfOwner(runEpoch)

        let text = tokens.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Partial stability gate: suppress results that differ radically from
        // the previous partial, which usually indicates noise contamination
        // rather than real speech evolution.
        //
        // IMPORTANT: do NOT update previousPartial on suppression.  A noise
        // partial must not become the baseline — otherwise the next good partial
        // would also look "too different" and get suppressed, creating a cascade.
        if !previousPartial.isEmpty {
            let ratio = Self.editDistanceRatio(previousPartial, text)
            if ratio > Self.maxPartialInstabilityRatio {
                NSLog("MLXSTTEngine: suppressed unstable partial (edit ratio %.2f) — keeping previous baseline", ratio)
                return nil
            }
        }

        previousPartial = text
        partialTranscript = text
        return text
    }

    /// Release the active run slot only if this run still owns it.
    /// Prevents a stale run from clearing a newer run's slot after a reset
    /// or watchdog reclaim.
    private func releaseSlotIfOwner(_ runEpoch: UInt64) {
        if activeStreamingRunEpoch == runEpoch {
            activeStreamingRunEpoch = nil
            streamingRunStartedAt = nil
        }
    }

    /// Clear all streaming state — call on segment completion or pipeline reset.
    ///
    /// Advances `streamingEpoch` to invalidate any in-flight transcription run.
    /// Does **not** touch `activeStreamingRunEpoch` — that is exclusively
    /// managed by `runStreamingTranscription()` and the watchdog.  The
    /// in-flight run will detect the epoch change at its next actor re-entry,
    /// bail out, and release the slot itself.
    func resetStreaming() {
        streamingEpoch &+= 1
        streamingBuffer.removeAll()
        partialTranscript = ""
        previousPartial = ""
        // Do NOT touch activeStreamingRunEpoch here.  The in-flight run owns it.
        lastStreamingRunSampleCount = 0
    }

    // MARK: - Utilities

    /// Normalised edit distance between two strings (0 = identical, 1 = completely different).
    static func editDistanceRatio(_ a: String, _ b: String) -> Float {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0 || n > 0 else { return 0 }

        // Optimised single-row Levenshtein.
        var row = Array(0...n)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            var prev = row[0]
            row[0] = i
            for j in 1...n {
                let old = row[j]
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                row[j] = min(row[j] + 1, min(row[j - 1] + 1, prev + cost))
                prev = old
            }
        }
        return Float(row[n]) / Float(max(m, n))
    }
}
