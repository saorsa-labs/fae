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
            image = try await captureScreen(appName: appName)
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
        let stream = await vlm.describe(image: image, prompt: prompt, options: options)
        do {
            for try await chunk in stream {
                result += chunk
            }
        } catch {
            return .error("VLM description failed: \(error.localizedDescription)")
        }

        let width = image.width
        let height = image.height
        return .success("Screenshot (\(width)x\(height)):\n\(result)")
    }

    /// Capture the screen or a specific app window using ScreenCaptureKit.
    private func captureScreen(appName: String?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        if let appName, let app = content.applications.first(where: {
            $0.applicationName.localizedCaseInsensitiveContains(appName)
        }) {
            let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
            if let targetWindow = windows.first ?? content.windows.first {
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            } else if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                throw ScreenshotError.noDisplay
            }
        } else {
            guard let display = content.displays.first else {
                throw ScreenshotError.noDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.scalesToFit = true
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return image
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
    let description = "Take a photo with the Mac's camera and describe what's visible. Use when asked about something physical in the room."
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

/// Helper class to capture a single camera frame using AVCaptureSession.
private final class CameraFrameCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var completion: ((Result<CGImage, Error>) -> Void)?

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

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            completion(.failure(CameraError.configFailed))
            return
        }
        session.addOutput(output)
        self.photoOutput = output
        self.session = session

        session.startRunning()

        // Small delay to let the camera warm up, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, session] in
            guard let self, let output = self.photoOutput else {
                session.stopRunning()
                return
            }
            let settings = AVCapturePhotoSettings()
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { session?.stopRunning() }

        if let error {
            completion?(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let ciImage = CIImage(data: data)
        else {
            completion?(.failure(CameraError.noImage))
            return
        }

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
                let options = GenerationOptions(
                    temperature: 0.3, topP: 0.9, maxTokens: 512, suppressThinking: true
                )
                var desc = ""
                let stream = await vlm.describe(
                    image: image,
                    prompt: "Briefly describe what's visible on screen. Focus on the main app and its state.",
                    options: options
                )
                for try await chunk in stream { desc += chunk }
                visualDescription = "Visual overview: \(desc)\n\n"
            } catch {
                visualDescription = "Visual capture unavailable: \(error.localizedDescription)\n\n"
            }
        }

        return .success("\(visualDescription)\(elementList)")
    }

    private func captureScreen(appName: String?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        if let appName, let app = content.applications.first(where: {
            $0.applicationName.localizedCaseInsensitiveContains(appName)
        }) {
            let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
            if let targetWindow = windows.first ?? content.windows.first {
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            } else if let display = content.displays.first {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                throw ScreenshotTool.ScreenshotError.noDisplay
            }
        } else {
            guard let display = content.displays.first else {
                throw ScreenshotTool.ScreenshotError.noDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.scalesToFit = true
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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

        // Fallback: keystroke synthesis at current cursor position.
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              !AccessibilityBridge.isDeniedAutomationTarget(pid: frontmostPID)
        else {
            return .error("Refusing to type into a protected system surface.")
        }

        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                continue
            }
            var unicodeChars = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            event.post(tap: .cghidEventTap)

            guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            upEvent.post(tap: .cghidEventTap)
        }

        return .success("Typed text at cursor position (\(text.count) chars).")
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
