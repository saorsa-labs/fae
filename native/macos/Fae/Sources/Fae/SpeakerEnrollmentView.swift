import AVFoundation
import SwiftUI

/// Guided 6-step speaker enrollment flow.
///
/// Steps:
///   1. Name — display name text field
///   2. Wake phrases — 4x "Hey Fae" recordings for acoustic template generation
///   3. Conversational — 3x 8-second free-speech samples for speaker embedding
///   4. Room noise — 20-second ambient baseline capture
///   5. Photo — optional camera reference image
///   6. Complete — atomic commit of all collected data
///
/// All data is committed atomically on step 6 — nothing is written to persistent
/// stores during earlier steps. If the user cancels before completing step 6,
/// no profile data is persisted.
struct SpeakerEnrollmentView: View {
    let captureManager: AudioCaptureManager
    let speakerEncoder: CoreMLSpeakerEncoder
    let speakerProfileStore: SpeakerProfileStore
    let wakeWordProfileStore: WakeWordProfileStore
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    /// Pre-filled name (e.g. from config.userName during first launch).
    var initialName: String = ""

    /// Optional callback to save the captured photo. Injected by ContentView
    /// so the enrollment view doesn't depend on FaeCore directly.
    var onPhotoCapture: ((Data) -> Void)?

    @State private var step: EnrollmentStep = .name
    @State private var displayName: String = ""

    // Wake phrase state (step 2)
    @State private var wakePhraseIndex: Int = 0
    @State private var wakeTemplates: [WakeWordAcousticDetector.Template] = []

    // Conversational state (step 3)
    @State private var conversationalIndex: Int = 0
    @State private var conversationalEmbeddings: [[Float]] = []

    // Shared recording state
    @State private var isRecording: Bool = false
    @State private var recordingProgress: Double = 0
    @State private var consistencyScore: Float = 0
    @State private var errorMessage: String?

    // Room noise state (step 4)
    @State private var noiseFloorRMS: Float = 0
    @State private var noiseProgress: Double = 0

    // Photo state (step 5)
    @State private var capturedPhoto: NSImage?
    @State private var capturedPhotoData: Data?
    @State private var isCapturingPhoto: Bool = false

    private static let wakePhraseCount = 4
    private static let wakeDuration: Double = 2.0
    private static let conversationalCount = 3
    private static let conversationalDuration: Double = 8.0
    private static let noiseDuration: Double = 20.0

    enum EnrollmentStep: Equatable {
        case name
        case wakePhrases
        case conversational
        case roomNoise
        case photo
        case complete
    }

