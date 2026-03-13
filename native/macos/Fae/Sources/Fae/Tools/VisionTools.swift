import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

/// Closure type for on-demand VLM access. Tools call this to get the engine,
/// which triggers model loading if needed.
typealias VLMProvider = @Sendable () async throws -> (any VLMEngine)?

private enum ComputerUseSafety {
    static func validateElementTarget(_ element: AccessibilityBridge.UIElement) -> ToolResult? {
        if AccessibilityBridge.isDeniedAutomationTarget(pid: element.pid) {
            return .error("Refusing to automate protected system surfaces for safety.")
        }
        if !AccessibilityBridge.isFrontmostApp(pid: element.pid) {
            let appName = element.appName ?? "target app"
            return .error("Bring \(appName) to the foreground before taking action.")
        }
        if !element.isEnabled {
            return .error("Target element is disabled. Re-run read_screen and choose an enabled control.")
        }
        return nil
    }

    static func validatePoint(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) }
    }
}

enum DesktopWindowSelection {
    struct CaptureWindowCandidate: Sendable, Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let appName: String
        let title: String?
        let frame: CGRect
    }

    struct VisibleWindow: Sendable, Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let ownerName: String
        let title: String?
        let layer: Int
        let bounds: CGRect
    }

    static func orderedVisibleWindows() -> [VisibleWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { item in
            guard let windowNumber = item[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let ownerName = item[kCGWindowOwnerName as String] as? String,
                  !ownerName.isEmpty
            else {
                return nil
            }

            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else { return nil }

            let boundsDict = item[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            return VisibleWindow(
                windowID: CGWindowID(windowNumber.uint32Value),
                processID: ownerPID.int32Value,
                ownerName: ownerName,
                title: item[kCGWindowName as String] as? String,
                layer: item[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds
            )
        }
    }

    static func selectCaptureWindow(
        candidates: [CaptureWindowCandidate],
        preferredAppName: String?,
        frontmostPID: pid_t?,
        orderedWindows: [VisibleWindow]
    ) -> CaptureWindowCandidate? {
        let scopedCandidates: [CaptureWindowCandidate]
        if let preferredAppName, !preferredAppName.isEmpty {
            scopedCandidates = candidates.filter { $0.appName.localizedCaseInsensitiveContains(preferredAppName) }
        } else if let frontmostPID {
            scopedCandidates = candidates.filter { $0.processID == frontmostPID }
        } else {
            scopedCandidates = candidates
        }

        guard !scopedCandidates.isEmpty else { return nil }

        return scopedCandidates.max { lhs, rhs in
            scoreCaptureWindow(lhs, orderedWindows: orderedWindows) < scoreCaptureWindow(rhs, orderedWindows: orderedWindows)
        }
    }

    static func resolveFallbackTypingTargetName(
        explicitAppName: String?,
        frontmostAppName: String?,
        orderedWindows: [VisibleWindow],
        excludedAppNames: Set<String>
    ) -> String? {
        if let explicitAppName,
           !explicitAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return explicitAppName
        }

        if let frontmostAppName,
           !excludedAppNames.contains(frontmostAppName.lowercased())
        {
            return frontmostAppName
        }

        if let window = orderedWindows.first(where: {
            $0.layer == 0 && !excludedAppNames.contains($0.ownerName.lowercased())
        }) {
            return window.ownerName
        }

        return orderedWindows.first(where: {
            !excludedAppNames.contains($0.ownerName.lowercased())
        })?.ownerName
    }

    private static func scoreCaptureWindow(
        _ candidate: CaptureWindowCandidate,
        orderedWindows: [VisibleWindow]
    ) -> Int {
        let orderedIndex = orderedWindows.firstIndex(where: { $0.windowID == candidate.windowID })
        let orderedMatch = orderedIndex.flatMap { orderedWindows[$0] }
        let hasTitle = !(candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let area = candidate.frame.width * candidate.frame.height

        var score = 0
        if let orderedIndex {
            score += max(0, 1_000 - (orderedIndex * 20))
        }
        if orderedMatch?.layer == 0 {
            score += 400
        }
        if hasTitle {
            score += 250
        }
        if area >= 120_000 {
            score += 150
        } else if area >= 40_000 {
            score += 75
        }
        return score
    }
}

@MainActor
private enum ScreenImageCapture {
    private static let protectedFrontmostBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowManager",
    ]

    private static let protectedFrontmostNames: Set<String> = [
        "loginwindow",
        "windowmanager",
    ]

    static func capture(appName: String?) async throws -> CGImage {
        NSLog("ScreenImageCapture: resolving shareable content app=%@", appName ?? "<all>")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        NSLog(
            "ScreenImageCapture: content displays=%d windows=%d applications=%d",
            content.displays.count,
            content.windows.count,
            content.applications.count
        )

        let filter: SCContentFilter
        let orderedWindows = DesktopWindowSelection.orderedVisibleWindows()
        let candidates = content.windows.compactMap { window -> DesktopWindowSelection.CaptureWindowCandidate? in
            guard let app = window.owningApplication else { return nil }
            return DesktopWindowSelection.CaptureWindowCandidate(
                windowID: window.windowID,
                processID: app.processID,
                appName: app.applicationName,
                title: window.title,
                frame: window.frame
            )
        }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostPID: pid_t? = {
            guard let frontmostApp, !isProtectedFrontmostTarget(frontmostApp) else { return nil }
            return frontmostApp.processIdentifier
        }()

        if let targetCandidate = DesktopWindowSelection.selectCaptureWindow(
            candidates: candidates,
            preferredAppName: appName,
            frontmostPID: frontmostPID,
            orderedWindows: orderedWindows
        ),
           let targetWindow = content.windows.first(where: { $0.windowID == targetCandidate.windowID })
        {
            NSLog(
                "ScreenImageCapture: targeting window app=%@ title=%@ windowID=%@",
                targetCandidate.appName,
                targetCandidate.title ?? "<untitled>",
                String(targetWindow.windowID)
            )
            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        } else if appName != nil, let display = content.displays.first {
            NSLog(
                "ScreenImageCapture: app matched but no usable window found, falling back to display %@",
                String(display.displayID)
            )
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if frontmostApp != nil {
            let display = try displayForActiveContext(in: content)
            NSLog(
                "ScreenImageCapture: frontmost app had no usable window, falling back to display %@",
                String(display.displayID)
            )
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            let display = try displayForActiveContext(in: content)
            NSLog("ScreenImageCapture: no frontmost app, targeting display %@", String(display.displayID))
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.scalesToFit = true
        config.showsCursor = false

        NSLog("ScreenImageCapture: captureImage starting")
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        NSLog("ScreenImageCapture: captureImage finished size=%dx%d", image.width, image.height)
        return image
    }

    private static func displayForActiveContext(in content: SCShareableContent) throws -> SCDisplay {
        let mouseLocation = NSEvent.mouseLocation
        if let pointedDisplay = content.displays.first(where: { $0.frame.contains(mouseLocation) }) {
            return pointedDisplay
        }
        if let mainScreenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let mainDisplay = content.displays.first(where: { $0.displayID == CGDirectDisplayID(mainScreenID.uint32Value) })
        {
            return mainDisplay
        }
        if let firstDisplay = content.displays.first {
            return firstDisplay
        }
        throw ScreenshotTool.ScreenshotError.noDisplay
    }

    private static func isProtectedFrontmostTarget(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, protectedFrontmostBundleIDs.contains(bundleID) {
            return true
        }
        if let name = app.localizedName?.lowercased(), protectedFrontmostNames.contains(name) {
            return true
        }
        return false
    }
}

// MARK: - Screenshot Tool

/// Captures the screen (or a specific app window) and describes it via the VLM.
struct ScreenshotTool: Tool {
    let name = "screenshot"
    let description = "Take a screenshot and describe what's visible. Use when asked about screen content, helping with apps, or 'look at this'."
    let parametersSchema = #"{"prompt":{"type":"string","description":"What to look for or describe"},"app":{"type":"string","description":"Optional: capture only this app's window"}}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .medium
    let example = #"<tool_call>{"name":"screenshot","arguments":{"prompt":"What app is open on screen?"}}</tool_call>"#

    /// Injected by PipelineCoordinator before execution.
    var vlmProvider: VLMProvider?

    func execute(input: [String: Any]) async throws -> ToolResult {
        let prompt = input["prompt"] as? String ?? "Describe what you see on screen."
        let appName = input["app"] as? String

        // Check screen recording permission.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .error("Screen Recording permission required. Please grant it in System Settings > Privacy & Security > Screen Recording, then try again.")
        }

        guard let provider = vlmProvider else {
            return .error("Vision is not available — enable it in Settings > Models.")
        }

        guard let vlm = try await provider() else {
            return .error("Vision model could not be loaded — insufficient RAM or vision disabled.")
        }

        // Capture the screen or specific app window.
        let image: CGImage
        do {
            NSLog("ScreenshotTool: capture starting app=%@", appName ?? "<all>")
            image = try await captureScreen(appName: appName)
            NSLog("ScreenshotTool: capture finished size=%dx%d", image.width, image.height)
        } catch {
            return .error("Screenshot failed: \(error.localizedDescription)")
        }

        // Send to VLM for description.
        let options = GenerationOptions(
            temperature: 0.3,
            topP: 0.9,
            maxTokens: 1024,
            suppressThinking: true
        )

        var result = ""
        NSLog("ScreenshotTool: vlm describe starting prompt=%@", prompt)
        let stream = await vlm.describe(image: image, prompt: prompt, options: options)
        do {
            for try await chunk in stream {
                result += chunk
            }
            NSLog("ScreenshotTool: vlm describe finished chars=%d", result.count)
        } catch {
            return .error("VLM description failed: \(error.localizedDescription)")
        }

        let width = image.width
        let height = image.height
        return .success("Screenshot (\(width)x\(height)):\n\(result)")
    }

    /// Capture the screen or a specific app window using ScreenCaptureKit.
    private func captureScreen(appName: String?) async throws -> CGImage {
        try await ScreenImageCapture.capture(appName: appName)
    }

    enum ScreenshotError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display found for screenshot"
            }
        }
    }
}

