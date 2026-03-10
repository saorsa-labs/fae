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

    /// Whether hardware AEC (Acoustic Echo Cancellation) is active.
    /// macOS AVAudioEngine does not expose hardware AEC, so this defaults
    /// to false. With no AEC, longer suppression windows are needed to
    /// prevent Fae from hearing her own voice through the speakers.
    var aecEnabled: Bool = false

    // MARK: - Timing Constants

    /// Echo tail after assistant stops speaking.
    /// Reduced from 3500ms → 2000ms: the old value created a perceptible
    /// "dead zone" where the user spoke and Fae appeared unresponsive.
    /// The RMS ceiling + short-utterance guard still catch actual echo.
    var echoTailMs: Int { aecEnabled ? 1000 : 2000 }
    /// Short-utterance guard window after assistant stops.
    /// Reduced from 4000ms → 2500ms to match shorter echo tail.
    var shortUtteranceGuardMs: Int { aecEnabled ? 1500 : 2500 }
    /// Echo tail for scheduling listening tone after approval.
    var echoTailForToneMs: Int { aecEnabled ? 1000 : 2000 }

    // MARK: - Amplitude Constants

    /// Minimum segment duration after playback (seconds).
    static let minPostPlaybackSegmentSecs: Float = 0.5
    /// If speech starts inside the echo tail but continues materially beyond it,
    /// treat it as a real user utterance rather than dropping the whole segment.
    static let minSpeechBeyondTailSecs: TimeInterval = 0.75
    static let minSpeechBeyondTailFraction: Double = 0.35
    /// Maximum segment duration before force-drop (seconds).
    static let maxSegmentSecs: Float = 15.0
    /// RMS ceiling — segments louder than this are likely speaker bleed.
    static let echoRmsCeiling: Float = 0.12
    /// Minimum segment for approval responses (seconds).
    static let minApprovalSegmentSecs: Float = 0.15

    // MARK: - State

    /// Whether the assistant is currently speaking.
    var assistantSpeaking: Bool = false
    /// Time when assistant stopped speaking.
    private var suppressUntil: Date?
    /// Short utterance guard expiry.
    private var shortUtteranceGuardUntil: Date?

    // MARK: - Computed Properties

    /// Whether the echo suppressor is currently actively suppressing audio.
    /// True when assistant is speaking or within the echo tail window.
    var isInSuppression: Bool {
        if assistantSpeaking { return true }
        if let until = suppressUntil, Date() < until { return true }
        return false
    }

    // MARK: - Public API

    /// Call when assistant starts speaking.
    mutating func onAssistantSpeechStart() {
        assistantSpeaking = true
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
    }

    /// Call when assistant stops speaking. Starts the echo tail windows.
    ///
    /// - Parameter speechDurationSecs: How long the assistant spoke. Longer TTS
    ///   responses produce more room echo and speaker bleedthrough, so the echo
    ///   tail and guard windows scale proportionally — but capped conservatively
    ///   to avoid blocking real speech for too long ("goes to sleep" effect).
    mutating func onAssistantSpeechEnd(speechDurationSecs: Double = 0) {
        assistantSpeaking = false
        let now = Date()

        // Scale echo windows based on speech duration: +150ms per second of speech,
        // capped at 1s bonus. An 8s response adds ~1s (total 3s). Previous values
        // (200ms/s, 1.5s cap) created a 5s dead zone that felt unresponsive.
        let durationBonusMs = Int(min(speechDurationSecs * 150, 1000))
        let tailMs = echoTailMs + durationBonusMs
        let guardMs = shortUtteranceGuardMs + durationBonusMs

        suppressUntil = now.addingTimeInterval(Double(tailMs) / 1000.0)
        shortUtteranceGuardUntil = now.addingTimeInterval(Double(guardMs) / 1000.0)
    }

    /// Evaluate whether a completed speech segment should be accepted or dropped.
    ///
    /// - Parameters:
    ///   - durationSecs: Duration of the speech segment in seconds.
    ///   - rms: RMS energy of the segment.
    ///   - awaitingApproval: Whether we're waiting for a yes/no approval response.
    ///   - segmentOnset: Wall-clock time when speech onset was detected by the VAD.
    ///     The echo tail is checked against this onset time (not current time) to
    ///     catch segments that *started* during the echo window but took seconds
    ///     to complete — e.g. an 8s echo segment that finishes 9s after playback
    ///     ends would slip through a current-time check but is caught by onset.
    /// - Returns: `true` if the segment should be forwarded to STT, `false` to drop.
    mutating func shouldAccept(
        durationSecs: Float,
        rms: Float,
        awaitingApproval: Bool,
        segmentOnset: Date? = nil
    ) -> Bool {
        let onset = segmentOnset ?? Date()
        let now = Date()

        // 1. Active suppression — assistant is speaking.
        if assistantSpeaking {
            return false
        }

        // 2. Echo tail window — check against segment ONSET time.
        //    A segment whose speech started during the echo tail is almost certainly
        //    speaker bleedthrough, unless it clearly continues beyond the tail and
        //    is more likely to be the user starting promptly after Fae stops.
        if let until = suppressUntil,
           Self.shouldRejectForEchoTail(
               segmentOnset: onset,
               durationSecs: durationSecs,
               suppressUntil: until
           )
        {
            return false
        }

        // 3. Short utterance guard — drop very short segments post-playback.
        //    Use current time here: a long segment that starts in the guard window
        //    but extends past it is likely real speech, not echo.
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

    static func shouldRejectForEchoTail(
        segmentOnset: Date,
        durationSecs: Float,
        suppressUntil: Date
    ) -> Bool {
        guard segmentOnset < suppressUntil else { return false }

        let segmentEnd = segmentOnset.addingTimeInterval(TimeInterval(durationSecs))
        let speechBeyondTailSecs = segmentEnd.timeIntervalSince(suppressUntil)
        if speechBeyondTailSecs <= 0 {
            return true
        }

        let beyondTailFraction = speechBeyondTailSecs / max(TimeInterval(durationSecs), 0.001)
        return speechBeyondTailSecs < Self.minSpeechBeyondTailSecs
            && beyondTailFraction < Self.minSpeechBeyondTailFraction
    }
}
