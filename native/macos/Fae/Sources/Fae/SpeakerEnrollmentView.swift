import SwiftUI

/// Guided speaker enrollment flow: name → record 3 samples → confirm.
///
/// Used for first-launch owner enrollment and re-enrollment from Settings.
struct SpeakerEnrollmentView: View {
    let captureManager: AudioCaptureManager
    let speakerEncoder: CoreMLSpeakerEncoder
    let speakerProfileStore: SpeakerProfileStore
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    /// Pre-filled name (e.g. from config.userName during first launch).
    var initialName: String = ""

    @State private var step: EnrollmentStep = .name
    @State private var displayName: String = ""
    @State private var sampleIndex: Int = 0
    @State private var embeddings: [[Float]] = []
    @State private var isRecording: Bool = false
    @State private var recordingProgress: Double = 0
    @State private var consistencyScore: Float = 0
    @State private var errorMessage: String?

    private static let sampleCount = 3
    private static let sampleDuration: Double = 8.0

    enum EnrollmentStep {
        case name
        case recording
        case complete
    }

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .name:
                nameStep
            case .recording:
                recordingStep
            case .complete:
                completeStep
            }
        }
        .padding(32)
        .frame(width: 420, height: 420)
        .onAppear {
            if !initialName.isEmpty {
                displayName = initialName
            }
        }
    }

    // MARK: - Step 1: Name

    private var nameStep: some View {
        VStack(spacing: 20) {
            Text("Voice Enrollment")
                .font(.title2.weight(.semibold))

            Text("What should I call you?")
                .font(.body)
                .foregroundStyle(.secondary)

            TextField("Your name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button("Next") { step = .recording }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Step 2: Recording

    /// Example phrases for each recording sample — gives users something
    /// natural to say rather than awkward silence.
    private static let samplePrompts: [[String]] = [
        [
            "\"The weather looks lovely today, I might go for a walk later.\"",
            "\"I've been meaning to reorganise my desk, it's getting cluttered.\"",
            "\"My favourite thing about mornings is that first cup of coffee.\"",
        ],
        [
            "\"I was thinking about what to cook for dinner tonight.\"",
            "\"There's a great wee bakery just round the corner from here.\"",
            "\"I really enjoy listening to music while I work.\"",
        ],
        [
            "\"Sometimes the best ideas come when you're not even trying.\"",
            "\"I should probably call my mum this weekend, it's been a while.\"",
            "\"The garden is looking better now that spring is on the way.\"",
        ],
    ]

    private var recordingStep: some View {
        VStack(spacing: 16) {
            Text("Voice Sample \(sampleIndex + 1) of \(Self.sampleCount)")
                .font(.title2.weight(.semibold))

            Text("Read any of these aloud in your natural voice:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Show example phrases for the current sample.
            VStack(alignment: .leading, spacing: 6) {
                let prompts = Self.samplePrompts[min(sampleIndex, Self.samplePrompts.count - 1)]
                ForEach(prompts, id: \.self) { prompt in
                    Text(prompt)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(.primary.opacity(0.75))
                        .italic()
                }
            }
            .padding(.horizontal, 8)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: recordingProgress)
                    .stroke(
                        isRecording ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: recordingProgress)

                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.title)
                    .foregroundStyle(isRecording ? .red : .primary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(isRecording ? "Recording..." : "Record") {
                    Task { await recordSample() }
                }
                .disabled(isRecording)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 3: Complete

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Got it, \(displayName)!")
                .font(.title2.weight(.semibold))

            Text("I'll recognize your voice from now on.")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Voice consistency:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", consistencyScore * 100))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(consistencyScore > 0.7 ? .green : .orange)
            }

            Button("Done") {
                onComplete(displayName)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Recording Logic

    @MainActor
    /// Maximum automatic retries when capture gets silence (mic warmup).
    private static let maxAutoRetries = 2

    private func recordSample() async {
        isRecording = true
        recordingProgress = 0
        errorMessage = nil

        // Pulsing progress indicator — shows recording is active without
        // implying a fixed duration. Pulses between 0.2 and 0.8 until
        // capture completes (speech detection handles the timing).
        let progressTask = Task {
            var up = true
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if up {
                    recordingProgress = min(recordingProgress + 0.02, 0.8)
                    if recordingProgress >= 0.8 { up = false }
                } else {
                    recordingProgress = max(recordingProgress - 0.01, 0.2)
                    if recordingProgress <= 0.2 { up = true }
                }
            }
        }

        do {
            // Retry automatically if mic returns silence (AVAudioEngine warmup).
            var samples: [Float] = []
            var quality = AudioCaptureManager.SegmentSpeechQuality(rms: 0, peak: 0, voicedFrameRatio: 0, voicedDurationSeconds: 0)

            for attempt in 0...Self.maxAutoRetries {
                samples = try await captureManager.captureSegment(durationSeconds: Self.sampleDuration)
                quality = AudioCaptureManager.analyzeSegment(samples)
                NSLog(
                    "SpeakerEnrollmentView: sample %d attempt %d quality rms=%.4f peak=%.4f voiced_ratio=%.3f voiced_seconds=%.2f usable=%@",
                    sampleIndex + 1,
                    attempt + 1,
                    quality.rms,
                    quality.peak,
                    quality.voicedFrameRatio,
                    quality.voicedDurationSeconds,
                    quality.hasUsableSpeech ? "true" : "false"
                )
                if quality.hasUsableSpeech { break }
                if attempt < Self.maxAutoRetries {
                    NSLog("SpeakerEnrollmentView: auto-retrying (attempt %d got silence)", attempt + 1)
                    recordingProgress = 0.2
                }
            }

            progressTask.cancel()
            recordingProgress = 1.0

            guard quality.hasUsableSpeech else {
                errorMessage = "I didn't hear enough clear speech. Move a bit closer and try that sample again."
                isRecording = false
                recordingProgress = 0
                return
            }

            let embedding = try await speakerEncoder.embed(
                audio: samples,
                sampleRate: AudioCaptureManager.targetSampleRate
            )
            embeddings.append(embedding)
            sampleIndex += 1

            if sampleIndex >= Self.sampleCount {
                // All samples collected — enroll and show confirmation.
                let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                await speakerProfileStore.bulkEnroll(
                    label: "owner",
                    embeddings: embeddings,
                    role: .owner,
                    displayName: trimmedName
                )
                consistencyScore = SpeakerProfileStore.consistencyScore(embeddings)
                step = .complete
            }
        } catch {
            progressTask.cancel()
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }

        isRecording = false
    }
}