// MARK: - Camera Tool

/// Captures a single frame from the Mac's camera and describes it via the VLM.
struct CameraTool: Tool {
    let name = "camera"
    let description = "Capture a photo using the webcam camera and describe what is visible. ALWAYS use this tool when the user asks you to look at them, see them, or asks about the camera — do not just talk about it, actually call this tool."
    let parametersSchema = #"{"prompt":{"type":"string","description":"What to look for or describe"}}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .medium
    let example = #"<tool_call>{"name":"camera","arguments":{"prompt":"What do you see?"}}</tool_call>"#

    var vlmProvider: VLMProvider?

    func execute(input: [String: Any]) async throws -> ToolResult {
        let prompt = input["prompt"] as? String ?? "Describe what you see."

        // Check camera permission.
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                return .error("Camera permission denied. Please grant it in System Settings > Privacy & Security > Camera.")
            }
        } else if cameraStatus != .authorized {
            return .error("Camera permission required. Please grant it in System Settings > Privacy & Security > Camera.")
        }

        guard let provider = vlmProvider else {
            return .error("Vision is not available — enable it in Settings > Models.")
        }

        guard let vlm = try await provider() else {
            return .error("Vision model could not be loaded — insufficient RAM or vision disabled.")
        }

        // Capture a single frame from the camera.
        let image: CGImage
        do {
            image = try await captureCameraFrame()
        } catch {
            return .error("Camera capture failed: \(error.localizedDescription)")
        }

        let options = GenerationOptions(
            temperature: 0.3,
            topP: 0.9,
            maxTokens: 1024,
            suppressThinking: true
        )

        var result = ""
        let stream = await vlm.describe(image: image, prompt: prompt, options: options)
        do {
            for try await chunk in stream {
                result += chunk
            }
        } catch {
            return .error("VLM description failed: \(error.localizedDescription)")
        }

        return .success("Camera capture:\n\(result)")
    }

    /// Capture a single frame from the default camera.
    private func captureCameraFrame() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let captureHelper = CameraFrameCapture()
            captureHelper.captureFrame { result in
                _ = captureHelper  // Strong capture — prevent ARC deallocation before callback.
                switch result {
                case .success(let cgImage):
                    continuation.resume(returning: cgImage)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Helper class to capture a single camera frame using AVCaptureVideoDataOutput.
/// Uses video data output (not AVCapturePhotoOutput) to avoid a macOS linking issue
/// where AVCapturePhotoOutput's KVO proxy class isn't resolved at runtime.
private final class CameraFrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var frameCount = 0
    // How many frames to skip while the sensor auto-exposes. Cameras typically
    // need 5-10 frames (~200-400ms at 30fps) before the image is bright enough.
    private static let warmUpFrames = 8

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
                completion(.failure(CameraError.configFailed))
                return
            }
            session.addInput(input)
        } catch {
            completion(.failure(error))
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let queue = DispatchQueue(label: "fae.camera.capture", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            completion(.failure(CameraError.configFailed))
            return
        }
        session.addOutput(output)
        self.session = session
        session.startRunning()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCount += 1
        // Skip the first N frames while the sensor warms up and auto-exposes.
        // Frame 0 is nearly always black; 8 frames at 30fps ≈ 270ms warm-up.
        guard frameCount > Self.warmUpFrames else { return }
        // Only convert and deliver once.
        guard frameCount == Self.warmUpFrames + 1 else { return }

        defer { session?.stopRunning() }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            completion?(.failure(CameraError.noImage))
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let rect = ciImage.extent
        guard let cgImage = context.createCGImage(ciImage, from: rect) else {
            completion?(.failure(CameraError.noImage))
            return
        }

        completion?(.success(cgImage))
    }

    enum CameraError: LocalizedError {
        case noCamera
        case configFailed
        case noImage

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera found"
            case .configFailed: return "Camera configuration failed"
            case .noImage: return "Failed to capture image"
            }
        }
    }
}

