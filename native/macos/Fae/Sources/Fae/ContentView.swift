import AppKit
import SwiftUI

/// Reduced companion window content.
///
/// The Rust orb host is the product UI. This window survives only as the
/// text-input companion surface ("Ask Fae"), the onboarding/enrollment host,
/// and the startup holding view. It stays hidden while the orb host runs and
/// is surfaced only by explicit user actions (Ask Fae, global hotkey).
struct ContentView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
    @EnvironmentObject private var subtitles: SubtitleStateController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var onboarding: OnboardingController
    @EnvironmentObject private var auxiliaryWindows: AuxiliaryWindowManager
    @EnvironmentObject private var faeCore: FaeCore
    @State private var showingNativeEnrollment = false
    @State private var showingPhotoCapture = false
    @State private var listeningBeforeNativeEnrollment = true

    var body: some View {
        VStack(spacing: 0) {
            if pipelineAux.isPipelineReady {
                // Voice hints — collapsible cheat sheet for wake/silence phrases.
                VoiceHintsView()

                // Conversation — scrolling, fills remaining space.
                ConversationScrollView()

                // Subtle separator
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)

                // Enrollment invitation — visible until owner voice is enrolled.
                if !ownerEnrollmentComplete {
                    EnrollmentInvitationBanner {
                        beginNativeEnrollment()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Photo setup — visible after voice enrollment until a photo is taken.
                // Gate on hasOwnerSetUp (synced from speaker profile store during
                // startup) rather than ownerEnrollmentComplete to avoid showing the
                // photo banner during the brief window before the owner check runs.
                if faeCore.hasOwnerSetUp && !faeCore.hasOwnerPhoto {
                    PhotoSetupBanner {
                        showingPhotoCapture = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Input — pinned at bottom once startup fully completes.
                InputBarView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                startupHoldingView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            NSWindowAccessor { window in
                windowState.window = window
            }
        )
        .animation(.easeInOut(duration: 0.4), value: ownerEnrollmentComplete)
        .animation(.easeInOut(duration: 0.4), value: faeCore.hasOwnerPhoto)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isStateRestored)
        .animation(.easeInOut(duration: 0.2), value: auxiliaryWindows.isApprovalVisible)
        .overlay {
            // Emergency stop — visible whenever a tool approval is pending
            if auxiliaryWindows.isApprovalVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { auxiliaryWindows.emergencyStop() }) {
                            Label("Stop", systemImage: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(FaeDesign.rowanBerry)
                        .clipShape(Capsule())
                        .shadow(color: FaeDesign.rowanBerry.opacity(0.5), radius: 6)
                        .padding(.trailing, 10)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .sheet(isPresented: $showingNativeEnrollment) {
            SpeakerEnrollmentView(
                captureManager: faeCore.nativeEnrollmentCaptureManager,
                speakerEncoder: faeCore.nativeEnrollmentSpeakerEncoder,
                speakerProfileStore: faeCore.nativeEnrollmentSpeakerProfileStore,
                wakeWordProfileStore: faeCore.nativeEnrollmentWakeWordProfileStore,
                onComplete: { enrolledName in
                    showingNativeEnrollment = false
                    let trimmedName = enrolledName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty {
                        onboarding.userName = trimmedName
                    }
                    onboarding.isComplete = true
                    restoreConversationAfterNativeEnrollment()
                    faeCore.completeNativeOwnerEnrollment(displayName: enrolledName)
                },
                onCancel: {
                    showingNativeEnrollment = false
                    restoreConversationAfterNativeEnrollment()
                },
                initialName: onboarding.userName ?? faeCore.userName ?? "",
                onPhotoCapture: { jpegData in
                    faeCore.saveOwnerPhoto(jpegData: jpegData, description: nil)
                }
            )
            .preferredColorScheme(nil)
        }
        .sheet(isPresented: $showingPhotoCapture) {
            OwnerPhotoCaptureView(
                onComplete: { jpegData in
                    showingPhotoCapture = false
                    faeCore.saveOwnerPhoto(jpegData: jpegData, description: nil)
                },
                onSkip: {
                    showingPhotoCapture = false
                }
            )
            .preferredColorScheme(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeStartNativeEnrollmentRequested)) { _ in
            windowState.showWindow()
            beginNativeEnrollment()
        }
    }

    private var ownerEnrollmentComplete: Bool {
        onboarding.isComplete || faeCore.hasOwnerSetUp
    }

    private var startupHoldingView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(Color.primary.opacity(0.45))

            Text("Fae is starting")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundColor(.primary.opacity(0.88))

            Text(startupDetailText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 320)

            Text("The conversation surface unlocks when downloads, model loading, and warmup are complete.")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.primary.opacity(0.42))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 360)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var startupDetailText: String {
        if !subtitles.progressLabel.isEmpty {
            return subtitles.progressLabel
        }
        if !pipelineAux.status.isEmpty {
            return pipelineAux.status
        }
        return "Loading local components…"
    }

    private func beginNativeEnrollment() {
        listeningBeforeNativeEnrollment = conversation.isListening
        NotificationCenter.default.post(name: .faeCancelGeneration, object: nil)
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": false]
        )
        showingNativeEnrollment = true
    }

    private func restoreConversationAfterNativeEnrollment() {
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": listeningBeforeNativeEnrollment]
        )
    }
}

