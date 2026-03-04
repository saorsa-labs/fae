import Foundation

/// Tool for voice identity management — enrollment, matching, and profile management.
///
/// Actions:
/// - `check_status` — returns enrollment state, speaker count, confidence scores
/// - `collect_sample` — plays ready beep, captures audio, embeds, enrolls
/// - `collect_wake_samples` — captures short "Hey Fae" samples and learns user wake aliases
/// - `confirm_identity` — matches current speaker against all profiles
/// - `rename_speaker` — updates display name
/// - `list_speakers` — lists all enrolled speakers with roles and counts
struct VoiceIdentityTool: Tool {
    let name = "voice_identity"
    let description = """
        Manage voice identity: enroll speakers, verify identity, and personalize wake name detection. \
        Actions: check_status, collect_sample (plays beep then captures voice), \
        collect_wake_samples, confirm_identity, rename_speaker, list_speakers.
        """
    let parametersSchema = #"""
        {
            "action": "string (required) — one of: check_status, collect_sample, collect_wake_samples, confirm_identity, rename_speaker, list_speakers",
            "label": "string (optional) — speaker label for collect_sample or rename_speaker (e.g. 'alice')",
            "role": "string (optional) — speaker role for collect_sample: 'owner', 'trusted', 'guest' (default: 'guest')",
            "display_name": "string (optional) — human-readable name for collect_sample or rename_speaker",
            "count": "number (optional) — number of wake samples for collect_wake_samples (default: 3, max: 6)",
            "phrase": "string (optional) — wake phrase prompt label for collect_wake_samples (default: 'Hey Fae')",
            "threshold": "number (optional) — similarity threshold for confirm_identity (default: 0.70)"
        }
        """#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"""
        <tool_call>{"name":"voice_identity","arguments":{"action":"collect_sample","label":"alice","role":"trusted","display_name":"Alice"}}</tool_call>
        """#

    // MARK: - Dependencies

    let speakerEncoder: CoreMLSpeakerEncoder?
    let speakerProfileStore: SpeakerProfileStore?
    let audioCaptureManager: AudioCaptureManager?
    let audioPlaybackManager: AudioPlaybackManager?
    let sttEngine: MLXSTTEngine?
    let wakeWordProfileStore: WakeWordProfileStore?

    // MARK: - Execute

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "check_status":
            return await checkStatus()
        case "collect_sample":
            return await collectSample(input: input)
        case "collect_wake_samples":
            return await collectWakeSamples(input: input)
        case "confirm_identity":
            return await confirmIdentity(input: input)
        case "rename_speaker":
            return await renameSpeaker(input: input)
        case "list_speakers":
            return await listSpeakers()
        default:
            return .error("Unknown action: \(action). Valid actions: check_status, collect_sample, collect_wake_samples, confirm_identity, rename_speaker, list_speakers")
        }
    }

    // MARK: - Actions

    private func checkStatus() async -> ToolResult {
        guard let store = speakerProfileStore else {
            return .success("""
                {"status": "unavailable", "reason": "Speaker profile store not loaded", \
                "speaker_count": 0, "has_owner": false, "encoder_loaded": false}
                """)
        }

        let hasOwner = await store.hasOwnerProfile()
        let summaries = await store.profileSummaries()
        let encoderLoaded = await speakerEncoder?.isLoaded ?? false

        let speakerList = summaries.map { s in
            let confidence = confidenceScore(for: s.enrollmentCount)
            let confidenceString = String(format: "%.3f", confidence)
            return "{\"label\": \"\(s.id)\", \"name\": \"\(s.displayName)\", \"role\": \"\(s.role.rawValue)\", \"enrollments\": \(s.enrollmentCount), \"confidence_score\": \(confidenceString)}"
        }.joined(separator: ", ")

        return .success("""
            {"status": "active", "encoder_loaded": \(encoderLoaded), \
            "has_owner": \(hasOwner), "speaker_count": \(summaries.count), \
            "speakers": [\(speakerList)]}
            """)
    }

    private func collectSample(input: [String: Any]) async -> ToolResult {
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            return .error("Speaker encoder not loaded — voice identity unavailable.")
        }
        guard let store = speakerProfileStore else {
            return .error("Speaker profile store not available.")
        }
        guard let capture = audioCaptureManager else {
            return .error("Audio capture not available.")
        }

        let label = (input["label"] as? String) ?? "unknown"
        let displayName = (input["display_name"] as? String) ?? label.capitalized
        let roleStr = (input["role"] as? String) ?? "guest"
        let role: SpeakerRole
        switch roleStr {
        case "owner": role = .owner
        case "trusted": role = .trusted
        case "guest": role = .guest
        default: role = .guest
        }

        // 1. Play ready beep.
        if let playback = audioPlaybackManager {
            await playback.playReadyBeep()
            // Wait for beep to finish (~150ms tone + buffer).
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 2. Capture ~3 seconds of audio.
        let samples: [Float]
        do {
            samples = try await capture.captureSegment(durationSeconds: 3.0)
        } catch {
            return .error("Audio capture failed: \(error.localizedDescription)")
        }

        guard samples.count > 8_000 else {
            return .error("Captured audio too short — please speak for at least 2 seconds after the beep.")
        }

        // 3. Compute embedding.
        let embedding: [Float]
        do {
            embedding = try await encoder.embed(audio: samples, sampleRate: AudioCaptureManager.targetSampleRate)
        } catch {
            return .error("Embedding failed: \(error.localizedDescription)")
        }

        // 4. Enroll.
        let hadOwnerBefore = await store.hasOwnerProfile()
        await store.enroll(label: label, embedding: embedding, role: role, displayName: displayName)

        if role == .owner, !hadOwnerBefore, await store.hasOwnerProfile() {
            NotificationCenter.default.post(
                name: .faePipelineState,
                object: nil,
                userInfo: [
                    "event": "pipeline.enrollment_complete",
                    "payload": [:] as [String: Any],
                ]
            )
        }

        // 5. Quality feedback.
        let enrollmentCount = await store.enrollmentCount(for: label)
        let quality: String
        if enrollmentCount >= 5 {
            quality = "excellent"
        } else if enrollmentCount >= 3 {
            quality = "good"
        } else {
            quality = "building"
        }

        return .success("""
            {"enrolled": true, "label": "\(label)", "display_name": "\(displayName)", \
            "role": "\(role.rawValue)", "enrollment_count": \(enrollmentCount), \
            "quality": "\(quality)", \
            "message": "Voice sample collected and enrolled. \(qualityAdvice(enrollmentCount))"}
            """)
    }

    private func collectWakeSamples(input: [String: Any]) async -> ToolResult {
        guard let capture = audioCaptureManager else {
            return .error("Audio capture not available.")
        }
        guard let stt = sttEngine else {
            return .error("STT engine not available — cannot learn wake aliases right now.")
        }
        guard let wakeStore = wakeWordProfileStore else {
            return .error("Wake profile store not available.")
        }

        let requestedCount = input["count"] as? Int ?? 3
        let count = max(1, min(requestedCount, 6))
        let rawPhrase = (input["phrase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase: String
        if let rawPhrase, !rawPhrase.isEmpty {
            phrase = rawPhrase
        } else {
            phrase = "Hey Fae"
        }

        var transcripts: [String] = []
        var learnedAliases: [String] = []

        for _ in 0..<count {
            if let playback = audioPlaybackManager {
                await playback.playReadyBeep()
                try? await Task.sleep(nanoseconds: 180_000_000)
            }

            let samples: [Float]
            do {
                samples = try await capture.captureSegment(durationSeconds: 2.0)
            } catch {
                return .error("Wake sample capture failed: \(error.localizedDescription)")
            }

            guard samples.count > 6_000 else {
                continue
            }

            do {
                let result = try await stt.transcribe(
                    samples: samples,
                    sampleRate: AudioCaptureManager.targetSampleRate
                )
                let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty {
                    transcripts.append(transcript)
                }
                if let alias = TextProcessing.extractWakeAliasCandidate(from: transcript) {
                    await wakeStore.recordAliasCandidate(alias, source: "enrollment")
                    learnedAliases.append(alias)
                }
            } catch {
                // Keep going — we still may learn from other samples.
                NSLog("VoiceIdentityTool: wake sample STT failed: %@", error.localizedDescription)
            }
        }

        let uniqueLearned = Array(Set(learnedAliases)).sorted()
        let payload: [String: Any] = [
            "learned": !uniqueLearned.isEmpty,
            "phrase": phrase,
            "samples_requested": count,
            "samples_transcribed": transcripts.count,
            "learned_aliases": uniqueLearned,
            "transcripts": transcripts,
            "message": uniqueLearned.isEmpty
                ? "I heard your samples, but I couldn't confidently derive a new wake-name variant yet."
                : "Wake-name personalization updated from your voice samples."
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8)
        {
            return .success(json)
        }

        return .success("{\"learned\":\(!uniqueLearned.isEmpty)}")
    }

    private func confirmIdentity(input: [String: Any]) async -> ToolResult {
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            return .error("Speaker encoder not loaded — voice identity unavailable.")
        }
        guard let store = speakerProfileStore else {
            return .error("Speaker profile store not available.")
        }
        guard let capture = audioCaptureManager else {
            return .error("Audio capture not available.")
        }

        let threshold = Float(input["threshold"] as? Double ?? 0.70)

        // Play ready beep.
        if let playback = audioPlaybackManager {
            let beepSamples = AudioToneGenerator.readyBeep()
            await playback.enqueue(
                samples: beepSamples,
                sampleRate: Int(AudioToneGenerator.sampleRate),
                isFinal: true
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Capture audio.
        let samples: [Float]
        do {
            samples = try await capture.captureSegment(durationSeconds: 3.0)
        } catch {
            return .error("Audio capture failed: \(error.localizedDescription)")
        }

        guard samples.count > 8_000 else {
            return .error("Captured audio too short — please speak for at least 2 seconds after the beep.")
        }

        // Embed.
        let embedding: [Float]
        do {
            embedding = try await encoder.embed(audio: samples, sampleRate: AudioCaptureManager.targetSampleRate)
        } catch {
            return .error("Embedding failed: \(error.localizedDescription)")
        }

        // Match.
        if let match = await store.match(embedding: embedding, threshold: threshold) {
            let confidence: String
            if match.similarity >= 0.85 {
                confidence = "high"
            } else if match.similarity >= 0.75 {
                confidence = "medium"
            } else {
                confidence = "low"
            }
            return .success("""
                {"matched": true, "label": "\(match.label)", \
                "display_name": "\(match.displayName)", \
                "role": "\(match.role.rawValue)", \
                "similarity": \(String(format: "%.3f", match.similarity)), \
                "confidence": "\(confidence)"}
                """)
        } else {
            return .success("""
                {"matched": false, "message": "No matching speaker profile found above threshold \(String(format: "%.2f", threshold))."}
                """)
        }
    }

    private func renameSpeaker(input: [String: Any]) async -> ToolResult {
        guard let store = speakerProfileStore else {
            return .error("Speaker profile store not available.")
        }
        guard let label = input["label"] as? String else {
            return .error("Missing required parameter: label")
        }
        guard let newName = input["display_name"] as? String else {
            return .error("Missing required parameter: display_name")
        }

        let labels = await store.enrolledLabels
        guard labels.contains(label) else {
            return .error("No speaker profile found with label: \(label)")
        }

        await store.rename(label: label, newDisplayName: newName)
        return .success("""
            {"renamed": true, "label": "\(label)", "new_display_name": "\(newName)"}
            """)
    }

    private func listSpeakers() async -> ToolResult {
        guard let store = speakerProfileStore else {
            return .success(#"{"speakers": [], "message": "Speaker profile store not available."}"#)
        }

        let summaries = await store.profileSummaries()
        if summaries.isEmpty {
            return .success(#"{"speakers": [], "message": "No speakers enrolled."}"#)
        }

        let iso = ISO8601DateFormatter()
        let list = summaries.map { s in
            """
            {"label": "\(s.id)", "display_name": "\(s.displayName)", \
            "role": "\(s.role.rawValue)", "enrollment_count": \(s.enrollmentCount), \
            "last_seen": "\(iso.string(from: s.lastSeen))"}
            """
        }.joined(separator: ", ")

        return .success("""
            {"speakers": [\(list)], "count": \(summaries.count)}
            """)
    }

    // MARK: - Helpers

    private func qualityAdvice(_ count: Int) -> String {
        if count >= 5 {
            return "Voice profile is strong with \(count) samples."
        } else if count >= 3 {
            return "Good start — \(5 - count) more sample(s) will improve recognition accuracy."
        } else {
            return "Profile is building — collect \(3 - count) more sample(s) for reliable recognition."
        }
    }

    /// Heuristic confidence score based on enrollment depth.
    private func confidenceScore(for enrollmentCount: Int) -> Double {
        let clamped = max(0, min(enrollmentCount, 5))
        return min(0.95, 0.55 + Double(clamped) * 0.08)
    }
}