// MARK: - Read Screen Tool (hybrid vision + accessibility)

/// Captures the screen and queries the Accessibility API for interactive elements.
struct ReadScreenTool: Tool {
    let name = "read_screen"
    let description = "Read the screen: capture screenshot + list interactive UI elements (buttons, fields, menus). Returns visual description and numbered element list for click/type_text actions."
    let parametersSchema = #"{"app":{"type":"string","description":"Optional: focus on this app only"}}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .medium  // Read-only tool — matches screenshot/camera.
    let example = #"<tool_call>{"name":"read_screen","arguments":{"app":"Safari"}}</tool_call>"#

    var vlmProvider: VLMProvider?

    func execute(input: [String: Any]) async throws -> ToolResult {
        let appName = input["app"] as? String

        // Check screen recording permission.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return .error("Screen Recording permission required. Please grant it in System Settings > Privacy & Security > Screen Recording.")
        }

        // Check accessibility permission.
        guard AccessibilityBridge.isAccessibilityEnabled() else {
            AccessibilityBridge.requestAccessibility()
            return .error("Accessibility permission required. Please grant it in System Settings > Privacy & Security > Accessibility.")
        }

        // Query UI elements.
        let elements: [AccessibilityBridge.UIElement]
        do {
            elements = try AccessibilityBridge.queryElements(appName: appName)
        } catch {
            return .error("Failed to query UI elements: \(error.localizedDescription)")
        }

