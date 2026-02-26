import Foundation

/// Tracks echo suppression state for the VAD stage.
///
/// When the assistant is speaking, audio captured from the mic contains
/// speaker bleedthrough. This module manages suppression windows and
/// decides whether a completed VAD segment should be accepted or dropped.
///
/// Replaces: echo suppression logic from `src/pipeline/coordinator.rs`
struct EchoSuppressor {

    // MARK: - Configuration

    /// Whether AEC (Acoustic Echo Cancellation) is enabled.
    var aecEnabled: Bool = true

    // MARK: - Timing Constants

    /// Echo tail after assistant stops speaking.
    var echoTailMs: Int { aecEnabled ? 1500 : 3000 }
    /// Short-utterance guard window after assistant stops.
    var shortUtteranceGuardMs: Int { aecEnabled ? 3000 : 5000 }
    /// Echo tail for scheduling listening tone after approval.
    var echoTailForToneMs: Int { aecEnabled ? 1500 : 3000 }

    // MARK: - Amplitude Constants

    /// Minimum segment duration after playback (seconds).
    static let minPostPlaybackSegmentSecs: Float = 0.4
    /// Maximum segment duration before force-drop (seconds).
    static let maxSegmentSecs: Float = 15.0
    /// RMS ceiling — segments louder than this are likely speaker bleed.
    static let echoRmsCeiling: Float = 0.15
    /// Minimum segment for approval responses (seconds).
    static let minApprovalSegmentSecs: Float = 0.15

    // MARK: - State

    /// Whether the assistant is currently speaking.
    var assistantSpeaking: Bool = false
    /// Time when assistant stopped speaking.
    private var suppressUntil: Date?
    /// Short utterance guard expiry.
    private var shortUtteranceGuardUntil: Date?

    // MARK: - Public API

    /// Call when assistant starts speaking.
    mutating func onAssistantSpeechStart() {
        assistantSpeaking = true
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
    }

    /// Call when assistant stops speaking. Starts the echo tail windows.
    mutating func onAssistantSpeechEnd() {
        assistantSpeaking = false
        let now = Date()
        suppressUntil = now.addingTimeInterval(Double(echoTailMs) / 1000.0)
        shortUtteranceGuardUntil = now.addingTimeInterval(Double(shortUtteranceGuardMs) / 1000.0)
    }

    /// Evaluate whether a completed speech segment should be accepted or dropped.
    ///
    /// - Parameters:
    ///   - durationSecs: Duration of the speech segment in seconds.
    ///   - rms: RMS energy of the segment.
    ///   - awaitingApproval: Whether we're waiting for a yes/no approval response.
    /// - Returns: `true` if the segment should be forwarded to STT, `false` to drop.
    mutating func shouldAccept(durationSecs: Float, rms: Float, awaitingApproval: Bool) -> Bool {
        let now = Date()

        // 1. Active suppression — assistant is speaking.
        if assistantSpeaking {
            return false
        }

        // 2. Echo tail window.
        if let until = suppressUntil, now < until {
            return false
        }

        // 3. Short utterance guard — drop very short segments post-playback.
        if let until = shortUtteranceGuardUntil, now < until {
            if durationSecs < Self.minPostPlaybackSegmentSecs {
                // Exception: during approval, accept shorter segments.
                if awaitingApproval && durationSecs >= Self.minApprovalSegmentSecs {
                    // Accept approval response.
                } else {
                    return false
                }
            }
        }

        // 4. Duration cap — very long segments are echo bleed.
        if durationSecs > Self.maxSegmentSecs {
            return false
        }

        // 5. Amplitude cap — loud segments are speaker bleedthrough.
        if rms > Self.echoRmsCeiling {
            return false
        }

        // Accepted — clear guard windows.
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
        return true
    }
}