// MARK: - Menu Action Handler

/// Retained Objective-C target for programmatic `NSMenuItem` actions.
final class MenuActionHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

// MARK: - Enrollment Invitation Banner

/// Shown above the input bar until the owner voice is enrolled.
/// Tapping it triggers the enrollment conversation with Fae.
private struct EnrollmentInvitationBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.person.filled")
                    .font(.system(size: 13))
                    .foregroundStyle(FaeDesign.heatherMistText)

                Text("Let me get to know you")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(FaeDesign.heatherMist.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Photo Setup Banner

/// Shown after voice enrollment until the owner takes a reference photo.
/// Tapping opens the enrollment flow which now includes a photo step.
private struct PhotoSetupBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(FaeDesign.heatherMistText)

                Text("Let Fae see you — tap to take a quick photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(FaeDesign.heatherMist.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Owner Photo Capture View

/// Standalone photo capture sheet for existing users who skipped the photo
/// during initial enrollment. Shown when tapping the PhotoSetupBanner.
private struct OwnerPhotoCaptureView: View {
    let onComplete: (Data) -> Void
    let onSkip: () -> Void

    @State private var capturedPhoto: NSImage?
    @State private var capturedPhotoData: Data?
    @State private var isCapturing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
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
                            .stroke(FaeDesign.glenGreen.opacity(0.6), lineWidth: 2)
                    )
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 160, height: 160)
                    .overlay {
                        if isCapturing {
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
                    .foregroundStyle(FaeDesign.statusError)
            }

            HStack(spacing: 12) {
                Button("Not now") { onSkip() }
                    .keyboardShortcut(.cancelAction)

                if let data = capturedPhotoData {
                    Button("Retake") {
                        capturedPhoto = nil
                        capturedPhotoData = nil
                        Task { await capturePhoto() }
                    }

                    Button("Looks good") {
                        onComplete(data)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Take Photo") {
                        Task { await capturePhoto() }
                    }
                    .disabled(isCapturing)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: 380, height: 380)
    }

    private func capturePhoto() async {
        isCapturing = true
        errorMessage = nil

        let frameCapture = OwnerPhotoFrameCapture()
        do {
            let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
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
        }

        isCapturing = false
    }
}

// MARK: - Photo Frame Capture (ContentView-local)

import AVFoundation

/// Captures a single camera frame for the standalone photo capture sheet.
private final class OwnerPhotoFrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var frameCount = 0
    private static let warmUpFrames = 8

    enum CaptureError: Error, LocalizedError {
        case noCamera
        case setupFailed
        case noFrame

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera available"
            case .setupFailed: return "Failed to set up camera"
            case .noFrame: return "No frame captured"
            }
        }
    }

    func captureFrame(completion: @escaping (Result<CGImage, Error>) -> Void) {
        self.completion = completion

        guard let device = AVCaptureDevice.default(for: .video) else {
            completion(.failure(CaptureError.noCamera))
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                completion(.failure(CaptureError.setupFailed))
                return
            }
            session.addInput(input)
        } catch {
            completion(.failure(error))
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let queue = DispatchQueue(label: "com.saorsalabs.fae.owner-photo")
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            completion(.failure(CaptureError.setupFailed))
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
            completion?(.failure(CaptureError.noFrame))
            completion = nil
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            completion?(.failure(CaptureError.noFrame))
            completion = nil
            return
        }

        completion?(.success(cgImage))
        completion = nil
    }
}