        // Build element list.
        var elementList = "Interactive elements:\n"
        for elem in elements.prefix(50) {
            let title = elem.title ?? "(no title)"
            let enabled = elem.isEnabled ? "" : " [disabled]"
            let secure = elem.isSecureInput ? " [secure]" : ""
            elementList += "[\(elem.elementIndex)] \(elem.role): \(title)\(enabled)\(secure) at (\(Int(elem.frame.midX)),\(Int(elem.frame.midY)))\n"
        }
        if elements.count > 50 {
            elementList += "... and \(elements.count - 50) more elements\n"
        }

        // If VLM is available, also describe the screenshot.
        var visualDescription = ""
        if let provider = vlmProvider, let vlm = try await provider() {
            do {
                let image = try await captureScreen(appName: appName)
                NSLog("ReadScreenTool: capture finished size=%dx%d", image.width, image.height)
                let options = GenerationOptions(
                    temperature: 0.3, topP: 0.9, maxTokens: 512, suppressThinking: true
                )
                var desc = ""
                NSLog("ReadScreenTool: vlm describe starting")
                let stream = await vlm.describe(
                    image: image,
                    prompt: "Briefly describe what's visible on screen. Focus on the main app and its state.",
                    options: options
                )
                for try await chunk in stream { desc += chunk }
                NSLog("ReadScreenTool: vlm describe finished chars=%d", desc.count)
                visualDescription = "Visual overview: \(desc)\n\n"
            } catch {
                visualDescription = "Visual capture unavailable: \(error.localizedDescription)\n\n"
            }
        }

        return .success("\(visualDescription)\(elementList)")
    }

    private func captureScreen(appName: String?) async throws -> CGImage {
        try await ScreenImageCapture.capture(appName: appName)
    }
}

// MARK: - Click Tool

