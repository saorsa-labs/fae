import AppKit
import AVFoundation
import CoreImage

/// Captures a single camera frame and returns JPEG data for progressive visual identity updates.
///
/// Used by FaeCore to silently refresh the owner's reference photo during
/// proactive camera observations. Handles AVCaptureSession setup, waits for
/// auto-exposure warm-up, then delivers JPEG data.
final class ProgressivePhotoCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var frameCount = 0
    private static let warmUpFrames = 8

    enum CaptureError: Error, LocalizedError {
        case noCamera
        case setupFailed
        case noFrame
        case jpegConversionFailed

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera available"
            case .setupFailed: return "Failed to set up camera"
            case .noFrame: return "No frame captured"
            case .jpegConversionFailed: return "JPEG conversion failed"
            }
        }
    }

    /// Capture a single frame and return it as JPEG data.
    func captureJPEG(completion: @escaping (Result<Data, Error>) -> Void) {
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
        let queue = DispatchQueue(label: "com.saorsalabs.fae.progressive-photo")
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

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else {
            completion?(.failure(CaptureError.jpegConversionFailed))
            completion = nil
            return
        }

        completion?(.success(jpegData))
        completion = nil
    }
}
