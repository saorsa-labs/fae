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
    private static let sampleDuration: Double = 4.0

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
        .frame(width: 400, height: 340)
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

    private var recordingStep: some View {
        VStack(spacing: 20) {
            Text("Voice Sample \(sampleIndex + 1) of \(Self.sampleCount)")
                .font(.title2.weight(.semibold))

            Text("Say something for a few seconds so I can learn your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
    private func recordSample() async {
        isRecording = true
        recordingProgress = 0
        errorMessage = nil

        // Animate progress ring.
        let progressTask = Task {
            let steps = 40
            for i in 1...steps {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(Self.sampleDuration / Double(steps) * 1_000_000_000))
                recordingProgress = Double(i) / Double(steps)
            }
        }

        do {
            let samples = try await captureManager.captureSegment(durationSeconds: Self.sampleDuration)
            progressTask.cancel()
            recordingProgress = 1.0

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