/// Clicks a UI element by index (from read_screen) or by screen coordinates.
struct ClickTool: Tool {
    let name = "click"
    let description = "Click a UI element. Use element_index from read_screen results (preferred) or x/y screen coordinates."
    let parametersSchema = #"{"element_index":{"type":"integer","description":"Element index from read_screen"},"x":{"type":"number","description":"Screen X coordinate"},"y":{"type":"number","description":"Screen Y coordinate"},"app":{"type":"string","description":"App name (required with element_index)"}}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"click","arguments":{"element_index":3,"app":"Safari"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard AccessibilityBridge.isAccessibilityEnabled() else {
            AccessibilityBridge.requestAccessibility()
            return .error("Accessibility permission required.")
        }

        // Element-based click (preferred).
        if let index = input["element_index"] as? Int {
            let appName = input["app"] as? String
            do {
                let elements = try AccessibilityBridge.queryElements(appName: appName)
                guard let elem = elements.first(where: { $0.elementIndex == index }) else {
                    return .error("Element \(index) not found. Run read_screen to refresh the element list.")
                }
                if let safetyError = ComputerUseSafety.validateElementTarget(elem) {
                    return safetyError
                }
                try AccessibilityBridge.pressElement(pid: elem.pid, frame: elem.frame)
                return .success("Clicked element [\(index)]: \(elem.role) '\(elem.title ?? "")'")
            } catch {
                return .error("Click failed: \(error.localizedDescription)")
            }
        }

        // Coordinate-based click.
        if let x = input["x"] as? Double, let y = input["y"] as? Double {
            let point = CGPoint(x: x, y: y)
            guard ComputerUseSafety.validatePoint(point) else {
                return .error("Coordinates (\(Int(x)), \(Int(y))) are outside visible displays.")
            }

            guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  !AccessibilityBridge.isDeniedAutomationTarget(pid: frontmostPID)
            else {
                return .error("Refusing to click on a protected system surface.")
            }

            guard let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return .error("Failed to create mouse event")
            }
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
            return .success("Clicked at (\(Int(x)), \(Int(y)))")
        }

        return .error("Provide either element_index or x/y coordinates.")
    }
}

// MARK: - Type Text Tool

/// Types text into a UI element or at the current cursor position.
struct TypeTextTool: Tool {
    let name = "type_text"
    let description = "Type text into a field. Use element_index from read_screen (preferred) or types at current cursor position."
    let parametersSchema = #"{"text":{"type":"string","description":"Text to type","required":true},"element_index":{"type":"integer","description":"Element index from read_screen"},"app":{"type":"string","description":"App name (required with element_index)"}}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"type_text","arguments":{"text":"Hello world","element_index":5,"app":"Notes"}}</tool_call>"#