    var body: some View {
        VStack(spacing: 24) {
            stepIndicator
            switch step {
            case .name:
                nameStep
            case .wakePhrases:
                wakePhraseStep
            case .conversational:
                conversationalStep
            case .roomNoise:
                roomNoiseStep
            case .photo:
                photoStep
            case .complete:
                completeStep
            }
        }
        .padding(32)
        .frame(width: 420, height: 500)
        .onAppear {
            if !initialName.isEmpty {
                displayName = initialName
            }
        }
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        let steps: [EnrollmentStep] = [.name, .wakePhrases, .conversational, .roomNoise, .photo, .complete]
        let currentIndex = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { index in
                Circle()
                    .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
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

                Button("Next") { step = .wakePhrases }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Step 2: Wake phrases

    private var wakePhraseStep: some View {
        VStack(spacing: 16) {
            Text("Wake phrase \(wakePhraseIndex + 1) of \(Self.wakePhraseCount)")
                .font(.title2.weight(.semibold))

            Text("Say this aloud in your natural voice:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("\"Hey Fae\"")
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .italic()
                .padding(.vertical, 4)

            recordingRing

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(isRecording ? "Listening…" : "Record") {
                    Task { await recordWakePhrase() }
                }
                .disabled(isRecording)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 3: Conversational

    /// Example phrases for each conversational sample.
    private static let conversationalPrompts: [[String]] = [
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

    private var conversationalStep: some View {
        VStack(spacing: 16) {
            Text("Voice sample \(conversationalIndex + 1) of \(Self.conversationalCount)")
                .font(.title2.weight(.semibold))

            Text("Read any of these aloud in your natural voice:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                let prompts = Self.conversationalPrompts[
                    min(conversationalIndex, Self.conversationalPrompts.count - 1)
                ]
                ForEach(prompts, id: \.self) { prompt in
                    Text(prompt)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(.primary.opacity(0.75))
                        .italic()
                }
            }
            .padding(.horizontal, 8)

            recordingRing

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(isRecording ? "Recording…" : "Record") {
                    Task { await recordConversationalSample() }
                }
                .disabled(isRecording)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 4: Room noise

    private var roomNoiseStep: some View {
        VStack(spacing: 16) {
            Text("Room noise baseline")
                .font(.title2.weight(.semibold))

            Text("Stay quiet for 20 seconds so I can learn your room's background noise.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 4)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: noiseProgress)
                    .stroke(
                        isRecording ? Color.blue : Color.accentColor,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: noiseProgress)

                Image(systemName: isRecording ? "waveform" : "ear")
                    .font(.title)
                    .foregroundStyle(isRecording ? .blue : .primary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(isRecording ? "Listening…" : "Start") {
                    Task { await recordRoomNoise() }
                }
                .disabled(isRecording)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 5: Photo

    private var photoStep: some View {
        VStack(spacing: 16) {
            Text("Let me see you")
                .font(.title2.weight(.semibold))

            Text("A quick photo helps me recognise you at your desk.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let photo = capturedPhoto {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.green.opacity(0.6), lineWidth: 2)
                    )
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 160, height: 160)
                    .overlay {
                        if isCapturingPhoto {
                            ProgressView()
                                .scaleEffect(1.2)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                    }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Skip for now") {
                    Task { await commitAndComplete() }
                }

                if capturedPhoto != nil {
                    Button("Retake") {
                        capturedPhoto = nil
                        capturedPhotoData = nil
                        Task { await capturePhoto() }
                    }

                    Button("Looks good") {
                        Task { await commitAndComplete() }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Take Photo") {
                        Task { await capturePhoto() }
                    }
                    .disabled(isCapturingPhoto)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: - Step 6: Complete

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Got it, \(displayName)!")
                .font(.title2.weight(.semibold))

            if capturedPhoto != nil {
                Text("I'll recognise your voice and face from now on.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text("I'll recognise your voice from now on.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("Voice consistency:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", consistencyScore * 100))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(consistencyScore > 0.7 ? .green : .orange)
                }
                HStack(spacing: 4) {
                    Text("Wake templates:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(wakeTemplates.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(wakeTemplates.count >= 2 ? .green : .orange)
                }
            }

            Button("Done") {
                onComplete(displayName)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Shared recording ring

    private var recordingRing: some View {
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
    }

    // MARK: - Wake phrase recording (Step 2)

    private func recordWakePhrase() async {
        isRecording = true
        recordingProgress = 0
        errorMessage = nil

        let progressTask = startPulsingProgress()

        do {
            let samples = try await captureManager.captureSegment(durationSeconds: Self.wakeDuration)
            progressTask.cancel()
            recordingProgress = 1.0

            let sampleRate = AudioCaptureManager.targetSampleRate
            if let template = WakeWordAcousticDetector.makeTemplate(
                samples: samples,
                sampleRate: sampleRate
            ) {
                wakeTemplates.append(template)
                NSLog(
                    "SpeakerEnrollmentView: wake phrase %d captured, duration=%.2fs",
                    wakePhraseIndex + 1,
                    template.durationSeconds
                )
            } else {
                NSLog(
                    "SpeakerEnrollmentView: wake phrase %d — template generation failed (too short/long or silent)",
                    wakePhraseIndex + 1
                )
                // Still advance — we'll just have fewer templates
            }

            wakePhraseIndex += 1
            recordingProgress = 0

            if wakePhraseIndex >= Self.wakePhraseCount {
                step = .conversational
            }
        } catch {
            progressTask.cancel()
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }

        isRecording = false
    }

    // MARK: - Conversational sample recording (Step 3)

    /// Maximum automatic retries when capture gets silence (mic warmup).
    private static let maxAutoRetries = 2

    private func recordConversationalSample() async {
        isRecording = true
        recordingProgress = 0
        errorMessage = nil

        let progressTask = startPulsingProgress()

        do {
            var samples: [Float] = []
            var quality = AudioCaptureManager.SegmentSpeechQuality(
                rms: 0, peak: 0, voicedFrameRatio: 0, voicedDurationSeconds: 0
            )

            for attempt in 0...Self.maxAutoRetries {
                samples = try await captureManager.captureSegment(
                    durationSeconds: Self.conversationalDuration
                )
                quality = AudioCaptureManager.analyzeSegment(samples)
                NSLog(
                    "SpeakerEnrollmentView: conv sample %d attempt %d quality rms=%.4f voiced_ratio=%.3f usable=%@",
                    conversationalIndex + 1,
                    attempt + 1,
                    quality.rms,
                    quality.voicedFrameRatio,
                    quality.hasUsableSpeech ? "true" : "false"
                )
                if quality.hasUsableSpeech { break }
                if attempt < Self.maxAutoRetries {
                    NSLog(
                        "SpeakerEnrollmentView: auto-retrying conv sample %d (attempt %d got silence)",
                        conversationalIndex + 1,
                        attempt + 1
                    )
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
            conversationalEmbeddings.append(embedding)
            conversationalIndex += 1
            recordingProgress = 0

            if conversationalIndex >= Self.conversationalCount {
                consistencyScore = SpeakerProfileStore.consistencyScore(conversationalEmbeddings)
                step = .roomNoise
            }
        } catch {
            progressTask.cancel()
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }

        isRecording = false
    }

    // MARK: - Room noise recording (Step 4)

    private func recordRoomNoise() async {
        isRecording = true
        noiseProgress = 0
        errorMessage = nil

        // Timed progress ring for noise capture (deterministic duration)
        let totalNanos = UInt64(Self.noiseDuration * 1_000_000_000)
        let tickNanos: UInt64 = 200_000_000 // 200ms ticks
        let ticks = Int(totalNanos / tickNanos)

        let progressTask = Task {
            for tick in 1...ticks {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: tickNanos)
                noiseProgress = Double(tick) / Double(ticks)
            }
        }

        do {
            let samples = try await captureManager.captureSegment(
                durationSeconds: Self.noiseDuration
            )
            progressTask.cancel()
            noiseProgress = 1.0

            // Compute RMS as noise floor
            if !samples.isEmpty {
                let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
                noiseFloorRMS = (sumSq / Float(samples.count)).squareRoot()
            }
            NSLog("SpeakerEnrollmentView: room noise baseline rms=%.5f", noiseFloorRMS)

            step = .photo
        } catch {
            progressTask.cancel()
            noiseProgress = 0
            errorMessage = "Noise capture failed: \(error.localizedDescription)"
        }

        isRecording = false
    }

    // MARK: - Atomic commit (called from photo step)

    /// Commits all enrollment data atomically. Nothing is written to persistent
    /// stores before this point — if the user cancels at any earlier step,
    /// no partial data is persisted.
    private func commitAndComplete() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Enroll speaker profile (conversational embeddings)
        if !conversationalEmbeddings.isEmpty {
            await speakerProfileStore.bulkEnroll(
                label: "owner",
                embeddings: conversationalEmbeddings,
                role: .owner,
                displayName: trimmedName
            )
        }

        // 2. Record acoustic wake templates
        for template in wakeTemplates {
            await wakeWordProfileStore.recordAcousticTemplate(
                template,
                phrase: "Hey Fae",
                source: "enrollment"
            )
        }

        // 3. Save photo if captured
        if let data = capturedPhotoData {
            onPhotoCapture?(data)
        }

        NSLog(
            "SpeakerEnrollmentView: enrollment committed — name=%@ conv=%d wake=%d photo=%@",
            trimmedName,
            conversationalEmbeddings.count,
            wakeTemplates.count,
            capturedPhotoData != nil ? "yes" : "no"
        )

        step = .complete
    }

    // MARK: - Photo capture (Step 5)

    private func capturePhoto() async {
        isCapturingPhoto = true
        errorMessage = nil

        let frameCapture = CameraFrameCapture()
        do {
            let cgImage = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CGImage, Error>) in
                frameCapture.captureFrame { result in
                    continuation.resume(with: result)
                }
            }

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            capturedPhoto = nsImage

            if let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            {
                capturedPhotoData = jpegData
            }
        } catch {
            errorMessage = "Camera capture failed: \(error.localizedDescription)"
            NSLog("SpeakerEnrollmentView: photo capture failed — %@", error.localizedDescription)
        }

        isCapturingPhoto = false
    }

    // MARK: - Helpers

    /// Starts a pulsing progress animation task (0.2 ↔ 0.8).
    /// Caller must cancel the returned task when recording completes.
    private func startPulsingProgress() -> Task<Void, Never> {
        Task {
            var up = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if up {
                    recordingProgress = min(recordingProgress + 0.02, 0.8)
                    if recordingProgress >= 0.8 { up = false }
                } else {
                    recordingProgress = max(recordingProgress - 0.01, 0.2)
                    if recordingProgress <= 0.2 { up = true }
                }
            }
        }
    }
}

// MARK: - Camera Frame Capture (reusable)

/// Captures a single frame from the default camera with auto-exposure warm-up.
///
/// Used by both the enrollment photo step and VisionTools. This class handles
/// AVCaptureSession setup, waits for the sensor to auto-expose, then delivers
/// a single CGImage via the completion handler.
private final class CameraFrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var frameCount = 0
    private static let warmUpFrames = 8

    enum CameraError: Error, LocalizedError {
        case noCamera
        case captureSetupFailed
        case noFrame

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera available"
            case .captureSetupFailed: return "Failed to set up camera capture"
            case .noFrame: return "No frame captured"
            }
        }
    }

    func captureFrame(completion: @escaping (Result<CGImage, Error>) -> Void) {
        self.completion = completion

        guard let device = AVCaptureDevice.default(for: .video) else {
            completion(.failure(CameraError.noCamera))
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                completion(.failure(CameraError.captureSetupFailed))
                return
            }
            session.addInput(input)
        } catch {
            completion(.failure(error))
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let queue = DispatchQueue(label: "com.saorsalabs.fae.enrollment-photo")
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            completion(.failure(CameraError.captureSetupFailed))
            return
        }
        session.addOutput(output)

        self.session = session
        session.startRunning()
    }

    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        frameCount += 1
        guard frameCount > Self.warmUpFrames else { return }

        session?.stopRunning()
        session = nil

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            completion?(.failure(CameraError.noFrame))
            completion = nil
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            completion?(.failure(CameraError.noFrame))
            completion = nil
            return
        }

        completion?(.success(cgImage))
        completion = nil
    }
}