    private struct ResolvedTypingTarget: Sendable {
        let pid: pid_t
        let appName: String
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let items = pasteboard.pasteboardItems?.map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            } ?? []
            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { itemData -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in itemData {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    private static let preferredTextRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
    ]

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let text = input["text"] as? String, !text.isEmpty else {
            return .error("Missing required parameter: text")
        }

        guard AccessibilityBridge.isAccessibilityEnabled() else {
            AccessibilityBridge.requestAccessibility()
            return .error("Accessibility permission required.")
        }

        // Element-based typing (preferred).
        if let index = input["element_index"] as? Int {
            let appName = input["app"] as? String
            do {
                let elements = try AccessibilityBridge.queryElements(appName: appName)
                guard let elem = elements.first(where: { $0.elementIndex == index }) else {
                    return .error("Element \(index) not found. Run read_screen to refresh.")
                }
                if let safetyError = ComputerUseSafety.validateElementTarget(elem) {
                    return safetyError
                }
                if elem.isSecureInput {
                    return .error("Refusing to type into a secure text field.")
                }

                try AccessibilityBridge.setValue(text, pid: elem.pid, frame: elem.frame)
                return .success("Typed text into element [\(index)] (\(text.count) chars).")
            } catch {
                return .error("Type failed: \(error.localizedDescription)")
            }
        }

        // Fallback: activate the real target app, paste the text, and verify it landed.
        let orderedVisibleWindows = DesktopWindowSelection.orderedVisibleWindows()
        guard let target = await Self.resolveTypingTarget(
            explicitAppName: input["app"] as? String,
            orderedVisibleWindows: orderedVisibleWindows
        )
        else {
            return .error("Couldn't determine which app to type into. Bring the target window to the foreground or specify an app.")
        }

        if AccessibilityBridge.isDeniedAutomationTarget(pid: target.pid) {
            return .error("Refusing to type into a protected system surface.")
        }

        guard await Self.activateTargetApp(target) else {
            return .error("Bring \(target.appName) to the foreground before typing.")
        }

        let beforeSnapshot = Self.focusedSnapshot(pid: target.pid)
        if beforeSnapshot?.isSecureInput == true {
            return .error("Refusing to type into a secure text field.")
        }

        let beforeValue = Self.preferredTextValue(appName: target.appName) ?? beforeSnapshot?.value

        if let targetElement = Self.preferredTextElement(appName: target.appName) {
            if targetElement.isSecureInput {
                return .error("Refusing to type into a secure text field.")
            }

            let replacementValue = (targetElement.value ?? beforeValue ?? "") + text
            do {
                try AccessibilityBridge.setValue(replacementValue, pid: targetElement.pid, frame: targetElement.frame)
                try? await Task.sleep(nanoseconds: 250_000_000)
                let afterValue = Self.preferredTextValue(appName: target.appName) ?? Self.focusedSnapshot(pid: target.pid)?.value
                if Self.didVerifyTypedText(text, beforeValue: beforeValue, afterValue: afterValue) {
                    return .success("Typed text in \(target.appName) (\(text.count) chars).")
                }
            } catch {
                // Fall back to paste-based input when AX value mutation is unavailable.
            }
        }

        guard await Self.pasteText(text) else {
            return .error("Failed to synthesize paste input.")
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let afterSnapshot = Self.focusedSnapshot(pid: target.pid) else {
            return .error("Typing could not be verified in \(target.appName). Bring the text field to the foreground or use read_screen first.")
        }
        if afterSnapshot.isSecureInput {
            return .error("Refusing to type into a secure text field.")
        }
        let afterValue = Self.preferredTextValue(appName: target.appName) ?? afterSnapshot.value
        guard Self.didVerifyTypedText(text, beforeValue: beforeValue, afterValue: afterValue) else {
            return .error("Typing could not be verified in \(target.appName). Bring the text field to the foreground or use read_screen first.")
        }

        return .success("Typed text in \(target.appName) (\(text.count) chars).")
    }

    private static func focusedSnapshot(pid: pid_t) -> AccessibilityBridge.FocusedElementSnapshot? {
        do {
            return try AccessibilityBridge.focusedElementSnapshot(pid: pid)
        } catch {
            return nil
        }
    }

    private static func preferredTextElement(appName: String) -> AccessibilityBridge.UIElement? {
        do {
            return try AccessibilityBridge.queryElements(appName: appName)
                .filter { preferredTextRoles.contains($0.role) && $0.isEnabled && !$0.isSecureInput }
                .max { lhs, rhs in
                    (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
                }
        } catch {
            return nil
        }
    }

    private static func preferredTextValue(appName: String) -> String? {
        preferredTextElement(appName: appName)?.value
    }

    private static func didVerifyTypedText(
        _ text: String,
        beforeValue: String?,
        afterValue: String?
    ) -> Bool {
        guard let normalizedText = normalize(text),
              let normalizedAfterValue = normalize(afterValue),
              normalizedAfterValue.contains(normalizedText)
        else {
            return false
        }

        let normalizedBeforeValue = normalize(beforeValue)
        return normalizedBeforeValue != normalizedAfterValue
    }

    private static func normalize(_ value: String?) -> String? {
        value?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    @MainActor
    private static func resolveTypingTarget(
        explicitAppName: String?,
        orderedVisibleWindows: [DesktopWindowSelection.VisibleWindow]
    ) -> ResolvedTypingTarget? {
        if let explicitAppName,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName?.localizedCaseInsensitiveContains(explicitAppName) == true
           }),
           let appName = app.localizedName
        {
            return ResolvedTypingTarget(pid: app.processIdentifier, appName: appName)
        }

        let excludedAppNames: Set<String> = [
            "fae",
            "loginwindow",
            "windowmanager",
            "system settings",
            "keychain access",
            "securityagent",
        ]
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if let frontmostApp,
           let frontmostName = frontmostApp.localizedName,
           !excludedAppNames.contains(frontmostName.lowercased())
        {
            return ResolvedTypingTarget(pid: frontmostApp.processIdentifier, appName: frontmostName)
        }

        guard let targetName = DesktopWindowSelection.resolveFallbackTypingTargetName(
            explicitAppName: nil,
            frontmostAppName: frontmostApp?.localizedName,
            orderedWindows: orderedVisibleWindows,
            excludedAppNames: excludedAppNames
        ),
        let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == targetName || $0.localizedName?.localizedCaseInsensitiveContains(targetName) == true
        }),
        let appName = app.localizedName
        else {
            return nil
        }

        return ResolvedTypingTarget(pid: app.processIdentifier, appName: appName)
    }

    @MainActor
    private static func activateTargetApp(_ target: ResolvedTypingTarget) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            return false
        }
        _ = app.activate()
        for _ in 0..<15 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    @MainActor
    private static func pasteText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let commandKey: CGKeyCode = 55
        let vKey: CGKeyCode = 9
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else {
            return false
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - Scroll Tool

/// Scrolls in a direction by a given amount.
struct ScrollTool: Tool {
    let name = "scroll"
    let description = "Scroll the screen in a direction. Use after read_screen to navigate content."
    let parametersSchema = #"{"direction":{"type":"string","description":"up, down, left, or right","required":true},"amount":{"type":"integer","description":"Pixels to scroll (default 300)"}}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .medium
    let example = #"<tool_call>{"name":"scroll","arguments":{"direction":"down","amount":300}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let direction = input["direction"] as? String else {
            return .error("Missing required parameter: direction (up/down/left/right)")
        }
        let amount = input["amount"] as? Int ?? 300

        let (dx, dy): (Int32, Int32)
        switch direction.lowercased() {
        case "up": (dx, dy) = (0, Int32(amount / 10))
        case "down": (dx, dy) = (0, -Int32(amount / 10))
        case "left": (dx, dy) = (Int32(amount / 10), 0)
        case "right": (dx, dy) = (-Int32(amount / 10), 0)
        default:
            return .error("Invalid direction: \(direction). Use up, down, left, or right.")
        }

        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           AccessibilityBridge.isDeniedAutomationTarget(pid: frontmostPID)
        {
            return .error("Refusing to scroll a protected system surface.")
        }

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return .error("Failed to create scroll event")
        }
        scrollEvent.post(tap: CGEventTapLocation.cghidEventTap)

        return .success("Scrolled \(direction) by \(amount) pixels")
    }
}

// MARK: - Find Element Tool

/// Searches for UI elements by text or role.
struct FindElementTool: Tool {
    let name = "find_element"
    let description = "Find UI elements by text content or role. Returns matching elements with indices for click/type_text."
    let parametersSchema = #"{"query":{"type":"string","description":"Text to search for in element titles/values","required":true},"role":{"type":"string","description":"Optional role filter: AXButton, AXTextField, AXMenuItem, etc."},"app":{"type":"string","description":"Optional app name to limit search"}}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"find_element","arguments":{"query":"Submit","app":"Safari"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let query = input["query"] as? String, !query.isEmpty else {
            return .error("Missing required parameter: query")
        }
        let roleFilter = input["role"] as? String
        let appName = input["app"] as? String

        guard AccessibilityBridge.isAccessibilityEnabled() else {
            AccessibilityBridge.requestAccessibility()
            return .error("Accessibility permission required.")
        }

        let elements: [AccessibilityBridge.UIElement]
        do {
            elements = try AccessibilityBridge.queryElements(appName: appName)
        } catch {
            return .error("Failed to query elements: \(error.localizedDescription)")
        }

        let queryLower = query.lowercased()
        let matches = elements.filter { elem in
            if let roleFilter, !elem.role.localizedCaseInsensitiveContains(roleFilter) {
                return false
            }
            let titleMatch = elem.title?.lowercased().contains(queryLower) ?? false
            let valueMatch = elem.value?.lowercased().contains(queryLower) ?? false
            return titleMatch || valueMatch
        }

        if matches.isEmpty {
            return .success("No elements found matching '\(query)'\(roleFilter.map { " with role \($0)" } ?? "").")
        }

        var result = "Found \(matches.count) matching element(s):\n"
        for elem in matches.prefix(20) {
            let title = elem.title ?? "(no title)"
            let enabled = elem.isEnabled ? "" : " [disabled]"
            let secure = elem.isSecureInput ? " [secure]" : ""
            result += "[\(elem.elementIndex)] \(elem.role): \(title)\(enabled)\(secure) at (\(Int(elem.frame.midX)),\(Int(elem.frame.midY)))\n"
        }
        if matches.count > 20 {
            result += "... and \(matches.count - 20) more matches\n"
        }

        return .success(result)
    }
}
